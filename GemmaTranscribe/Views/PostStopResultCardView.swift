//
//  PostStopResultCardView.swift
//  GemmaTranscribe
//
//  Rich post-STOP Cloudflare AI structuring & Web search results card.
//

import SwiftUI

public struct PostStopResultCardView: View {
    let cleanTranscript: String
    let response: CloudflareBrainResponse?
    let onDismiss: () -> Void
    
    @State private var copied: Bool = false
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // Header Status
                    HStack {
                        Label("Saved to Local History", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                        
                        Spacer()
                        
                        if let model = response?.model {
                            Text(model)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Cleaned Transcript Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Стенограмма")
                                .font(.headline)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = cleanTranscript
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copied = false
                                }
                            } label: {
                                Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.caption.weight(.medium))
                            }
                        }
                        
                        Text(cleanTranscript)
                            .font(.body)
                            .foregroundColor(.primary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                    }
                    
                    // Web Search Source Citation
                    if let webSearch = response?.webSearch, let urlString = webSearch.url, let url = URL(string: urlString) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "globe")
                                    .foregroundColor(.dictusAccent)
                                Text("Поиск в сети")
                                    .font(.headline)
                            }
                            
                            Link(destination: url) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(webSearch.title ?? "Результат поиска")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(.primary)
                                        
                                        if let snippet = webSearch.snippet {
                                            Text(snippet)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
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
                    if let summary = response?.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundColor(.purple)
                                Text("AI Анализ & Резюме")
                                    .font(.headline)
                            }
                            
                            Text(summary)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.purple.opacity(0.08))
                                .cornerRadius(12)
                        }
                    }
                    
                    // Structured Definition Cards
                    if let cards = response?.cards, !cards.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Ключевые понятия")
                                .font(.headline)
                            
                            ForEach(cards) { card in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(card.term)
                                            .font(.subheadline.weight(.bold))
                                        Spacer()
                                        if let src = card.source, let srcUrl = URL(string: src) {
                                            Link(destination: srcUrl) {
                                                Image(systemName: "link")
                                                    .font(.caption)
                                            }
                                        }
                                    }
                                    
                                    Text(card.definition)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    
                                    if let notes = card.notes, !notes.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(notes, id: \.self) { note in
                                                HStack(alignment: .top, spacing: 6) {
                                                    Text("•")
                                                    Text(note)
                                                }
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                }
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            }
                        }
                    }
                    
                    // Action Points
                    if let actions = response?.actionPoints, !actions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ключевые действия")
                                .font(.headline)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(actions, id: \.self) { action in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "checkmark.circle")
                                            .font(.caption)
                                            .foregroundColor(.dictusAccent)
                                            .padding(.top, 2)
                                        Text(action)
                                            .font(.subheadline)
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
                .padding()
            }
            .navigationTitle("Результат записи")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") {
                        onDismiss()
                    }
                }
            }
        }
    }
}
