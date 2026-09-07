//
//  RealtimeTranscriptView.swift
//  GemmaTranscribe
//
//  Real-time streaming transcript view with smooth auto-scrolling.
//  Adapted from LiveTranscriber captions view.
//

import SwiftUI

public struct RealtimeTranscriptView: View {
    let lines: [TranscriptionLine]
    let interimText: String
    let isRecording: Bool
    
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if lines.isEmpty && interimText.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(size: 19, weight: .regular, design: .rounded))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        
                        if !interimText.isEmpty {
                            Text(interimText)
                                .font(.system(size: 19, weight: .regular, design: .rounded))
                                .foregroundColor(.secondary.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    
                    // Anchor for auto-scrolling
                    Color.clear
                        .frame(height: 1)
                        .id("bottomAnchor")
                }
                .padding()
            }
            .onChange(of: lines.count) { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .onChange(of: interimText) { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: isRecording ? "waveform" : "mic.circle")
                .font(.system(size: 44))
                .foregroundColor(.dictusAccent.opacity(0.7))
                .symbolEffect(.pulse, isActive: isRecording)
            
            Text(isRecording ? "Listening & transcribing..." : "Tap the microphone to speak")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Powered on-device by Google Gemma 3n E2B LiteRT")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding()
    }
}
