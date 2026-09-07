//
//  ModelManagerView.swift
//  GemmaTranscribe
//
//  Hugging Face Model Manager sheet: search models, view specifications,
//  download weights, switch active model, and delete models.
//  Adapted from Dictus ModelManagerView.
//

import SwiftUI

public struct ModelManagerView: View {
    @ObservedObject var modelManager = ModelManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: Int = 0 // 0: Recommended, 1: HF Search, 2: Installed
    @State private var searchQuery: String = ""
    @State private var searchResults: [ModelInfo] = []
    @State private var isSearching: Bool = false
    @State private var searchError: String?
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab Picker
                Picker("Категории", selection: $selectedTab) {
                    Text("Рекомендуемые").tag(0)
                    Text("Hugging Face").tag(1)
                    Text("Установленные (\(modelManager.downloadedModelIds.count))").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                
                // Content Views
                Group {
                    switch selectedTab {
                    case 0:
                        recommendedListView
                    case 1:
                        huggingFaceSearchView
                    case 2:
                        installedListView
                    default:
                        EmptyView()
                    }
                }
            }
            .navigationTitle("Менеджер моделей")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    // MARK: - Recommended Models View
    
    private var recommendedListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header notice
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.dictusAccent)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Локальные модели Google AI Edge")
                            .font(.subheadline.weight(.semibold))
                        Text("Модели не встроены в IPA и скачиваются напрямую с Hugging Face.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color.dictusAccent.opacity(0.08))
                .cornerRadius(12)
                
                ForEach(ModelInfo.recommendedCatalog) { model in
                    ModelCardView(
                        model: model,
                        isDownloaded: modelManager.isModelDownloaded(model.identifier),
                        isActive: modelManager.isActiveModel(model.identifier),
                        isDownloading: modelManager.downloadingModelId == model.identifier,
                        downloadProgress: modelManager.downloadingModelId == model.identifier ? modelManager.currentDownloadProgress : nil,
                        onDownload: {
                            Task {
                                await modelManager.startDownload(model: model)
                            }
                        },
                        onSelect: {
                            Task {
                                await modelManager.selectActiveModel(model.identifier)
                            }
                        },
                        onDelete: {
                            modelManager.deleteModel(model.identifier)
                        }
                    )
                }
            }
            .padding()
        }
    }
    
    // MARK: - Hugging Face Search View
    
    private var huggingFaceSearchView: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Поиск моделей на Hugging Face (например: gemma, litert)...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        performHFSearch()
                    }
                
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                
                Button("Найти") {
                    performHFSearch()
                }
                .buttonStyle(.borderedProminent)
                .tint(.dictusAccent)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
            
            if isSearching {
                Spacer()
                ProgressView("Поиск моделей в Hugging Face Hub...")
                    .foregroundColor(.secondary)
                Spacer()
            } else if let error = searchError {
                Spacer()
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                Spacer()
            } else if searchResults.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("Введите запрос для поиска моделей LiteRT на Hugging Face")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(searchResults) { model in
                            ModelCardView(
                                model: model,
                                isDownloaded: modelManager.isModelDownloaded(model.identifier),
                                isActive: modelManager.isActiveModel(model.identifier),
                                isDownloading: modelManager.downloadingModelId == model.identifier,
                                downloadProgress: modelManager.downloadingModelId == model.identifier ? modelManager.currentDownloadProgress : nil,
                                onDownload: {
                                    Task {
                                        await modelManager.startDownload(model: model)
                                    }
                                },
                                onSelect: {
                                    Task {
                                        await modelManager.selectActiveModel(model.identifier)
                                    }
                                },
                                onDelete: {
                                    modelManager.deleteModel(model.identifier)
                                }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
    }
    
    // MARK: - Installed Models View
    
    private var installedListView: some View {
        Group {
            if modelManager.downloadedModelIds.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("Нет установленных моделей")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Перейдите во вкладку «Рекомендуемые» или «Hugging Face», чтобы скачать Gemma 3n E2B.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(Array(modelManager.downloadedModelIds), id: \.self) { modelId in
                            let catalogMatch = ModelInfo.recommendedCatalog.first { $0.identifier == modelId }
                            let info = catalogMatch ?? ModelInfo(
                                identifier: modelId,
                                displayName: modelId.components(separatedBy: "/").last?.capitalized ?? modelId,
                                author: modelId.components(separatedBy: "/").first ?? "local",
                                sizeBytes: 2_450_000_000,
                                description: "Локально сохраненная модель для LiteRT runtime."
                            )
                            
                            ModelCardView(
                                model: info,
                                isDownloaded: true,
                                isActive: modelManager.isActiveModel(modelId),
                                isDownloading: false,
                                downloadProgress: nil,
                                onDownload: {},
                                onSelect: {
                                    Task {
                                        await modelManager.selectActiveModel(modelId)
                                    }
                                },
                                onDelete: {
                                    modelManager.deleteModel(modelId)
                                }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
    }
    
    private func performHFSearch() {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSearching = true
        searchError = nil
        
        Task {
            do {
                let results = try await HuggingFaceSearchService.search(query: searchQuery)
                self.searchResults = results
                self.isSearching = false
            } catch {
                self.searchError = "Ошибка поиска: \(error.localizedDescription)"
                self.isSearching = false
            }
        }
    }
}
