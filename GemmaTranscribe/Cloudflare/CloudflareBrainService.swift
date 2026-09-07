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
        
        let workerUrlString = UserDefaults.standard.string(forKey: AppConfig.cloudflareWorkerUrlKey) ?? AppConfig.defaultCloudflareWorkerUrl
        let apiKey = UserDefaults.standard.string(forKey: AppConfig.cloudflareApiKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let accountId = UserDefaults.standard.string(forKey: AppConfig.cloudflareAccountIdKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        // Determine if direct Cloudflare Workers AI REST API is being called
        if workerUrlString.contains("api.cloudflare.com") || (!accountId.isEmpty && workerUrlString.contains("accounts/")) {
            return try await processDirectCloudflareAI(
                cleanTranscript: cleanTranscript,
                urlString: workerUrlString,
                apiKey: apiKey,
                accountId: accountId,
                locale: locale
            )
        }
        
        // Custom Cloudflare Worker pipeline
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
        
        // Attach Bearer Authentication if API Key is configured
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = httpBody
        request.timeoutInterval = 30.0
        
        logger.info("Sending clean transcript (\(cleanTranscript.count) chars) to Cloudflare Worker (Auth=\(!apiKey.isEmpty))")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
            }
            
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                logger.error("Cloudflare Worker authentication failed (HTTP \(httpResponse.statusCode))")
                throw NSError(domain: "CloudflareBrainService", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Ошибка авторизации Cloudflare (HTTP \(httpResponse.statusCode)). Проверьте API Key в настройках."
                ])
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                logger.warning("Cloudflare worker returned HTTP \(httpResponse.statusCode), using local fallback")
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
    
    /// Direct call to Cloudflare Workers AI REST API: https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run/@cf/meta/llama-3.1-8b-instruct
    private static func processDirectCloudflareAI(
        cleanTranscript: String,
        urlString: String,
        apiKey: String,
        accountId: String,
        locale: String
    ) async throws -> CloudflareBrainResponse {
        var resolvedUrlString = urlString
        if resolvedUrlString.contains("{account_id}") && !accountId.isEmpty {
            resolvedUrlString = resolvedUrlString.replacingOccurrences(of: "{account_id}", with: accountId)
        }
        
        guard let url = URL(string: resolvedUrlString) else {
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        }
        
        let systemPrompt = """
        Ты — аналитический AI-ассистент в приложении GemmaTranscribe.
        Структурируй стенограмму и верни ответ СТРОГО в валидном JSON виде:
        {
          "summary": "Краткое саммари (1-2 предложения)",
          "cards": [
            {
              "term": "Ключевое понятие или тезис",
              "definition": "Четкое определение или факт",
              "notes": ["Важная деталь", "Контекст"],
              "source": "Источник или Wikipedia"
            }
          ],
          "actionPoints": ["Пункт действия 1"]
        }
        Не добавляй текст до или после JSON.
        """
        
        let messagesPayload: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": "Стенограмма речи:\n\(cleanTranscript)"]
        ]
        
        let body: [String: Any] = [
            "messages": messagesPayload,
            "max_tokens": 800
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
                NSLocalizedDescriptionKey: "Ошибка авторизации Cloudflare AI (HTTP \(httpResponse.statusCode)). Проверьте API Key и Account ID."
            ])
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? [String: Any],
           let responseText = result["response"] as? String {
            
            // Extract json substring
            if let start = responseText.range(of: "{"),
               let end = responseText.range(of: "}", options: .backwards) {
                let jsonStr = String(responseText[start.lowerBound...end.upperBound])
                if let parsedData = jsonStr.data(using: .utf8) {
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    if let parsed = try? decoder.decode(CloudflareBrainResponse.self, from: parsedData) {
                        return parsed
                    }
                }
            }
        }
        
        return fallbackLocalEnrichment(cleanTranscript: cleanTranscript)
    }
    
    /// Tests the connection to Cloudflare endpoint
    public static func testConnection() async -> (success: Bool, message: String) {
        let workerUrlString = UserDefaults.standard.string(forKey: AppConfig.cloudflareWorkerUrlKey) ?? AppConfig.defaultCloudflareWorkerUrl
        let apiKey = UserDefaults.standard.string(forKey: AppConfig.cloudflareApiKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        guard let url = URL(string: workerUrlString) else {
            return (false, "Неверный URL эндпоинта")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let testPayload: [String: Any] = [
            "raw_transcript": "Тестовое подключение к Cloudflare AI",
            "locale": "ru"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: testPayload)
        request.timeoutInterval = 10.0
        
        do {
            let start = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Нет ответа от сервера")
            }
            
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return (false, "Ошибка авторизации (HTTP \(httpResponse.statusCode)). Неверный API Key.")
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                return (true, "Успешно! Подключено к Cloudflare (\(latencyMs) мс)")
            } else {
                let errSnippet = String(data: data.prefix(120), encoding: .utf8) ?? ""
                return (false, "HTTP \(httpResponse.statusCode): \(errSnippet)")
            }
        } catch {
            return (false, "Сбой соединения: \(error.localizedDescription)")
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
