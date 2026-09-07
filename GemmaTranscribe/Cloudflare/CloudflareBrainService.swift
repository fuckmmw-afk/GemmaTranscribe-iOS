//
//  CloudflareBrainService.swift
//  GemmaTranscribe
//
//  Sends clean text transcript to Cloudflare Worker for AI structuring & Web search.
//  CRITICAL: Never sends audio to Cloudflare; sends only cleaned text transcript.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "CloudflareBrainService")

public struct CloudflareBrainService: Sendable {
    
    public static func process(cleanTranscript: String, locale: String = "ru") async throws -> CloudflareBrainResponse {
        guard !cleanTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CloudflareBrainResponse(
                summary: "Empty transcript",
                cards: [],
                actionPoints: [],
                webSearch: nil,
                model: "none",
                searched: false
            )
        }
        
        let workerUrlString = UserDefaults.standard.string(forKey: AppConfig.cloudflareWorkerUrlKey) ?? AppConfig.defaultCloudflareWorkerUrl
        guard let url = URL(string: workerUrlString) else {
            logger.error("Invalid Cloudflare worker URL: \(workerUrlString, privacy: .public)")
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        }
        
        let payload: [String: Any] = [
            "raw_transcript": cleanTranscript,
            "locale": locale
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = httpBody
        request.timeoutInterval = 30.0
        
        logger.info("Sending clean transcript (\(cleanTranscript.count) chars) to Cloudflare Worker")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                logger.warning("Cloudflare worker returned non-200 HTTP code, using local fallback")
                return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
            }
            
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let brainResponse = try decoder.decode(CloudflareBrainResponse.self, from: data)
            logger.info("Cloudflare processing complete: \(brainResponse.cards?.count ?? 0) cards generated")
            return brainResponse
        } catch {
            logger.warning("Cloudflare worker connection failed: \(error.localizedDescription), using local fallback")
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        }
    }
    
    /// Local fallback in case device is offline or Cloudflare Worker is temporarily unreachable
    private static func fallbackLocalEnrichment(cleanTranscript: String) -> CloudflareBrainResponse {
        let words = cleanTranscript.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 3 }
        let topEntity = words.first ?? "Тема записи"
        
        let card = DefinitionCard(
            term: topEntity.capitalized,
            definition: "Автоматически извлеченный тезис из стенограммы.",
            notes: ["Обработано локальным анализатором речи."],
            source: "https://ru.wikipedia.org/wiki/\(topEntity.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        )
        
        return CloudflareBrainResponse(
            summary: cleanTranscript.prefix(160) + (cleanTranscript.count > 160 ? "..." : ""),
            cards: [card],
            actionPoints: ["Ознакомиться с деталями стенограммы"],
            webSearch: WebSearchCitation(
                query: topEntity,
                title: "Поиск по ключевому понятию",
                snippet: "Поиск в свободной энциклопедии по термину '\(topEntity)'",
                url: "https://ru.wikipedia.org/wiki/\(topEntity.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            ),
            model: "Local Offline Fallback",
            searched: true
        )
    }
}
