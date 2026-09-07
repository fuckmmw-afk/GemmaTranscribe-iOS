//
//  HuggingFaceSearchService.swift
//  GemmaTranscribe
//
//  Searches Hugging Face model hub for compatible LiteRT / Gemma models.
//

import Foundation

public struct HuggingFaceSearchService: Sendable {
    
    public struct HFModelItem: Codable, Sendable {
        public let id: String
        public let author: String?
        public let downloads: Int?
        public let likes: Int?
        public let tags: [String]?
    }
    
    public static func search(query: String) async throws -> [ModelInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchQuery = trimmed.isEmpty ? "litert" : trimmed
        
        guard let encodedQuery = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://huggingface.co/api/models?search=\(encodedQuery)&limit=20") else {
            return []
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15.0
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            return []
        }
        
        let decoder = JSONDecoder()
        let items = (try? decoder.decode([HFModelItem].self, from: data)) ?? []
        
        return items.map { item in
            let authorName = item.author ?? (item.id.contains("/") ? String(item.id.split(separator: "/")[0]) : "community")
            let modelName = item.id.contains("/") ? String(item.id.split(separator: "/")[1]) : item.id
            
            return ModelInfo(
                identifier: item.id,
                displayName: modelName.replacingOccurrences(of: "-", with: " ").capitalized,
                author: authorName,
                format: "LiteRT-LM",
                sizeBytes: 2_400_000_000,
                accuracyScore: 0.90,
                speedScore: 0.85,
                description: "Hugging Face model '\(item.id)' for LiteRT on-device inference.",
                isDefaultRecommended: item.id == AppConfig.defaultModelId,
                downloads: item.downloads ?? 0,
                likes: item.likes ?? 0
            )
        }
    }
}
