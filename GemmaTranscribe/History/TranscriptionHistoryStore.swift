//
//  TranscriptionHistoryStore.swift
//  GemmaTranscribe
//
//  Completely local storage for transcription history.
//  No iCloud, no external accounts, no cloud sync.
//  Adapted from Dictus TranscriptionHistoryStore.
//

import Foundation
import Combine
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "HistoryStore")

@MainActor
public final class TranscriptionHistoryStore: ObservableObject {
    public static let shared = TranscriptionHistoryStore()
    
    @Published public private(set) var records: [TranscriptionRecord] = []
    
    private let fileURL: URL
    
    public init(fileURL: URL = AppConfig.historyFileURL) {
        self.fileURL = fileURL
        loadFromDisk()
    }
    
    public func append(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        saveToDisk()
        logger.info("Saved transcription record \(record.id, privacy: .public)")
    }
    
    public func delete(id: UUID) {
        records.removeAll { $0.id == id }
        saveToDisk()
        logger.info("Deleted transcription record \(id, privacy: .public)")
    }
    
    public func delete(atOffsets offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        saveToDisk()
    }
    
    public func clearAll() {
        records.removeAll()
        saveToDisk()
        logger.info("Cleared all transcription history")
    }
    
    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([TranscriptionRecord].self, from: data)
            logger.info("Loaded \(self.records.count) history records from disk")
        } catch {
            logger.error("Failed to load history from disk: \(error.localizedDescription)")
            records = []
        }
    }
    
    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("Failed to save history to disk: \(error.localizedDescription)")
        }
    }
}
