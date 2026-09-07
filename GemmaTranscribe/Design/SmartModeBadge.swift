//
//  SmartModeBadge.swift
//  GemmaTranscribe
//
//  Corner badge for AnimatedMicButton.
//  Adapted from Dictus SmartModeBadge.
//

import Foundation

public enum SmartModeBadge: Equatable, Sendable, Codable {
    case symbol(String)
    case text(String)
}
