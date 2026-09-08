//
//  LiteRTGemmaEngine.swift
//  GemmaTranscribe
//
//  Google Gemma 3n E2B local speech engine powered by Google AI Edge / LiteRT runtime.
//  Optimized for iPhone with direct memory-mapping and 16kHz mono audio processing.
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
    
    public func loadModel(from localDirectoryOrFile: URL) async throws {
        logger.info("Initializing LiteRT runtime for \(self.modelId, privacy: .public) from \(localDirectoryOrFile.path, privacy: .public)")
        
        let validModelFile = Self.resolveModelFilePath(from: localDirectoryOrFile)
        
        guard let modelFile = validModelFile else {
            logger.error("No valid model files found in \(localDirectoryOrFile.path, privacy: .public)")
            throw NSError(
                domain: "GemmaTranscribe.LiteRT",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Файл весов Gemma 3n (.litertlm / .bin) не найден в \(localDirectoryOrFile.lastPathComponent)"]
            )
        }
        
        self.modelURL = modelFile
        logger.info("Resolved Gemma 3n weight file: \(modelFile.path, privacy: .public)")
        
#if canImport(LiteRTLM)
        do {
            let config = try EngineConfig(
                modelPath: modelFile.path,
                backend: .gpu,
                visionBackend: nil,
                audioBackend: .cpu(),
                maxNumTokens: 2048,
                cacheDir: NSTemporaryDirectory()
            )
            let litertEngine = Engine(engineConfig: config)
            try await litertEngine.initialize()
            self.engine = litertEngine
            self._isLoaded = true
            logger.info("Google AI Edge LiteRT Engine initialized successfully (GPU) for Gemma 3n: \(modelFile.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("LiteRT GPU engine init error: \(error.localizedDescription). Falling back to CPU...")
            let fallbackConfig = try EngineConfig(
                modelPath: modelFile.path,
                backend: .cpu(),
                visionBackend: nil,
                audioBackend: .cpu(),
                maxNumTokens: 1024,
                cacheDir: NSTemporaryDirectory()
            )
            let litertEngine = Engine(engineConfig: fallbackConfig)
            try await litertEngine.initialize()
            self.engine = litertEngine
            self._isLoaded = true
            logger.info("Google AI Edge LiteRT Engine initialized successfully (CPU) for Gemma 3n")
        }
#else
        self._isLoaded = true
        logger.info("LiteRT model registered: \(modelFile.lastPathComponent, privacy: .public)")
#endif
    }
    
    public static func resolveModelFilePath(from url: URL) -> URL? {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                return url
            }
        }
        
        // Search directory recursively for largest valid model file (.litertlm, .bin, .tflite or > 50MB)
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        
        var candidates: [(url: URL, size: Int64)] = []
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  vals.isDirectory == false else { continue }
            let size = Int64(vals.fileSize ?? 0)
            let ext = fileURL.pathExtension.lowercased()
            if (ext == "litertlm" || ext == "tflite" || ext == "bin" || size > 50_000_000) && size > 5_000_000 {
                candidates.append((fileURL, size))
            }
        }
        
        return candidates.max(by: { $0.size < $1.size })?.url
    }
    
    public func unload() async {
#if canImport(LiteRTLM)
        self.engine = nil
#endif
        self._isLoaded = false
        self.modelURL = nil
        logger.info("LiteRT engine unloaded from memory")
    }
    
    public func transcribe(audioSamples: [Float]) async throws -> String {
        guard _isLoaded, let _ = modelURL else {
            logger.warning("Gemma transcribe requested but model is not loaded")
            return ""
        }
        guard !audioSamples.isEmpty else { return "" }
        
#if canImport(LiteRTLM)
        guard let engine = self.engine else {
            return ""
        }
        
        // Slice long audio into 15-second windows (240,000 samples @ 16kHz) to avoid context overflow / OOM on long recordings
        let maxChunkSamples = 240_000
        if audioSamples.count <= maxChunkSamples {
            return try await transcribeSingleChunk(audioSamples, engine: engine)
        } else {
            var fullResult: [String] = []
            var offset = 0
            while offset < audioSamples.count {
                let end = min(offset + maxChunkSamples, audioSamples.count)
                let slice = Array(audioSamples[offset..<end])
                if slice.count > 8000 { // at least 0.5s
                    do {
                        let text = try await transcribeSingleChunk(slice, engine: engine)
                        if !text.isEmpty {
                            fullResult.append(text)
                        }
                    } catch {
                        logger.error("Error transcribing Gemma slice: \(error.localizedDescription)")
                    }
                }
                offset = end
            }
            return fullResult.joined(separator: " ")
        }
#else
        return ""
#endif
    }
    
#if canImport(LiteRTLM)
    private func transcribeSingleChunk(_ samples: [Float], engine: Engine) async throws -> String {
        let conversation = try await engine.createConversation()
        let wavData = WAVEncoder.encode(samples: samples)
        let audioMessage = Message(
            of: .audioData(wavData),
            .text("Стенографируй эту речь на русском языке точно с пунктуацией. Верни только распознанный текст.")
        )
        let response = try await conversation.sendMessage(audioMessage)
        let transcribed = response.toString.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Gemma 3n transcribed slice: \(transcribed.prefix(50))...")
        return transcribed
    }
#endif
}
