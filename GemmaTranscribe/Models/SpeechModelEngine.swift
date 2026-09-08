//
//  SpeechModelEngine.swift
//  GemmaTranscribe
//
//  Pluggable local speech model engine & ASRProvider protocols.
//  Enables swapping local models (LiteRT Gemma 3n, Whisper, Apple Neural Speech)
//  without modifying audio or UI pipelines.
//

import Foundation
import AVFoundation

/// Universal Local ASR Provider protocol conforming to the modular speech pipeline.
public protocol ASRProvider: AnyObject, Sendable {
    /// Unique identifier for this speech model provider
    var providerId: String { get }
    
    /// User-facing display name
    var displayName: String { get }
    
    /// Whether the model weights are loaded and ready in memory
    var isReady: Bool { get }
    
    /// Transcribes an audio buffer of 16kHz mono Float32 samples
    func processAudio(samples: [Float]) async throws -> String
}

/// Extended speech model engine for models loaded from disk directories
public protocol SpeechModelEngine: ASRProvider {
    var modelId: String { get }
    var isLoaded: Bool { get }
    
    func loadModel(from localDirectory: URL) async throws
    func unload() async
    func transcribe(audioSamples: [Float]) async throws -> String
}

extension SpeechModelEngine {
    public var providerId: String { modelId }
    public var isReady: Bool { isLoaded }
    
    public func processAudio(samples: [Float]) async throws -> String {
        try await transcribe(audioSamples: samples)
    }
}
