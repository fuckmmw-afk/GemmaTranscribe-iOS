//
//  TranscriptionLine.swift
//  GemmaTranscribe
//
//  Represents a segment or line of transcription.
//  Adapted from LiveTranscriber architecture.
//

import Foundation

public struct TranscriptionLine: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public let timestamp: Date
    public var isFinal: Bool
    
    public init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = Date(),
        isFinal: Bool = false
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.isFinal = isFinal
    }
}
