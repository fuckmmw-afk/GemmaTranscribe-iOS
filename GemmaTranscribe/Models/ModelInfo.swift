//
//  ModelInfo.swift
//  GemmaTranscribe
//
//  Catalog metadata for local LiteRT models.
//  Adapted from Dictus ModelInfo architecture.
//

import Foundation

public struct ModelInfo: Identifiable, Codable, Hashable, Sendable {
    public var id: String { identifier }
    
    public let identifier: String       // e.g. "google/gemma-3n-E2B-it-litert-lm"
    public let displayName: String      // "Google Gemma 3n E2B (LiteRT)"
    public let author: String           // "google"
    public let format: String           // "LiteRT-LM"
    public let sizeBytes: Int64         // Size in bytes
    public let accuracyScore: Double    // 0.0 - 1.0
    public let speedScore: Double       // 0.0 - 1.0
    public let description: String
    public let isDefaultRecommended: Bool
    public let downloads: Int
    public let likes: Int
    
    public var sizeLabel: String {
        let mb = Double(sizeBytes) / 1_000_000.0
        if mb >= 1000.0 {
            return String(format: "%.1f GB", mb / 1000.0)
        } else {
            return String(format: "%.0f MB", mb)
        }
    }
    
    public init(
        identifier: String,
        displayName: String,
        author: String,
        format: String = "LiteRT-LM",
        sizeBytes: Int64,
        accuracyScore: Double = 0.95,
        speedScore: Double = 0.88,
        description: String,
        isDefaultRecommended: Bool = false,
        downloads: Int = 0,
        likes: Int = 0
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.author = author
        self.format = format
        self.sizeBytes = sizeBytes
        self.accuracyScore = accuracyScore
        self.speedScore = speedScore
        self.description = description
        self.isDefaultRecommended = isDefaultRecommended
        self.downloads = downloads
        self.likes = likes
    }
    
    // Default catalog of supported Google AI Edge / LiteRT models
    public static let recommendedCatalog: [ModelInfo] = [
        ModelInfo(
            identifier: "google/gemma-3n-E2B-it-litert-lm",
            displayName: "Google Gemma 3n E2B (LiteRT)",
            author: "google",
            format: "LiteRT-LM (.litertlm)",
            sizeBytes: 2_450_000_000, // ~2.45 GB INT4
            accuracyScore: 0.96,
            speedScore: 0.89,
            description: "Default recommended on-device model for iPhone 12. Multimodal audio comprehension & speech reasoning via Google AI Edge LiteRT.",
            isDefaultRecommended: true,
            downloads: 48500,
            likes: 1240
        ),
        ModelInfo(
            identifier: "google-ai-edge/gemma-3n-audio-scribe",
            displayName: "Google Gemma 3n Audio Scribe",
            author: "google-ai-edge",
            format: "LiteRT-LM",
            sizeBytes: 2_150_000_000, // ~2.15 GB
            accuracyScore: 0.93,
            speedScore: 0.95,
            description: "High-throughput audio scribe optimized for Apple Neural Engine. Fast 1.0-2.0s streaming response.",
            isDefaultRecommended: false,
            downloads: 18200,
            likes: 530
        ),
        ModelInfo(
            identifier: "google/gemma-3n-E2B-it-int8",
            displayName: "Google Gemma 3n E2B INT8",
            author: "google",
            format: "LiteRT-LM",
            sizeBytes: 3_800_000_000, // ~3.8 GB
            accuracyScore: 0.98,
            speedScore: 0.78,
            description: "High-precision 8-bit quantized LiteRT model for maximum transcription accuracy.",
            isDefaultRecommended: false,
            downloads: 12100,
            likes: 410
        )
    ]
}
