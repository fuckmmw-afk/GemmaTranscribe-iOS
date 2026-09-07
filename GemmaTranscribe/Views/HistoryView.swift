//
//  HistoryView.swift
//  GemmaTranscribe
//
//  Local transcription history list view.
//  Adapted from Dictus HistoryView.
//

import SwiftUI

public struct HistoryView: View {
    @ObservedObject var historyStore = TranscriptionHistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showingClearConfirmation = false
    
    private var filteredRecords: [TranscriptionRecord] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return historyStore.records
        } else {
            return historyStore.records.filter {
                $0.cleanTranscript.localizedCaseInsensitiveContains(searchText) ||
                ($0.summary?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
    }
    
    public var body: some View {
        NavigationStack {
            Group {
                if historyStore.records.isEmpty {
                    emptyStateView
                } else {
                    List {
                        ForEach(filteredRecords) { record in
                            NavigationLink {
                                TranscriptionDetailView(record: record) {
                                    historyStore.delete(id: record.id)
                                }
                            } label: {
                                recordRow(record)
                            }
                        }
                        .onDelete { indexSet in
                            historyStore.delete(atOffsets: indexSet)
                        }
                    }
                    .searchable(text: $searchText, prompt: "Поиск в истории...")
                }
            }
            .navigationTitle("История записей")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
                
                if !historyStore.records.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Очистить") {
                            showingClearConfirmation = true
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .confirmationDialog(
                "Очистить историю?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Удалить все записи", role: .destructive) {
                    historyStore.clearAll()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Все локальные стенограммы и результаты AI будут удалены безвозвратно.")
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("История пуста")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Ваши расшифрованные записи и результаты AI поиска будут сохраняться здесь локально.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func recordRow(_ record: TranscriptionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.dateFormatted)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(record.durationFormatted)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.dictusAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.dictusAccent.opacity(0.1))
                    .clipShape(Capsule())
            }
            
            Text(record.cleanTranscript)
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(2)
            
            if let summary = record.summary, !summary.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundColor(.purple)
                    Text(summary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
