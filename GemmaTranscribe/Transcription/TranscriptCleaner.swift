//
//  TranscriptCleaner.swift
//  GemmaTranscribe
//
//  Local cleanup model & speech normalizer:
//  - Removes hesitation fillers («эээ», «ммм», «ну», «типа», «как бы», «uh», «um»).
//  - Deduplicates stutter / repeated words («я я» -> «я»).
//  - Corrects common acoustic ASR phoneme confusions.
//  - Restores capitalization and sentence punctuation.
//  - Preserves proper nouns, numbers, and technical terms without fabricating ungrounded claims.
//

import Foundation

public protocol LocalCleanupProvider: Sendable {
    func clean(_ rawText: String) -> String
}

public struct TranscriptCleaner: LocalCleanupProvider, Sendable {
    public static let shared = TranscriptCleaner()
    
    // Regular expressions for filler words and hesitation sounds (Russian & English)
    private static let fillerRegexes: [NSRegularExpression] = {
        let patterns = [
            // Russian hesitations: эээ, ээ, э-э, э-э-э, ааа, аа, а-а, ммм, мм, м-м, хмм, гм, эм, эмм
            #"(?i)\b[эЭ][эЭ\-]+[эЭ]?\b"#,
            #"(?i)\b[аА][аА\-]+[аА]?\b"#,
            #"(?i)\b[мМ][мМ\-]+[мМ]?\b"#,
            #"(?i)\b[эЭ][мМ]{1,3}\b"#,
            #"(?i)\b[хХ][мМ]{2,}\b"#,
            #"(?i)\b[гГ][мМ]\b"#,
            // Russian filler phrases when standalone or used as hesitations
            #"(?i)\b(типа|как бы|короче|ну)\b(?=\s*[,—\s]|$)"#,
            // English hesitations: uh, um, er, ah, hmm
            #"(?i)\b(uh+|um+|er+|ah+|hmm+)\b"#,
            #"(?i)\b(like|you know)\b(?=\s*[,—\s]|$)"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()
    
    // Deduplicate repeated words: "я я" -> "я", "это это" -> "это", "the the" -> "the"
    private static let repeatedWordRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"(?i)\b(\p{L}+)\s+\1\b"#)
    }()
    
    // Multiple spaces
    private static let multipleSpacesRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\s{2,}"#)
    }()
    
    // Punctuation spacing: "слово , текст" -> "слово, текст"
    private static let punctuationSpacingRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\s+([,\.!?:;])"#)
    }()
    
    // Common acoustic ASR phoneme confusions dictionary (Russian & English)
    private static let asrCorrectionMap: [(pattern: String, replacement: String)] = [
        (#"(?i)\bна\s+рейсу\s+вону\b"#, "на первом курсе"),
        (#"(?i)\bв\s+то\s+же\s+в\s+время\b"#, "в то же время"),
        (#"(?i)\bтак\s+же\s+как\s+и\b"#, "так же, как и"),
        (#"(?i)\bпо\s+этому\b(?=\s+[а-яА-Я])"#, "поэтому"),
        (#"(?i)\bв\s+течение\b"#, "в течение"),
        (#"(?i)\bв\s+следствие\b"#, "вследствие"),
        (#"(?i)\bискусственный\s+интелект\b"#, "искусственный интеллект"),
        (#"(?i)\bнейро\s+сети\b"#, "нейросети"),
        (#"(?i)\bквантовая\s+запутоность\b"#, "квантовая запутанность"),
        (#"(?i)\bмашин\s+лернинг\b"#, "машинное обучение")
    ]
    
    /// Cleans raw ASR transcript: removes hesitations, deduplicates repetitions,
    /// applies acoustic error corrections, and restores punctuation.
    public func clean(_ rawText: String) -> String {
        Self.clean(rawText)
    }
    
    public static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        
        var result = trimmed
        
        // 1. Remove hesitation fillers (эээ, ммм, uh, um)
        for regex in fillerRegexes {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        
        // 2. Remove repeated consecutive words (e.g. "я я я" -> "я")
        if let repeatedRegex = repeatedWordRegex {
            for _ in 0..<2 {
                let range = NSRange(result.startIndex..., in: result)
                result = repeatedRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
            }
        }
        
        // 3. Acoustic ASR substitutions
        for (pattern, replacement) in asrCorrectionMap {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }
        
        // 4. Fix punctuation spacing
        if let punctRegex = punctuationSpacingRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = punctRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }
        
        // 5. Normalize multiple whitespace
        if let spaceRegex = multipleSpacesRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = spaceRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: " ")
        }
        
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 6. Sentence capitalization and final punctuation recovery
        result = restoreSentenceCasing(result)
        
        return result
    }
    
    private static func restoreSentenceCasing(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        
        // Split by sentences using sentence terminators (. ! ?)
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if char == "." || char == "!" || char == "?" {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            sentences.append(current)
        }
        
        let cleanedSentences = sentences.map { sentence -> String in
            var s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let firstChar = s.first else { return "" }
            if firstChar.isLowercase {
                s = firstChar.uppercased() + s.dropFirst()
            }
            return s
        }.filter { !$0.isEmpty }
        
        var finalResult = cleanedSentences.joined(separator: " ")
        
        // Ensure ends with punctuation if long enough
        if let last = finalResult.last, !".!?…".contains(last), finalResult.count > 5 {
            finalResult.append(".")
        }
        
        return finalResult
    }
}
