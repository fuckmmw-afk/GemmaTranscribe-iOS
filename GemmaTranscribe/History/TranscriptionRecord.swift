//
//  TranscriptionRecord.swift
//  GemmaTranscribe
//
//  Local transcription history record containing transcript, duration, model,
//  and post-STOP Cloudflare AI enrichment cards.
//  Adapted from Dictus TranscriptionRecord architecture.
//

import Foundation

public struct TranscriptionRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let durationSeconds: Int
    public let rawTranscript: String
    public let cleanTranscript: String
    public let modelUsed: String
    
    // Cloudflare AI Post-Processing & Web Search results
    public let summary: String?
    public let cards: [DefinitionCard]?
    public let actionPoints: [String]?
    public let webSearchCitation: WebSearchCitation?
    
    public var durationFormatted: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    public var dateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
    
    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        durationSeconds: Int,
        rawTranscript: String,
        cleanTranscript: String,
        modelUsed: String,
        summary: String? = nil,
        cards: [DefinitionCard]? = nil,
        actionPoints: [String]? = nil,
        webSearchCitation: WebSearchCitation? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.rawTranscript = rawTranscript
        self.cleanTranscript = cleanTranscript
        self.modelUsed = modelUsed
        self.summary = summary
        self.cards = cards
        self.actionPoints = actionPoints
        self.webSearchCitation = webSearchCitation
    }
}
