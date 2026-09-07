//
//  SpeechModelEngine.swift
//  GemmaTranscribe
//
//  Pluggable local speech model engine protocol.
//  Enables swapping local models (Gemma 3n E2B, LiteRT models) without rewriting the app.
//

import Foundation
import AVFoundation

public protocol SpeechModelEngine: AnyObject, Sendable {
    /// The unique identifier of this engine or active model
    var modelId: String { get }
    
    /// Display name of the active model
    var displayName: String { get }
    
    /// Whether the engine weights are loaded into memory / ready for inference
    var isLoaded: Bool { get }
    
    /// Prepares and loads the model from a local directory on disk
    func loadModel(from localDirectory: URL) async throws
    
    /// Unloads weights from memory
    func unload() async
    
    /// Transcribes an audio chunk (16kHz mono Float32 PCM samples) in realtime
    func transcribe(audioSamples: [Float]) async throws -> String
}
