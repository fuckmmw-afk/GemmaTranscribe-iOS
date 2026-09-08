//
//  AppleOnDeviceSpeechEngine.swift
//  GemmaTranscribe
//
//  Apple Neural speech recognition engine using Speech framework.
//  Transcribes spoken audio in realtime with native hardware buffer streaming
//  and seamless long-session rotation for recordings of any duration (4+ minutes).
//

import Foundation
import Speech
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "AppleSpeechEngine")

public final class AppleOnDeviceSpeechEngine: SpeechModelEngine, @unchecked Sendable {
    public let modelId: String = "apple/on-device-neural"
    public let displayName: String = "Apple Neural Speech"
    
    public var isLoaded: Bool {
        return true
    }
    
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private var cumulativeTranscript: String = ""
    private var currentSegmentText: String = ""
    private var isStreamingActive: Bool = false
    private var textUpdateCallback: (@Sendable (String) -> Void)?
    
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "com.gemmatranscribe.applespeech", qos: .userInitiated)
    
    public init() {
        let ruLocale = Locale(identifier: "ru-RU")
        if let rec = SFSpeechRecognizer(locale: ruLocale), rec.isAvailable {
            self.recognizer = rec
        } else if let rec = SFSpeechRecognizer(locale: Locale.current), rec.isAvailable {
            self.recognizer = rec
        } else {
            self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        
        self.recognizer?.defaultTaskHint = .dictation
        logger.info("AppleSpeechEngine initialized with locale: \(self.recognizer?.locale.identifier ?? "unknown", privacy: .public)")
    }
    
    public func loadModel(from localDirectory: URL) async throws {
        // Built-in system model
    }
    
    public func unload() async {
        stopStreaming()
    }
    
    public func getAccumulatedTranscript() -> String {
        var result = ""
        queue.sync {
            let part1 = self.cumulativeTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            let part2 = self.currentSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !part1.isEmpty && !part2.isEmpty {
                result = part1 + " " + part2
            } else if !part1.isEmpty {
                result = part1
            } else {
                result = part2
            }
        }
        return result
    }
    
    public func startStreaming(onTextUpdate: @escaping @Sendable (String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cumulativeTranscript = ""
            self.currentSegmentText = ""
            self.isStreamingActive = true
            self.textUpdateCallback = onTextUpdate
            
            let authStatus = SFSpeechRecognizer.authorizationStatus()
            if authStatus != .authorized {
                SFSpeechRecognizer.requestAuthorization { status in
                    if status == .authorized {
                        self.queue.async {
                            self.beginRecognitionTask()
                        }
                    } else {
                        logger.error("SFSpeechRecognizer authorization not granted: \(status.rawValue)")
                    }
                }
            } else {
                self.beginRecognitionTask()
            }
        }
    }
    
    private func beginRecognitionTask() {
        guard isStreamingActive else { return }
        guard let recognizer = self.recognizer, recognizer.isAvailable else {
            logger.error("SFSpeechRecognizer is unavailable")
            return
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request
        
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.queue.async {
                    self.currentSegmentText = text
                    let full = self.formatFullTranscript()
                    self.textUpdateCallback?(full)
                }
                
                if result.isFinal {
                    self.queue.async {
                        self.rotateSegment()
                    }
                }
            }
            
            if let error = error {
                let nsError = error as NSError
                // If the 60s iOS recognition limit was reached or task completed, rotate and resume streaming
                self.queue.async {
                    if self.isStreamingActive {
                        logger.info("Speech segment ended or timed out (\(nsError.code)). Rotating session smoothly...")
                        self.rotateSegment()
                    }
                }
            }
        }
        
        logger.info("Apple Speech recognition task started")
    }
    
    private func formatFullTranscript() -> String {
        let part1 = cumulativeTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let part2 = currentSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !part1.isEmpty && !part2.isEmpty {
            return part1 + " " + part2
        } else if !part1.isEmpty {
            return part1
        } else {
            return part2
        }
    }
    
    private func rotateSegment() {
        guard isStreamingActive else { return }
        let currentTrimmed = currentSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentTrimmed.isEmpty {
            if !cumulativeTranscript.isEmpty {
                cumulativeTranscript += " " + currentTrimmed
            } else {
                cumulativeTranscript = currentTrimmed
            }
            currentSegmentText = ""
        }
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask = nil
        
        // Start fresh recognition request for continuous long speech
        beginRecognitionTask()
    }
    
    public func appendRawBuffer(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self = self, let request = self.recognitionRequest else { return }
            request.append(buffer)
        }
    }
    
    public func appendAudioSamples(_ samples: [Float]) {
        queue.async { [weak self] in
            guard let self = self, let request = self.recognitionRequest, !samples.isEmpty else { return }
            
            let frameCount = AVAudioFrameCount(samples.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount
            
            if let floatData = buffer.floatChannelData?[0] {
                for i in 0..<samples.count {
                    floatData[i] = samples[i]
                }
            }
            
            request.append(buffer)
        }
    }
    
    public func stopStreaming() {
        queue.sync {
            self.isStreamingActive = false
            self.recognitionRequest?.endAudio()
            let currentTrimmed = self.currentSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentTrimmed.isEmpty {
                if !self.cumulativeTranscript.isEmpty {
                    self.cumulativeTranscript += " " + currentTrimmed
                } else {
                    self.cumulativeTranscript = currentTrimmed
                }
                self.currentSegmentText = ""
            }
            self.recognitionRequest = nil
            self.recognitionTask = nil
        }
    }
    
    public func transcribe(audioSamples: [Float]) async throws -> String {
        return getAccumulatedTranscript()
    }
}
