//
//  LiveTranscriptionCoordinator.swift
//  GemmaTranscribe
//
//  Central coordinator for real-time speech capture, on-device Gemma 3n E2B transcription,
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
    
    public let audioPipeline = AudioPipeline()
    public var audioCapture: AudioPipeline { audioPipeline }
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
        // Stream audio chunks directly to on-device Gemma 3n E2B
        audioPipeline.onAudioChunkAvailable = { chunk in
            Task { @MainActor in
                await LiveTranscriptionCoordinator.shared.processAudioChunk(chunk)
            }
        }
        
        audioPipeline.onElapsedSecondsUpdated = { seconds in
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
        
        // Ensure Gemma 3n model is loaded before starting
        if !modelManager.isModelReady {
            await modelManager.loadActiveEngine()
        }
        
        guard modelManager.isModelReady else {
            status = .failed
            errorText = "Модель Gemma 3n E2B не найдена. Нажмите на плашку вверху экрана, чтобы открыть Менеджер моделей и загрузить веса."
            logger.error("Recording aborted: Gemma 3n E2B weights are not ready on device")
            return
        }
        
        status = .recording
        elapsedSeconds = 0
        recordingStartTime = Date()
        
        let chunkDuration = UserDefaults.standard.double(forKey: AppConfig.audioChunkDurationKey)
        let effectiveDuration = chunkDuration > 0 ? chunkDuration : AppConfig.defaultAudioChunkDuration
        
        do {
            try await audioPipeline.startCapture(chunkDuration: effectiveDuration)
            logger.info("Recording session started with on-device Gemma 3n E2B engine")
        } catch {
            status = .failed
            errorText = error.localizedDescription
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    public func stopRecordingAndProcess() async {
        guard status.isRecordingOrTranscribing else { return }
        
        status = .transcribing
        let finalAudioSamples = await audioPipeline.stopCapture()
        let duration = max(1, Int(self.elapsedSeconds.rounded()))
        
        var cleanText = plainCleanTranscript
        
        // Execute Google Gemma 3n E2B local model transcription on recorded audio
        if !finalAudioSamples.isEmpty {
            logger.info("Executing Google Gemma 3n E2B local model transcription on \(finalAudioSamples.count) samples...")
            do {
                let gemmaText = try await modelManager.activeEngine.processAudio(samples: finalAudioSamples)
                if !gemmaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cleanText = TranscriptCleaner.clean(gemmaText)
                    self.fullRawTranscript = gemmaText
                    self.interimText = cleanText
                    logger.info("Google Gemma 3n E2B recognized: \(cleanText.prefix(40))...")
                }
            } catch {
                logger.error("Gemma 3n transcription error: \(error.localizedDescription)")
            }
        }
        
        if cleanText.isEmpty && !interimText.isEmpty {
            cleanText = TranscriptCleaner.clean(interimText)
        }
        if cleanText.isEmpty && !fullRawTranscript.isEmpty {
            cleanText = TranscriptCleaner.clean(fullRawTranscript)
        }
        
        let hasSpeech = !cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let finalCleanText = hasSpeech ? cleanText : "Речь не была распознана (тишина или неразборчиво)"
        self.currentCleanTranscript = finalCleanText
        
        // Trigger Cloudflare Post-STOP AI Processing & Context-Aware Search with CLEAN transcript only
        status = .processing
        logger.info("Processing post-stop with clean transcript: \(finalCleanText.prefix(40))...")
        
        let engineName = "Google Gemma 3n E2B (LiteRT)"
        
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
    
    private func processAudioChunk(_ samples: [Float], isFinal: Bool = false) async {
        guard !samples.isEmpty else { return }
        
        do {
            let rawChunkText = try await modelManager.activeEngine.processAudio(samples: samples)
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
            logger.error("Error transcribing audio chunk via Gemma 3n: \(error.localizedDescription)")
        }
    }
}
