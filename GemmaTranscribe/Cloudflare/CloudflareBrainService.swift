//
//  CloudflareBrainService.swift
//  GemmaTranscribe
//
//  Cloudflare Workers AI backend & contextual search pipeline:
//  1. Analyzes speech context and identifies true user intent (dictation vs. search request).
//  2. Decouples search intent from raw transcript: never searches blindly on pure dictation.
//  3. When search intent is detected, invokes SearchProvider with refined semantic query.
//  4. Synthesizes structured knowledge cards, clean summary, and action items.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "CloudflareBrainService")

// MARK: - Modular Search Provider Protocol

public protocol SearchProvider: Sendable {
    func search(query: String, locale: String) async -> WebSearchCitation?
}

public struct WikipediaSearchProvider: SearchProvider {
    public init() {}
    
    public func search(query: String, locale: String) async -> WebSearchCitation? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }
        
        let domain = locale.hasPrefix("en") ? "en.wikipedia.org" : "ru.wikipedia.org"
        guard let encodedQuery = trimmedQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        
        // Step 1: Full-text search for the most relevant article
        guard let searchURL = URL(string: "https://\(domain)/w/api.php?action=query&list=search&srsearch=\(encodedQuery)&utf8=1&format=json&srlimit=1") else {
            return nil
        }
        
        var searchReq = URLRequest(url: searchURL)
        searchReq.setValue("GemmaTranscribe/1.0 (iOS; Speech Intelligence)", forHTTPHeaderField: "User-Agent")
        searchReq.timeoutInterval = 7.0
        
        guard let (searchData, _) = try? await URLSession.shared.data(for: searchReq),
              let searchJson = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let queryObj = searchJson["query"] as? [String: Any],
              let searchResults = queryObj["search"] as? [[String: Any]],
              let firstMatch = searchResults.first,
              let foundTitle = firstMatch["title"] as? String else {
            return nil
        }
        
        let rawSnippet = firstMatch["snippet"] as? String ?? ""
        let cleanedSnippet = rawSnippet
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Step 2: Fetch rich plain-text extract for this exact title
        var fullDefinition = cleanedSnippet
        if let encodedTitle = foundTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let extractURL = URL(string: "https://\(domain)/w/api.php?action=query&prop=extracts&exintro=1&explaintext=1&titles=\(encodedTitle)&format=json") {
            
            var extReq = URLRequest(url: extractURL)
            extReq.setValue("GemmaTranscribe/1.0 (iOS; Speech Intelligence)", forHTTPHeaderField: "User-Agent")
            extReq.timeoutInterval = 7.0
            
            if let (extData, _) = try? await URLSession.shared.data(for: extReq),
               let extJson = try? JSONSerialization.jsonObject(with: extData) as? [String: Any],
               let extQuery = extJson["query"] as? [String: Any],
               let pages = extQuery["pages"] as? [String: Any] {
                
                for (_, pageVal) in pages {
                    if let pageDict = pageVal as? [String: Any],
                       let extractText = pageDict["extract"] as? String,
                       !extractText.isEmpty {
                        let sentences = extractText.components(separatedBy: ". ")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        if !sentences.isEmpty {
                            fullDefinition = sentences.prefix(3).joined(separator: ". ")
                            if !fullDefinition.hasSuffix(".") { fullDefinition += "." }
                        }
                        break
                    }
                }
            }
        }
        
        let articleUrl = "https://\(domain)/wiki/\(foundTitle.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")"
        
        logger.info("SearchProvider found: '\(foundTitle, privacy: .public)' (Snippet: \(fullDefinition.prefix(40), privacy: .public)...)")
        
        return WebSearchCitation(
            query: trimmedQuery,
            title: foundTitle,
            snippet: fullDefinition,
            url: articleUrl
        )
    }
}

// MARK: - Cloudflare Brain Service

public enum CloudflareBrainService {
    
    public static var searchProvider: SearchProvider = WikipediaSearchProvider()
    
    public struct ResolvedEndpoint {
        public let url: URL
        public let isDirectAI: Bool
        public let accountId: String?
        public let model: String
    }
    
    // MARK: - API Key Cleaning & Normalization
    
    public static func cleanApiKey(_ rawKey: String) -> String {
        var token = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if (token.hasPrefix("\"") && token.hasSuffix("\"")) || (token.hasPrefix("'") && token.hasSuffix("'")) {
            token = String(token.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return token
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
            var extractedAccount = accountId
            if extractedAccount.isEmpty {
                if let range = rawUrl.range(of: "(?<=accounts/)[a-fA-F0-9]{32}", options: .regularExpression) {
                    extractedAccount = String(rawUrl[range])
                } else if let hexRange = rawUrl.range(of: "[a-fA-F0-9]{32}", options: .regularExpression) {
                    extractedAccount = String(rawUrl[hexRange])
                }
            }
            
            if !extractedAccount.isEmpty {
                let resolvedString = "https://api.cloudflare.com/client/v4/accounts/\(extractedAccount)/ai/run/\(effectiveModel)"
                if let validUrl = URL(string: resolvedString) {
                    return ResolvedEndpoint(url: validUrl, isDirectAI: true, accountId: extractedAccount, model: effectiveModel)
                }
            }
            
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
    
    private static func applyAuthHeaders(to request: inout URLRequest) {
        let rawKey = UserDefaults.standard.string(forKey: AppConfig.cloudflareApiKeyKey) ?? ""
        let cleanKey = cleanApiKey(rawKey)
        guard !cleanKey.isEmpty else { return }
        
        let email = (UserDefaults.standard.string(forKey: AppConfig.cloudflareEmailKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Cloudflare Global API Key format: 'cfk_...' or 37-hex characters with email
        if cleanKey.hasPrefix("cfk_") || !email.isEmpty {
            if !email.isEmpty {
                request.setValue(email, forHTTPHeaderField: "X-Auth-Email")
                request.setValue(cleanKey, forHTTPHeaderField: "X-Auth-Key")
                return
            }
        }
        
        // Scoped API Token format (Bearer)
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
    }
    
    /// Cloudflare Workers AI speech transcription via @cf/openai/whisper
    public static func transcribeAudio(wavData: Data) async throws -> String {
        guard let resolved = resolveEndpoint(), let accountId = resolved.accountId, !accountId.isEmpty else {
            throw NSError(domain: "GemmaTranscribe.CloudflareWhisper", code: 400, userInfo: [NSLocalizedDescriptionKey: "Cloudflare Account ID не указан в настройках"])
        }
        
        let whisperUrl = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountId)/ai/run/@cf/openai/whisper")!
        var request = URLRequest(url: whisperUrl)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthHeaders(to: &request)
        request.httpBody = wavData
        
        logger.info("Sending audio to Cloudflare Whisper: \(wavData.count) bytes")
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 500)"
            logger.error("Cloudflare Whisper error: \(errorText)")
            throw NSError(domain: "GemmaTranscribe.CloudflareWhisper", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        
        struct WhisperApiResponse: Codable {
            let result: WhisperResult?
            struct WhisperResult: Codable {
                let text: String?
            }
        }
        
        let decoded = try JSONDecoder().decode(WhisperApiResponse.self, from: data)
        let transcribed = decoded.result?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        logger.info("Cloudflare Whisper recognized text: \(transcribed.prefix(50))...")
        return transcribed
    }

    /// Processes the cleaned transcript:
    /// - Evaluates intent: determines if search is actually needed or if it's pure dictation.
    /// - Fetches contextual web knowledge only when appropriate.
    /// - Generates accurate summary and structured concept cards.
    public static func process(cleanTranscript: String, locale: String = "ru") async throws -> CloudflareBrainResponse {
        let trimmed = cleanTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
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
            logger.warning("Could not resolve Cloudflare endpoint, using local intent enrichment")
            return await fallbackLocalEnrichment(cleanTranscript: trimmed, locale: locale)
        }
        
        if endpoint.isDirectAI {
            return try await processDirectWorkersAI(
                cleanTranscript: trimmed,
                endpoint: endpoint,
                locale: locale
            )
        } else {
            return try await processCustomWorker(
                cleanTranscript: trimmed,
                endpoint: endpoint,
                locale: locale
            )
        }
    }
    
    // MARK: - Direct Workers AI Execution with Context-Aware Search Intent
    
    private static func processDirectWorkersAI(
        cleanTranscript: String,
        endpoint: ResolvedEndpoint,
        locale: String
    ) async throws -> CloudflareBrainResponse {
        logger.info("Executing Context-Aware Workers AI request to: \(endpoint.url.absoluteString, privacy: .public)")
        
        let systemPrompt = """
        Ты — аналитический AI-ассистент в приложении GemmaTranscribe.
        Твоя задача — внимательно изучить очищенную стенограмму речи пользователя и сформировать структурированный результат.

        КРИТИЧЕСКИЕ ПРАВИЛА:
        1. Определение поискового интента ("needs_search"):
           - Установи "needs_search": true ТОЛЬКО если пользователь прямо задаёт вопрос («Что такое...», «Кто такой...», «Расскажи про...») или явно просит найти информацию («Поищи в интернете...»).
           - Установи "needs_search": false, если пользователь просто надиктовывает свои мысли, конспект, лекцию или рабочий материал (например, фраза «Я буду начитывать материал» НЕ ЯВЛЯЕТСЯ поисковым запросом!).
           - Если "needs_search": true, укажи в "search_query" точное ключевое понятие или имя сущности (например: "Квантовая запутанность", "Илон Маск"). Никаких случайных обрывков фраз!
           - Если "needs_search": false, значение "search_query" должно быть null.
        
        2. Резюме ("summary"):
           - Сформулируй 1-3 связных предложения с сутью сказанного пользователем на русском языке.
        
        3. Карточки понятий ("cards"):
           - 1-3 понятных карточки по теме речи:
             "term": точное название термина (НЕ одно слово наугад, а полный термин);
             "definition": чёткое правильное определение, сохраняющее исходный смысл;
             "notes": 2-3 ключевых тезиса;
             "source": источник или ссылка (если есть).
        
        4. Действия/выводы ("actionPoints"):
           - 1-3 практических пункта или вывода из стенограммы.

        Верни ответ СТРОГО в виде валидного JSON без markdown-блоков:
        {
          "intent": "dictation | question | search_request",
          "needs_search": false,
          "search_query": null,
          "summary": "...",
          "cards": [
            {
              "term": "...",
              "definition": "...",
              "notes": ["..."],
              "source": "..."
            }
          ],
          "actionPoints": ["..."]
        }
        Язык ответа: \(locale.hasPrefix("en") ? "English" : "Russian").
        """
        
        let userPrompt = "Стенограмма речи:\n\"\(cleanTranscript)\""
        
        let payload: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": 1024,
            "temperature": 0.2
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            return await fallbackLocalEnrichment(cleanTranscript: cleanTranscript, locale: locale)
        }
        
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request)
        request.httpBody = httpBody
        request.timeoutInterval = 35.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return await fallbackLocalEnrichment(cleanTranscript: cleanTranscript, locale: locale)
            }
            
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                logger.error("Cloudflare authorization failed (HTTP \(httpResponse.statusCode))")
                return await fallbackLocalEnrichment(cleanTranscript: cleanTranscript, locale: locale)
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                logger.warning("Cloudflare HTTP \(httpResponse.statusCode), using local enrichment")
                return await fallbackLocalEnrichment(cleanTranscript: cleanTranscript, locale: locale)
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let responseText = result["response"] as? String {
                
                if let parsedResponse = await parseJsonModelResponse(responseText, cleanTranscript: cleanTranscript, model: endpoint.model, locale: locale) {
                    return parsedResponse
                }
            }
            
            return await fallbackLocalEnrichment(cleanTranscript: cleanTranscript, locale: locale)
        } catch {
            logger.warning("Direct Workers AI call failed: \(error.localizedDescription), using local intent enrichment")
            return await fallbackLocalEnrichment(cleanTranscript: cleanTranscript, locale: locale)
        }
    }
    
    // MARK: - Custom Cloudflare Worker Execution
    
    private static func processCustomWorker(
        cleanTranscript: String,
        endpoint: ResolvedEndpoint,
        locale: String
    ) async throws -> CloudflareBrainResponse {
        let payload: [String: Any] = [
            "raw_transcript": cleanTranscript,
            "locale": locale
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            return await fallbackLocalEnrichment(cleanTranscript: cleanTranscript, locale: locale)
        }
        
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthHeaders(to: &request)
        request.httpBody = httpBody
        request.timeoutInterval = 30.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return await fallbackLocalEnrichment(cleanTranscript: cleanTranscript, locale: locale)
            }
            
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let brainResponse = try decoder.decode(CloudflareBrainResponse.self, from: data)
            return brainResponse
        } catch {
            return await fallbackLocalEnrichment(cleanTranscript: cleanTranscript, locale: locale)
        }
    }
    
    // MARK: - Connection Diagnostics
    
    public static func testConnection() async -> (success: Bool, message: String) {
        guard let endpoint = resolveEndpoint() else {
            return (false, "Не удалось определить адрес эндпоинта. Укажите Account ID или URL воркера.")
        }
        
        let rawKey = UserDefaults.standard.string(forKey: AppConfig.cloudflareApiKeyKey) ?? ""
        let cleanKey = cleanApiKey(rawKey)
        let email = (UserDefaults.standard.string(forKey: AppConfig.cloudflareEmailKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanKey.isEmpty else {
            return (false, "Не заполнен API Key Cloudflare.")
        }
        
        let isGlobalKey = cleanKey.hasPrefix("cfk_") || (cleanKey.count == 37 && cleanKey.range(of: "^[a-fA-F0-9]{37}$", options: .regularExpression) != nil)
        
        if isGlobalKey && email.isEmpty {
            return (false, "Ключ '\(cleanKey.prefix(4))...' — это Global API Key. Для него обязательно заполните Email вашей учетной записи Cloudflare в Настройках. Либо создайте API Token в dash.cloudflare.com/profile/api-tokens.")
        }
        
        if !isGlobalKey && email.isEmpty && endpoint.isDirectAI {
            if let tokenVerification = await verifyTokenValidity(cleanKey) {
                if !tokenVerification.isValid {
                    return (false, "Cloudflare отклонил токен: \(tokenVerification.detail). Убедитесь, что токен скопирован без лишних символов.")
                }
            }
        }
        
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request)
        request.timeoutInterval = 15.0
        
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
                return (false, "Нет ответа от сервера Cloudflare")
            }
            
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                if isGlobalKey {
                    return (false, "Ошибка 401: Неверный Global API Key или не совпадает Email учетной записи.")
                } else {
                    return (false, "Ошибка 401: Токен не имеет прав для Workers AI на аккаунте \(endpoint.accountId ?? ""). В dash.cloudflare.com -> API Tokens добавьте разрешение: Account -> Workers AI -> Edit.")
                }
            }
            
            if httpResponse.statusCode == 400 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errors = json["errors"] as? [[String: Any]],
                   let firstErr = errors.first {
                    let code = firstErr["code"] as? Int ?? 400
                    let msg = firstErr["message"] as? String ?? "Bad Request"
                    if code == 7003 {
                        return (false, "Ошибка 7003: Неверный Account ID. Проверьте 32-значный хэш: \(msg)")
                    }
                    return (false, "Ошибка Cloudflare [\(code)]: \(msg)")
                }
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                let targetDesc = endpoint.isDirectAI ? "Workers AI (\(endpoint.model))" : "Cloudflare Worker"
                let authMethod = isGlobalKey ? "Global Key" : "API Token"
                return (true, "Успешно! Подключено к \(targetDesc) через \(authMethod) (\(latencyMs) мс)")
            } else {
                let errSnippet = String(data: data.prefix(140), encoding: .utf8) ?? ""
                return (false, "HTTP \(httpResponse.statusCode): \(errSnippet)")
            }
        } catch {
            return (false, "Сбой соединения: \(error.localizedDescription)")
        }
    }
    
    private static func verifyTokenValidity(_ cleanToken: String) async -> (isValid: Bool, detail: String)? {
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/user/tokens/verify") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8.0
        
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else {
            return nil
        }
        
        if http.statusCode == 200 {
            return (true, "Токен активен")
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = json["errors"] as? [[String: Any]],
           let first = errors.first,
           let msg = first["message"] as? String {
            return (false, msg)
        }
        
        return (false, "HTTP \(http.statusCode)")
    }
    
    // MARK: - JSON Response Parsing & Search Intent Resolution
    
    private static func parseJsonModelResponse(
        _ responseText: String,
        cleanTranscript: String,
        model: String,
        locale: String
    ) async -> CloudflareBrainResponse? {
        var clean = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```json") {
            clean = String(clean.dropFirst(7))
        } else if clean.hasPrefix("```") {
            clean = String(clean.dropFirst(3))
        }
        if clean.hasSuffix("```") {
            clean = String(clean.dropLast(3))
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let start = clean.range(of: "{"),
              let end = clean.range(of: "}", options: .backwards) else {
            return nil
        }
        
        let jsonStr = String(clean[start.lowerBound...end.upperBound])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        let needsSearch = (json["needs_search"] as? Bool) ?? (json["needsSearch"] as? Bool) ?? false
        let rawQuery = (json["search_query"] as? String) ?? (json["searchQuery"] as? String)
        let searchQuery = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        var webSearchCitation: WebSearchCitation? = nil
        var didSearch = false
        
        // Execute Search ONLY if the model specifically detected a search intent and provided a valid query
        if needsSearch && !searchQuery.isEmpty {
            logger.info("Contextual search intent detected: query='\(searchQuery, privacy: .public)'")
            webSearchCitation = await searchProvider.search(query: searchQuery, locale: locale)
            didSearch = (webSearchCitation != nil)
        } else {
            logger.info("Pure dictation detected; external search bypassed to avoid false matches")
        }
        
        let summary = json["summary"] as? String ?? ""
        var cards: [DefinitionCard] = []
        if let rawCards = json["cards"] as? [[String: Any]] {
            for c in rawCards {
                let term = c["term"] as? String ?? ""
                let def = c["definition"] as? String ?? ""
                guard !term.isEmpty, !def.isEmpty else { continue }
                let notes = c["notes"] as? [String] ?? []
                let source = c["source"] as? String ?? (webSearchCitation?.url ?? "")
                cards.append(DefinitionCard(term: term, definition: def, notes: notes, source: source))
            }
        }
        
        // If web citation exists and matched a term, enrich or insert top card
        if let citation = webSearchCitation, let title = citation.title, let snip = citation.snippet {
            let matchedIndex = cards.firstIndex { $0.term.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains($0.term) }
            if let idx = matchedIndex {
                cards[idx] = DefinitionCard(
                    term: title,
                    definition: snip,
                    notes: cards[idx].notes ?? ["Проверенное энциклопедическое определение"],
                    source: citation.url
                )
            } else {
                cards.insert(DefinitionCard(
                    term: title,
                    definition: snip,
                    notes: ["Извлечено из проверенной базы знаний Wikipedia"],
                    source: citation.url
                ), at: 0)
            }
        }
        
        let actionPoints = json["actionPoints"] as? [String] ?? (json["action_points"] as? [String] ?? [])
        
        return CloudflareBrainResponse(
            summary: summary,
            cards: cards,
            actionPoints: actionPoints,
            webSearch: webSearchCitation,
            model: model,
            searched: didSearch
        )
    }
    
    // MARK: - Reliable Fallback Knowledge Enrichment
    
    private static func fallbackLocalEnrichment(cleanTranscript: String, locale: String) async -> CloudflareBrainResponse {
        let isQuestionOrSearch = hasExplicitSearchIntent(cleanTranscript)
        var searchCitation: WebSearchCitation? = nil
        var didSearch = false
        
        if isQuestionOrSearch {
            let extracted = extractFallbackSearchQuery(from: cleanTranscript)
            if !extracted.isEmpty {
                searchCitation = await searchProvider.search(query: extracted, locale: locale)
                didSearch = (searchCitation != nil)
            }
        }
        
        let query = searchCitation?.query ?? extractFallbackSearchQuery(from: cleanTranscript)
        let title = searchCitation?.title ?? (query.isEmpty ? "Тезис записи" : query.capitalized)
        
        let definition: String
        let sourceUrl: String?
        let notes: [String]
        
        if let citation = searchCitation, let snip = citation.snippet, !snip.isEmpty {
            definition = snip
            sourceUrl = citation.url
            notes = [
                "Информация получена из проверенной базы знаний Wikipedia.",
                "Соответствует поисковому запросу: «\(query)»"
            ]
        } else {
            definition = "Ключевое содержание стенограммы: «\(cleanTranscript.prefix(140))»."
            sourceUrl = nil
            notes = ["Сформировано локальным модулем анализа речи."]
        }
        
        let card = DefinitionCard(
            term: title,
            definition: definition,
            notes: notes,
            source: sourceUrl
        )
        
        let summaryText: String
        if let citation = searchCitation, let snip = citation.snippet, !snip.isEmpty {
            summaryText = "По запросу «\(query)» найдена справка: **\(title)**.\n\(snip)"
        } else {
            summaryText = cleanTranscript.prefix(180) + (cleanTranscript.count > 180 ? "..." : "")
        }
        
        return CloudflareBrainResponse(
            summary: summaryText,
            cards: [card],
            actionPoints: isQuestionOrSearch ? ["Изучить подробнее по теме: \(title)"] : ["Сохранено в историю записей"],
            webSearch: searchCitation,
            model: "local-intent-enrichment",
            searched: didSearch
        )
    }
    
    private static func hasExplicitSearchIntent(_ text: String) -> Bool {
        let patterns = [
            #"(?i)\b(что такое|кто такой|кто такая|кто такие|что значит)\b"#,
            #"(?i)\b(поищи|найди в интернете|найди информацию|расскажи про|объясни)\b"#,
            #"(?i)\b(what is|who is|tell me about|how does)\b"#
        ]
        for pattern in patterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
    
    private static func extractFallbackSearchQuery(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixPatterns: [String] = [
            "^(?:поищи|найди|ищи)\\s+(?:в\\s+интернете\\s+)?(?:информацию\\s+)?(?:про|о|об)?\\s*",
            "^(?:что\\s+такое|что\\s+значит|кто\\s+такой|кто\\s+такая|кто\\s+такие)\\s*",
            "^(?:расскажи\\s+(?:мне\\s+)?(?:про|о|об))\\s*",
            "^(?:объясни\\s+(?:мне\\s+)?(?:что\\s+такое|как\\s+работает|про|о|об)?)\\s*",
            "^(?:what\\s+is|who\\s+is|tell\\s+me\\s+about)\\s*"
        ]
        for pattern in prefixPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)),
               match.range.location == 0,
               let range = Range(match.range, in: cleaned) {
                let candidate = String(cleaned[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\"'"))
                if candidate.count >= 2 { return candidate }
            }
        }
        return ""
    }
}
