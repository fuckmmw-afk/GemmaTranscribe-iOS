//
//  TranscriptCleaner.swift
//  GemmaTranscribe
//
//  On-device speech cleaner: removes hesitation fillers («эээ», «ааа», «uh», «um»),
//  deduplicates repeated words (stutters), and cleans speech artifacts.
//

import Foundation

public struct TranscriptCleaner: Sendable {
    
    // Regular expressions for filler words and hesitation sounds (Russian & English)
    private static let fillerRegexes: [NSRegularExpression] = {
        let patterns = [
            // Russian hesitations: эээ, ээ, э-э, э-э-э, ааа, аа, а-а, ммм, мм, м-м, хмм, гм
            #"(?i)\b[эЭ][эЭ\-]+[эЭ]?\b"#,
            #"(?i)\b[аА][аА\-]+[аА]?\b"#,
            #"(?i)\b[мМ][мМ\-]+[мМ]?\b"#,
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
    
    // Punctuation spacing: "word , text" -> "word, text"
    private static let punctuationSpacingRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\s+([,\.!\?:;])"#)
    }()
    
    /// Cleans the input text by removing hesitation fillers, repeated words, and extra whitespace.
    public static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        
        var result = text
        
        // 1. Remove fillers
        for regex in fillerRegexes {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        
        // 2. Remove repeated consecutive words (run twice to catch triple repetitions like "я я я")
        if let repeatedRegex = repeatedWordRegex {
            for _ in 0..<2 {
                let range = NSRange(result.startIndex..., in: result)
                result = repeatedRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
            }
        }
        
        // 3. Fix punctuation spacing
        if let punctRegex = punctuationSpacingRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = punctRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }
        
        // 4. Normalize multiple spaces
        if let spaceRegex = multipleSpacesRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = spaceRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: " ")
        }
        
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Capitalize first character if needed
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        
        return result
    }
}
