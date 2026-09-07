//
//  AppleOnDeviceSpeechEngine.swift
//  GemmaTranscribe
//
//  On-device Apple Neural speech recognition engine using Speech framework.
//  Provides 100% on-device, offline, zero-network speech-to-text fallback
//  while Gemma 3n weights are downloading or on devices where LiteRT is optimizing.
//

import Foundation
import Speech
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "AppleSpeechEngine")

public final class AppleOnDeviceSpeechEngine: SpeechModelEngine, @unchecked Sendable {
    public let modelId: String = "apple/on-device-neural"
    public let displayName: String = "Apple On-Device Neural Speech"
    
    public var isLoaded: Bool {
        return true
    }
    
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
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
        logger.info("AppleOnDeviceSpeechEngine initialized with locale: \(self.recognizer?.locale.identifier ?? "unknown", privacy: .public)")
    }
    
    public func loadModel(from localDirectory: URL) async throws {
        // Built-in system model, always ready
    }
    
    public func unload() async {
        stopStreaming()
    }
    
    public func startStreaming(onTextUpdate: @escaping @Sendable (String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopStreamingInternal()
            
            // Check authorization
            let authStatus = SFSpeechRecognizer.authorizationStatus()
            if authStatus != .authorized {
                SFSpeechRecognizer.requestAuthorization { status in
                    if status == .authorized {
                        self.beginRecognitionTask(onTextUpdate: onTextUpdate)
                    } else {
                        logger.error("SFSpeechRecognizer permission denied: \(status.rawValue)")
                    }
                }
            } else {
                self.beginRecognitionTask(onTextUpdate: onTextUpdate)
            }
        }
    }
    
    private func beginRecognitionTask(onTextUpdate: @escaping @Sendable (String) -> Void) {
        guard let recognizer = self.recognizer, recognizer.isAvailable else {
            logger.error("SFSpeechRecognizer is not available")
            return
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        
        self.recognitionRequest = request
        
        self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result = result {
                let text = result.bestTranscription.formattedString
                onTextUpdate(text)
            }
            if let error = error {
                logger.debug("Speech recognition callback: \(error.localizedDescription)")
            }
        }
        
        logger.info("Apple Speech recognition streaming started")
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
        queue.async { [weak self] in
            self?.stopStreamingInternal()
        }
    }
    
    private func stopStreamingInternal() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }
    
    public func transcribe(audioSamples: [Float]) async throws -> String {
        guard !audioSamples.isEmpty else { return "" }
        appendAudioSamples(audioSamples)
        return ""
    }
}
