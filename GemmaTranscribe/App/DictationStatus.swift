//
//  DictationStatus.swift
//  GemmaTranscribe
//
//  Lifecycle status of recording, transcription, and post-processing.
//  Adapted from Dictus Core architecture.
//

import Foundation

public enum DictationStatus: String, Codable, CaseIterable, Sendable {
    case idle         // Ready to record
    case recording    // Actively recording audio from microphone
    case transcribing // Running local model transcription on audio chunk
    case processing   // Post-STOP Cloudflare AI processing + Web search
    case ready        // Finished successfully with results
    case failed       // An error occurred
    
    public var isRecordingOrTranscribing: Bool {
        self == .recording || self == .transcribing
    }
}
