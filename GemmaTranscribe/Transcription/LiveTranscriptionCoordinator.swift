//
//  LiveTranscriptionCoordinator.swift
//  GemmaTranscribe
//
//  Central coordinator for real-time speech capture, local model transcription,
//  text cleaning, and post-STOP Cloudflare AI enrichment.
//

import Foundation
import Combine
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "LiveTranscriptionCoordinator")

@MainActor
public final class LiveTranscriptionCoordinator: ObservableObject {
    public static let shared = LiveTranscriptionCoordinator()
    
    // Published UI State
    @Published public var status: DictationStatus = .idle
    @Published public var transcriptLines: [TranscriptionLine] = []
    @Published public var interimText: String = ""
    @Published public var currentCleanTranscript: String = ""
    @Published public var latestBrainResponse: CloudflareBrainResponse?
    @Published public var errorText: String?
    @Published public var isPostStopSheetPresented: Bool = false
    @Published public var elapsedSeconds: Double = 0
    
    public let audioCapture = UnifiedAudioCapture()
    private let modelManager = ModelManager.shared
    private let historyStore = TranscriptionHistoryStore.shared
    
    private var recordingStartTime: Date?
    private var fullRawTranscript: String = ""
    
    public var plainCleanTranscript: String {
        if !interimText.isEmpty {
            return TranscriptCleaner.clean(interimText)
        }
        let text = transcriptLines.map(\.text).joined(separator: " ")
        return TranscriptCleaner.clean(text)
    }
    
    public init() {
        // Stream raw hardware audio buffers directly to speech recognizer
        audioCapture.onRawBufferAvailable = { [weak self] buffer in
            self?.modelManager.appleFallbackEngine.appendRawBuffer(buffer)
        }
        
        // Handle chunk intervals for models and duration
        audioCapture.onAudioChunkAvailable = { chunk in
            Task { @MainActor in
                await LiveTranscriptionCoordinator.shared.processAudioChunk(chunk)
            }
        }
        
        audioCapture.onElapsedSecondsUpdated = { seconds in
            Task { @MainActor in
                LiveTranscriptionCoordinator.shared.elapsedSeconds = seconds
            }
        }
    }
    
    // MARK: - Actions
    
    public func toggleRecording() async {
        if status.isRecordingOrTranscribing {
            await stopRecordingAndProcess()
        } else {
            await startRecording()
        }
    }
    
    public func startRecording() async {
        guard !status.isRecordingOrTranscribing else { return }
        
        errorText = nil
        interimText = ""
        transcriptLines.removeAll()
        fullRawTranscript = ""
        latestBrainResponse = nil
        status = .recording
        elapsedSeconds = 0
        recordingStartTime = Date()
        
        // Start streaming recognition
        modelManager.appleFallbackEngine.startStreaming { recognizedText in
            Task { @MainActor in
                LiveTranscriptionCoordinator.shared.handleStreamingSpeechUpdate(recognizedText)
            }
        }
        
        let chunkDuration = UserDefaults.standard.double(forKey: AppConfig.audioChunkDurationKey)
        let effectiveDuration = chunkDuration > 0 ? chunkDuration : AppConfig.defaultAudioChunkDuration
        
        do {
            try await audioCapture.startCapture(chunkDuration: effectiveDuration)
            logger.info("Recording session started")
        } catch {
            status = .failed
            errorText = error.localizedDescription
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    public func stopRecordingAndProcess() async {
        guard status.isRecordingOrTranscribing else { return }
        
        status = .transcribing
        modelManager.appleFallbackEngine.stopStreaming()
        
        let finalAudioSamples = await audioCapture.stopCapture()
        let duration = max(1, Int(self.elapsedSeconds.rounded()))
        
        // 1. Check Gemma 3n E2B model inference if model is downloaded
        var cleanText = plainCleanTranscript
        let isGemmaDownloaded = modelManager.isModelDownloaded(modelManager.activeModelId)
        
        if isGemmaDownloaded && !finalAudioSamples.isEmpty {
            logger.info("Executing Google Gemma 3n E2B local model transcription...")
            if let gemmaText = try? await modelManager.activeEngine.transcribe(audioSamples: finalAudioSamples), !gemmaText.isEmpty {
                cleanText = TranscriptCleaner.clean(gemmaText)
                self.fullRawTranscript = gemmaText
                self.interimText = cleanText
                logger.info("Google Gemma 3n E2B recognized: \(cleanText.prefix(40))...")
            }
        }
        
        if cleanText.isEmpty && !interimText.isEmpty {
            cleanText = TranscriptCleaner.clean(interimText)
        }
        if cleanText.isEmpty && !fullRawTranscript.isEmpty {
            cleanText = TranscriptCleaner.clean(fullRawTranscript)
        }
        
        // 2. Fallback: If on-device speech engine didn't catch speech, fallback to Cloudflare Whisper
        if cleanText.isEmpty && !finalAudioSamples.isEmpty {
            logger.info("Falling back to Cloudflare Whisper with \(finalAudioSamples.count) samples...")
            let wavData = WAVEncoder.encode(samples: finalAudioSamples)
            if let cloudText = try? await CloudflareBrainService.transcribeAudio(wavData: wavData), !cloudText.isEmpty {
                cleanText = TranscriptCleaner.clean(cloudText)
                self.fullRawTranscript = cloudText
                self.interimText = cleanText
                logger.info("Cloudflare Whisper successfully transcribed speech: \(cleanText.prefix(40))...")
            }
        }
        
        let hasSpeech = !cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let finalCleanText = hasSpeech ? cleanText : "Речь не была распознана (тишина или неразборчиво)"
        self.currentCleanTranscript = finalCleanText
        
        // Trigger Cloudflare Post-STOP AI Processing & Web Search if we have speech
        status = .processing
        logger.info("Processing post-stop: \(finalCleanText.prefix(40))...")
        
        let engineName = isGemmaDownloaded
            ? "Google Gemma 3n E2B (LiteRT)"
            : modelManager.appleFallbackEngine.displayName
        
        if hasSpeech {
            do {
                let brainResult = try await CloudflareBrainService.process(cleanTranscript: finalCleanText)
                self.latestBrainResponse = brainResult
                self.status = .ready
                self.isPostStopSheetPresented = true
                
                // Save to local history immediately
                let record = TranscriptionRecord(
                    durationSeconds: duration,
                    rawTranscript: fullRawTranscript.isEmpty ? finalCleanText : fullRawTranscript,
                    cleanTranscript: finalCleanText,
                    modelUsed: engineName,
                    summary: brainResult.summary,
                    cards: brainResult.cards,
                    actionPoints: brainResult.actionPoints,
                    webSearchCitation: brainResult.webSearch
                )
                historyStore.append(record)
                logger.info("Recording successfully processed and saved to local history")
            } catch {
                logger.error("Cloudflare processing error: \(error.localizedDescription)")
                self.status = .ready
                self.isPostStopSheetPresented = true
                
                // Save even if Cloudflare failed
                let record = TranscriptionRecord(
                    durationSeconds: duration,
                    rawTranscript: fullRawTranscript.isEmpty ? finalCleanText : fullRawTranscript,
                    cleanTranscript: finalCleanText,
                    modelUsed: engineName
                )
                historyStore.append(record)
            }
        } else {
            // Empty / silent speech session
            self.latestBrainResponse = CloudflareBrainResponse(
                summary: "Запись завершена, однако в аудиофрагменте не обнаружено распознаваемой речи.",
                cards: [],
                actionPoints: ["Говорите ближе к микрофону", "Убедитесь, что микрофону предоставлен доступ в Настройках iOS"],
                webSearch: nil,
                model: engineName,
                searched: false
            )
            self.status = .ready
            self.isPostStopSheetPresented = true
            
            let record = TranscriptionRecord(
                durationSeconds: duration,
                rawTranscript: "Речь не была распознана",
                cleanTranscript: "Речь не была распознана",
                modelUsed: engineName
            )
            historyStore.append(record)
        }
    }
    
    // MARK: - Private Processing
    
    public func handleStreamingSpeechUpdate(_ text: String) {
        let cleaned = TranscriptCleaner.clean(text)
        guard !cleaned.isEmpty else { return }
        self.interimText = cleaned
        self.fullRawTranscript = text
    }
    
    private func processAudioChunk(_ samples: [Float], isFinal: Bool = false) async {
        guard !samples.isEmpty else { return }
        
        do {
            let rawChunkText = try await modelManager.activeEngine.transcribe(audioSamples: samples)
            guard !rawChunkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            
            fullRawTranscript += (fullRawTranscript.isEmpty ? "" : " ") + rawChunkText
            let cleanedChunk = TranscriptCleaner.clean(rawChunkText)
            guard !cleanedChunk.isEmpty else { return }
            
            if isFinal {
                let finalLine = TranscriptionLine(text: cleanedChunk, isFinal: true)
                transcriptLines.append(finalLine)
                interimText = ""
            } else {
                self.interimText = cleanedChunk
            }
        } catch {
            logger.error("Error transcribing audio chunk: \(error.localizedDescription)")
        }
    }
}
