//
//  LiteRTGemmaEngine.swift
//  GemmaTranscribe
//
//  Google Gemma 3n E2B local speech engine powered by Google AI Edge / LiteRT runtime.
//  Optimized for iPhone 12 with direct memory-mapping and 16kHz mono audio chunk processing.
//

import Foundation
import OSLog
#if canImport(LiteRTLM)
import LiteRTLM
#endif

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "LiteRTGemmaEngine")

public final class LiteRTGemmaEngine: SpeechModelEngine, @unchecked Sendable {
    public let modelId: String
    public let displayName: String
    
    private var modelURL: URL?
    private var _isLoaded: Bool = false
    private let queue = DispatchQueue(label: "com.gemmatranscribe.litert-engine", qos: .userInitiated)
    
#if canImport(LiteRTLM)
    private var engine: Engine?
    private var conversation: Conversation?
#endif
    
    public var isLoaded: Bool {
        _isLoaded
    }
    
    public init(
        modelId: String = "google/gemma-3n-E2B-it-litert-lm",
        displayName: String = "Google Gemma 3n E2B (LiteRT)"
    ) {
        self.modelId = modelId
        self.displayName = displayName
    }
    
    public func loadModel(from localDirectory: URL) async throws {
        logger.info("Initializing LiteRT runtime for \(self.modelId, privacy: .public) from \(localDirectory.path, privacy: .public)")
        
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(at: localDirectory, includingPropertiesForKeys: nil)) ?? []
        
        let bundleFile = contents.first { url in
            let ext = url.pathExtension.lowercased()
            return ext == "litertlm" || ext == "tflite" || ext == "bin"
        }
        
        guard let validModelFile = bundleFile ?? contents.first else {
            logger.error("No valid model files found in \(localDirectory.path, privacy: .public)")
            throw NSError(
                domain: "GemmaTranscribe.LiteRT",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Файл модели Gemma 3n не найден в папке \(localDirectory.lastPathComponent)"]
            )
        }
        
        self.modelURL = validModelFile
        
#if canImport(LiteRTLM)
        do {
            let config = try EngineConfig(
                modelPath: validModelFile.path,
                backend: .gpu,
                visionBackend: nil,
                audioBackend: .cpu(),
                maxNumTokens: 2048,
                cacheDir: NSTemporaryDirectory()
            )
            let litertEngine = Engine(engineConfig: config)
            try await litertEngine.initialize()
            self.engine = litertEngine
            self.conversation = try await litertEngine.createConversation()
            self._isLoaded = true
            logger.info("Google AI Edge LiteRT Engine initialized successfully for Gemma 3n: \(validModelFile.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Failed to initialize LiteRT GPU engine: \(error.localizedDescription). Trying CPU fallback...")
            let fallbackConfig = try EngineConfig(
                modelPath: validModelFile.path,
                backend: .cpu(),
                visionBackend: nil,
                audioBackend: .cpu(),
                maxNumTokens: 1024,
                cacheDir: NSTemporaryDirectory()
            )
            let litertEngine = Engine(engineConfig: fallbackConfig)
            try await litertEngine.initialize()
            self.engine = litertEngine
            self.conversation = try await litertEngine.createConversation()
            self._isLoaded = true
            logger.info("Google AI Edge LiteRT Engine (CPU) initialized for Gemma 3n")
        }
#else
        self._isLoaded = true
        logger.info("LiteRT model registered: \(validModelFile.lastPathComponent, privacy: .public)")
#endif
    }
    
    public func unload() async {
#if canImport(LiteRTLM)
        self.conversation = nil
        self.engine = nil
#endif
        self._isLoaded = false
        self.modelURL = nil
        logger.info("LiteRT engine unloaded from memory")
    }
    
    public func transcribe(audioSamples: [Float]) async throws -> String {
        guard _isLoaded, let _ = modelURL else {
            return ""
        }
        guard !audioSamples.isEmpty else { return "" }
        
#if canImport(LiteRTLM)
        if let conversation = self.conversation {
            let wavData = WAVEncoder.encode(samples: audioSamples)
            let audioMessage = Message(
                of: .audioData(wavData),
                .text("Стенографируй эту речь на русском языке точно с пунктуацией. Верни только распознанный текст.")
            )
            let response = try await conversation.sendMessage(audioMessage)
            let transcribed = response.toString.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("Gemma 3n transcribed: \(transcribed.prefix(50))...")
            return transcribed
        }
#endif
        return ""
    }
}
