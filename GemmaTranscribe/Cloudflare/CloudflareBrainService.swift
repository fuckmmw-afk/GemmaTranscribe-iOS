//
//  CloudflareBrainService.swift
//  GemmaTranscribe
//
//  Sends clean text transcript to Cloudflare Worker or direct Cloudflare AI REST API
//  for AI structuring & Web search.
//  CRITICAL: Never sends audio to Cloudflare; sends only cleaned plaintext transcript.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "CloudflareBrainService")

public struct CloudflareBrainService: Sendable {
    
    public struct ResolvedEndpoint: Sendable {
        public let url: URL
        public let isDirectAI: Bool
        public let accountId: String?
        public let model: String
    }
    
    /// Normalizes and resolves user inputs (Account ID, partial URLs, Worker URLs) into a valid URL
    public static func resolveEndpoint() -> ResolvedEndpoint? {
        let mode = UserDefaults.standard.integer(forKey: AppConfig.cloudflareModeKey) // 0: Direct AI, 1: Custom Worker
        let rawUrl = (UserDefaults.standard.string(forKey: AppConfig.cloudflareWorkerUrlKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let accountId = (UserDefaults.standard.string(forKey: AppConfig.cloudflareAccountIdKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (UserDefaults.standard.string(forKey: AppConfig.cloudflareDirectModelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = model.isEmpty ? AppConfig.defaultCloudflareDirectModel : model
        
        // Mode 0: Direct Cloudflare Workers AI REST API
        if mode == 0 || rawUrl.contains("api.cloudflare.com") || (!accountId.isEmpty && !rawUrl.contains("workers.dev")) {
            // Find Account ID (either from accountId field or extracted from URL)
            var extractedAccount = accountId
            if extractedAccount.isEmpty {
                // Regex search for 32-hex character account ID in URL
                if let range = rawUrl.range(of: "(?<=accounts/)[a-fA-F0-9]{32}", options: .regularExpression) {
                    extractedAccount = String(rawUrl[range])
                } else if let hexRange = rawUrl.range(of: "[a-fA-F0-9]{32}", options: .regularExpression) {
                    extractedAccount = String(rawUrl[hexRange])
                }
            }
            
            if !extractedAccount.isEmpty {
                // Standard Cloudflare Workers AI REST endpoint:
                // https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run/@cf/meta/llama-3.1-8b-instruct
                let resolvedString = "https://api.cloudflare.com/client/v4/accounts/\(extractedAccount)/ai/run/\(effectiveModel)"
                if let validUrl = URL(string: resolvedString) {
                    return ResolvedEndpoint(url: validUrl, isDirectAI: true, accountId: extractedAccount, model: effectiveModel)
                }
            }
            
            // If rawUrl already has /ai/run/
            if rawUrl.contains("/ai/run/") {
                var normalized = rawUrl
                if !normalized.contains("/client/v4/") {
                    normalized = normalized.replacingOccurrences(of: "api.cloudflare.com/", with: "api.cloudflare.com/client/v4/")
                }
                if let validUrl = URL(string: normalized) {
                    return ResolvedEndpoint(url: validUrl, isDirectAI: true, accountId: extractedAccount.isEmpty ? nil : extractedAccount, model: effectiveModel)
                }
            }
        }
        
        // Mode 1: Custom Cloudflare Worker
        let workerString = rawUrl.isEmpty ? AppConfig.defaultCloudflareWorkerUrl : rawUrl
        if let customUrl = URL(string: workerString) {
            return ResolvedEndpoint(url: customUrl, isDirectAI: false, accountId: nil, model: effectiveModel)
        }
        
        return nil
    }
    
    public static func process(cleanTranscript: String, locale: String = "ru") async throws -> CloudflareBrainResponse {
        guard !cleanTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CloudflareBrainResponse(
                summary: "Пустая стенограмма",
                cards: [],
                actionPoints: [],
                webSearch: nil,
                model: "none",
                searched: false
            )
        }
        
        guard let endpoint = resolveEndpoint() else {
            logger.warning("Could not resolve Cloudflare endpoint, using local fallback")
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        }
        
        let apiKey = (UserDefaults.standard.string(forKey: AppConfig.cloudflareApiKeyKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        if endpoint.isDirectAI {
            return try await processDirectWorkersAI(
                cleanTranscript: cleanTranscript,
                endpoint: endpoint,
                apiKey: apiKey,
                locale: locale
            )
        } else {
            return try await processCustomWorker(
                cleanTranscript: cleanTranscript,
                endpoint: endpoint,
                apiKey: apiKey,
                locale: locale
            )
        }
    }
    
    // MARK: - Direct Workers AI Execution
    
    private static func processDirectWorkersAI(
        cleanTranscript: String,
        endpoint: ResolvedEndpoint,
        apiKey: String,
        locale: String
    ) async throws -> CloudflareBrainResponse {
        logger.info("Executing Direct Cloudflare Workers AI request to: \(endpoint.url.absoluteString, privacy: .public)")
        
        // 1. On-device Wikipedia search for contextual enrichment
        let searchQuery = extractSearchQuery(from: cleanTranscript)
        let webCitation = await performWikipediaSearch(query: searchQuery, locale: locale)
        
        let searchContext = webCitation != nil
            ? "Дополнительная справка из Wikipedia:\nНазвание: \(webCitation!.title)\nОписание: \(webCitation!.snippet)\nURL: \(webCitation!.url)\n\n"
            : ""
        
        let systemPrompt = """
        Ты — экспертный аналитический AI-ассистент в приложении GemmaTranscribe.
        Твоя задача — получить стенограмму речи, структурировать её и вернуть ответ СТРОГО в валидном JSON виде:
        {
          "summary": "Краткое саммари всей речи (1-2 емких предложения)",
          "cards": [
            {
              "term": "Ключевое понятие или тезис",
              "definition": "Четкое и понятное определение или факт",
              "notes": ["Важная деталь", "Контекст"],
              "source": "Название источника или Wikipedia"
            }
          ],
          "actionPoints": ["Конкретный пункт действия"]
        }
        Не добавляй никакого вводного текста до или после JSON. Язык ответа: \(locale.hasPrefix("en") ? "English" : "Russian").
        """
        
        let userPrompt = "\(searchContext)Стенограмма речи:\n\"\(cleanTranscript)\""
        
        let payload: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": 1024,
            "temperature": 0.2
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        }
        
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = httpBody
        request.timeoutInterval = 35.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
            }
            
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw NSError(domain: "CloudflareBrainService", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Ошибка авторизации Cloudflare (HTTP \(httpResponse.statusCode)). Проверьте API Token (Bearer)."
                ])
            }
            
            if httpResponse.statusCode == 400 {
                let errText = String(data: data, encoding: .utf8) ?? ""
                logger.error("Cloudflare AI HTTP 400: \(errText, privacy: .public)")
                if errText.contains("7003") {
                    throw NSError(domain: "CloudflareBrainService", code: 7003, userInfo: [
                        NSLocalizedDescriptionKey: "Ошибка маршрутизации Cloudflare (7003). Проверьте корректность Account ID."
                    ])
                }
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let responseText = result["response"] as? String {
                
                if let parsedResponse = parseJsonModelResponse(responseText, searchResult: webCitation, model: endpoint.model) {
                    return parsedResponse
                }
            }
            
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        } catch {
            logger.warning("Direct Workers AI call failed: \(error.localizedDescription), using local fallback")
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        }
    }
    
    // MARK: - Custom Cloudflare Worker Execution
    
    private static func processCustomWorker(
        cleanTranscript: String,
        endpoint: ResolvedEndpoint,
        apiKey: String,
        locale: String
    ) async throws -> CloudflareBrainResponse {
        let payload: [String: Any] = [
            "raw_transcript": cleanTranscript,
            "locale": locale
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        }
        
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = httpBody
        request.timeoutInterval = 30.0
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        }
        
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw NSError(domain: "CloudflareBrainService", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Ошибка авторизации Cloudflare Worker (HTTP \(httpResponse.statusCode))."
            ])
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CloudflareBrainResponse.self, from: data)
    }
    
    // MARK: - Connection Diagnostics
    
    public static func testConnection() async -> (success: Bool, message: String) {
        guard let endpoint = resolveEndpoint() else {
            return (false, "Не удалось определить адрес эндпоинта. Укажите Account ID или URL воркера.")
        }
        
        let apiKey = (UserDefaults.standard.string(forKey: AppConfig.cloudflareApiKeyKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 12.0
        
        if endpoint.isDirectAI {
            let directPayload: [String: Any] = [
                "messages": [
                    ["role": "user", "content": "ping"]
                ],
                "max_tokens": 5
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: directPayload)
        } else {
            let workerPayload: [String: Any] = [
                "raw_transcript": "Тест подключения к воркеру",
                "locale": "ru"
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: workerPayload)
        }
        
        do {
            let start = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Нет ответа от сервера")
            }
            
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return (false, "Ошибка авторизации (HTTP \(httpResponse.statusCode)). Проверьте API Token (Bearer).")
            }
            
            if httpResponse.statusCode == 400 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errors = json["errors"] as? [[String: Any]],
                   let firstErr = errors.first {
                    let code = firstErr["code"] as? Int ?? 400
                    let msg = firstErr["message"] as? String ?? "Bad Request"
                    if code == 7003 {
                        return (false, "Ошибка 7003: Неверный путь или Account ID. Проверьте 32-значный Account ID: \(msg)")
                    } else if code == 10000 {
                        return (false, "Ошибка 10000: Неверный API Token Cloudflare.")
                    }
                    return (false, "Ошибка Cloudflare [\(code)]: \(msg)")
                }
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                let targetDesc = endpoint.isDirectAI ? "Workers AI (\(endpoint.model))" : "Cloudflare Worker"
                return (true, "Успешно! Подключено к \(targetDesc) (\(latencyMs) мс)")
            } else {
                let errSnippet = String(data: data.prefix(120), encoding: .utf8) ?? ""
                return (false, "HTTP \(httpResponse.statusCode): \(errSnippet)")
            }
        } catch {
            return (false, "Сбой соединения: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helpers
    
    private static func extractSearchQuery(from text: String) -> String {
        let words = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
        return words.prefix(3).joined(separator: " ")
    }
    
    private static func performWikipediaSearch(query: String, locale: String) async -> WebSearchCitation? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let domain = locale.hasPrefix("en") ? "en.wikipedia.org" : "ru.wikipedia.org"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://\(domain)/w/api.php?action=opensearch&search=\(encoded)&limit=1&namespace=0&format=json") else {
            return nil
        }
        
        var req = URLRequest(url: url)
        req.setValue("GemmaTranscribe/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 6.0
        
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 4,
              let titles = json[1] as? [String], !titles.isEmpty,
              let snippets = json[2] as? [String],
              let urls = json[3] as? [String] else {
            return nil
        }
        
        return WebSearchCitation(
            query: query,
            title: titles.first ?? query,
            snippet: snippets.first ?? "",
            url: urls.first ?? "https://\(domain)/wiki/\(encoded)"
        )
    }
    
    private static func parseJsonModelResponse(_ responseText: String, searchResult: WebSearchCitation?, model: String) -> CloudflareBrainResponse? {
        guard let start = responseText.range(of: "{"),
              let end = responseText.range(of: "}", options: .backwards) else {
            return nil
        }
        
        let jsonStr = String(responseText[start.lowerBound...end.upperBound])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        let summary = json["summary"] as? String ?? ""
        var cards: [DefinitionCard] = []
        if let rawCards = json["cards"] as? [[String: Any]] {
            for c in rawCards {
                let term = c["term"] as? String ?? "Ключевой тезис"
                let def = c["definition"] as? String ?? ""
                let notes = c["notes"] as? [String] ?? []
                let source = c["source"] as? String ?? (searchResult?.url ?? "")
                cards.append(DefinitionCard(term: term, definition: def, notes: notes, source: source))
            }
        }
        
        let actionPoints = json["actionPoints"] as? [String] ?? (json["action_points"] as? [String] ?? [])
        
        return CloudflareBrainResponse(
            summary: summary,
            cards: cards,
            actionPoints: actionPoints,
            webSearch: searchResult,
            model: model,
            searched: searchResult != nil
        )
    }
    
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
