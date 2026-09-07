//
//  CloudflareResponse.swift
//  GemmaTranscribe
//
//  Structured data models for Cloudflare AI processing and Web search results.
//

import Foundation

public struct DefinitionCard: Identifiable, Codable, Hashable, Sendable {
    public var id: String { term }
    public let term: String
    public let definition: String
    public let notes: [String]?
    public let source: String?
    
    public init(term: String, definition: String, notes: [String]? = nil, source: String? = nil) {
        self.term = term
        self.definition = definition
        self.notes = notes
        self.source = source
    }
}

public struct WebSearchCitation: Codable, Hashable, Sendable {
    public let query: String?
    public let title: String?
    public let snippet: String?
    public let url: String?
    
    public init(query: String? = nil, title: String? = nil, snippet: String? = nil, url: String? = nil) {
        self.query = query
        self.title = title
        self.snippet = snippet
        self.url = url
    }
}

public struct CloudflareBrainResponse: Codable, Sendable {
    public let summary: String?
    public let cards: [DefinitionCard]?
    public let actionPoints: [String]?
    public let webSearch: WebSearchCitation?
    public let model: String?
    public let searched: Bool?
    
    public init(
        summary: String? = nil,
        cards: [DefinitionCard]? = nil,
        actionPoints: [String]? = nil,
        webSearch: WebSearchCitation? = nil,
        model: String? = nil,
        searched: Bool? = nil
    ) {
        self.summary = summary
        self.cards = cards
        self.actionPoints = actionPoints
        self.webSearch = webSearch
        self.model = model
        self.searched = searched
    }
}
