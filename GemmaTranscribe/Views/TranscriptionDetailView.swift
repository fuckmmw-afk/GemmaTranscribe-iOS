//
//  TranscriptionDetailView.swift
//  GemmaTranscribe
//
//  Detailed view for a single saved history recording, showing transcript,
//  Cloudflare AI structuring, definition cards, and web search citations.
//  Adapted from Dictus TranscriptionDetailView.
//

import SwiftUI

public struct TranscriptionDetailView: View {
    let record: TranscriptionRecord
    let onDelete: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                
                // Meta info pill row
                HStack(spacing: 8) {
                    Label(record.durationFormatted, systemImage: "timer")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                    
                    Label(record.modelUsed.components(separatedBy: "/").last ?? record.modelUsed, systemImage: "cpu")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.dictusAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.dictusAccent.opacity(0.12))
                        .clipShape(Capsule())
                    
                    Spacer()
                    
                    Text(record.dateFormatted)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // Transcript text
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Стенограмма")
                            .font(.headline)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = record.cleanTranscript
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                        }
                    }
                    
                    Text(record.cleanTranscript)
                        .font(.body)
                        .foregroundColor(.primary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                }
                
                // Web Search Citation
                if let webSearch = record.webSearchCitation, let urlString = webSearch.url, let url = URL(string: urlString) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(.dictusAccent)
                            Text("Поиск в сети")
                                .font(.headline)
                        }
                        
                        Link(destination: url) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(webSearch.title ?? "Источник")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.primary)
                                    if let snippet = webSearch.snippet {
                                        Text(snippet)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                    Text(url.host ?? "")
                                        .font(.caption2)
                                        .foregroundColor(.dictusAccent)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    }
                }
                
                // AI Summary
                if let summary = record.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.purple)
                            Text("AI Анализ & Резюме")
                                .font(.headline)
                        }
                        
                        Text(summary)
                            .font(.subheadline)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.purple.opacity(0.08))
                            .cornerRadius(12)
                    }
                }
                
                // Definition Cards
                if let cards = record.cards, !cards.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ключевые понятия")
                            .font(.headline)
                        
                        ForEach(cards) { card in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(card.term)
                                    .font(.subheadline.weight(.bold))
                                Text(card.definition)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                if let notes = card.notes {
                                    ForEach(notes, id: \.self) { note in
                                        Text("• \(note)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Запись")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
    }
}
