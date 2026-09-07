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
    
    public let audioCapture = UnifiedAudioCapture()
    private let modelManager = ModelManager.shared
    private let historyStore = TranscriptionHistoryStore.shared
    
    private var recordingStartTime: Date?
    private var fullRawTranscript: String = ""
    
    public var plainCleanTranscript: String {
        let text = transcriptLines.map(\.text).joined(separator: " ") + (interimText.isEmpty ? "" : " " + interimText)
        return TranscriptCleaner.clean(text)
    }
    
    public init() {
        // Set up streaming audio chunk handler
        audioCapture.onAudioChunkAvailable = { [weak self] chunk in
            Task { @MainActor in
                await self?.processAudioChunk(chunk)
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
        recordingStartTime = Date()
        
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
        let finalAudioSamples = await audioCapture.stopCapture()
        
        // Finalize remaining audio samples if any
        if !finalAudioSamples.isEmpty {
            await processAudioChunk(finalAudioSamples, isFinal: true)
        }
        
        // Calculate duration
        let duration = Int(audioCapture.elapsedSeconds.rounded())
        
        // Prepare clean transcript
        let cleanText = plainCleanTranscript
        self.currentCleanTranscript = cleanText
        
        guard !cleanText.isEmpty else {
            status = .idle
            logger.info("Empty transcription recorded, resetting to idle")
            return
        }
        
        // Trigger Cloudflare Post-STOP AI Processing & Web Search
        status = .processing
        logger.info("Triggering Cloudflare brain processing for: \(cleanText.prefix(40))...")
        
        do {
            let brainResult = try await CloudflareBrainService.process(cleanTranscript: cleanText)
            self.latestBrainResponse = brainResult
            self.status = .ready
            self.isPostStopSheetPresented = true
            
            // Save to local history immediately
            let record = TranscriptionRecord(
                durationSeconds: duration,
                rawTranscript: fullRawTranscript.isEmpty ? cleanText : fullRawTranscript,
                cleanTranscript: cleanText,
                modelUsed: modelManager.activeModelId,
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
            
            // Save even if Cloudflare failed (using clean text)
            let record = TranscriptionRecord(
                durationSeconds: duration,
                rawTranscript: fullRawTranscript.isEmpty ? cleanText : fullRawTranscript,
                cleanTranscript: cleanText,
                modelUsed: modelManager.activeModelId
            )
            historyStore.append(record)
        }
    }
    
    // MARK: - Private Processing
    
    private func processAudioChunk(_ samples: [Float], isFinal: Bool = false) async {
        guard !samples.isEmpty else { return }
        
        do {
            let rawChunkText = try await modelManager.activeEngine.transcribe(audioSamples: samples)
            guard !rawChunkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            
            fullRawTranscript += (fullRawTranscript.isEmpty ? "" : " ") + rawChunkText
            
            // Clean chunk with TranscriptCleaner
            let cleanedChunk = TranscriptCleaner.clean(rawChunkText)
            guard !cleanedChunk.isEmpty else { return }
            
            if isFinal {
                let finalLine = TranscriptionLine(text: cleanedChunk, isFinal: true)
                transcriptLines.append(finalLine)
                interimText = ""
            } else {
                // Update streaming interim text
                self.interimText = cleanedChunk
            }
        } catch {
            logger.error("Error transcribing audio chunk: \(error.localizedDescription)")
        }
    }
}
