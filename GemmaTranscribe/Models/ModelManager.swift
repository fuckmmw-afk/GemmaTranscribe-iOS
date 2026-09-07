//
//  ModelManager.swift
//  GemmaTranscribe
//
//  Manages downloaded models, Hugging Face downloads, and active local engine.
//  Adapted from Dictus ModelManager.
//

import Foundation
import Combine
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "ModelManager")

@MainActor
public final class ModelManager: ObservableObject {
    public static let shared = ModelManager()
    
    @Published public private(set) var activeModelId: String
    @Published public private(set) var downloadedModelIds: Set<String> = []
    @Published public private(set) var currentDownloadProgress: ModelDownloadProgress?
    @Published public private(set) var downloadingModelId: String?
    @Published public private(set) var errorMessage: String?
    
    private var downloader: ModelRepoDownloader?
    private var cancellables = Set<AnyCancellable>()
    
    // Active speech engine
    public private(set) var activeEngine: SpeechModelEngine
    
    public init() {
        let storedModel = UserDefaults.standard.string(forKey: AppConfig.activeModelKey) ?? AppConfig.defaultModelId
        self.activeModelId = storedModel
        self.activeEngine = LiteRTGemmaEngine(modelId: storedModel)
        
        refreshDownloadedModels()
        
        NotificationCenter.default.publisher(for: .modelDownloadProgressUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                if let progress = note.object as? ModelDownloadProgress {
                    self?.currentDownloadProgress = progress
                }
            }
            .store(in: &cancellables)
            
        // Attempt loading active model if already downloaded
        Task {
            await self.loadActiveEngine()
        }
    }
    
    public func isModelDownloaded(_ identifier: String) -> Bool {
        downloadedModelIds.contains(identifier)
    }
    
    public func isActiveModel(_ identifier: String) -> Bool {
        activeModelId == identifier
    }
    
    public func refreshDownloadedModels() {
        let modelsDir = AppConfig.modelsDirectory
        guard let subdirs = try? FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil) else {
            downloadedModelIds = []
            return
        }
        
        var downloaded = Set<String>()
        for dir in subdirs {
            let modelId = dir.lastPathComponent.replacingOccurrences(of: "___", with: "/")
            // Check if dir has any files
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if !files.isEmpty {
                downloaded.insert(modelId)
            }
        }
        self.downloadedModelIds = downloaded
    }
    
    public func selectActiveModel(_ identifier: String) async {
        guard activeModelId != identifier else { return }
        
        logger.info("Switching active model to \(identifier, privacy: .public)")
        await activeEngine.unload()
        
        activeModelId = identifier
        UserDefaults.standard.set(identifier, forKey: AppConfig.activeModelKey)
        
        // Instantiate new engine
        self.activeEngine = LiteRTGemmaEngine(modelId: identifier)
        await loadActiveEngine()
    }
    
    public func startDownload(model: ModelInfo) async {
        guard downloadingModelId == nil else { return }
        
        downloadingModelId = model.identifier
        currentDownloadProgress = ModelDownloadProgress(bytesDownloaded: 0, totalBytes: model.sizeBytes, fraction: 0)
        errorMessage = nil
        
        let sanitizedName = model.identifier.replacingOccurrences(of: "/", with: "___")
        let destination = AppConfig.modelsDirectory.appendingPathComponent(sanitizedName, isDirectory: true)
        
        let downloaderInstance = ModelRepoDownloader()
        self.downloader = downloaderInstance
        
        do {
            try await downloaderInstance.download(repoId: model.identifier, destination: destination) { [weak self] progress in
                Task { @MainActor in
                    self?.currentDownloadProgress = progress
                }
            }
            
            refreshDownloadedModels()
            downloadingModelId = nil
            currentDownloadProgress = nil
            self.downloader = nil
            
            // Auto-activate if no model currently active or if default
            if activeModelId == model.identifier || !isModelDownloaded(activeModelId) {
                await selectActiveModel(model.identifier)
            }
            logger.info("Model download finished: \(model.identifier, privacy: .public)")
        } catch {
            logger.error("Download failed for \(model.identifier, privacy: .public): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            downloadingModelId = nil
            currentDownloadProgress = nil
            self.downloader = nil
        }
    }
    
    public func cancelDownload() {
        downloader?.cancel()
        downloader = nil
        downloadingModelId = nil
        currentDownloadProgress = nil
    }
    
    public func deleteModel(_ identifier: String) {
        let sanitizedName = identifier.replacingOccurrences(of: "/", with: "___")
        let destination = AppConfig.modelsDirectory.appendingPathComponent(sanitizedName, isDirectory: true)
        
        try? FileManager.default.removeItem(at: destination)
        refreshDownloadedModels()
        
        if activeModelId == identifier {
            Task {
                await activeEngine.unload()
            }
        }
        logger.info("Model deleted: \(identifier, privacy: .public)")
    }
    
    private func loadActiveEngine() async {
        guard isModelDownloaded(activeModelId) else { return }
        let sanitizedName = activeModelId.replacingOccurrences(of: "/", with: "___")
        let destination = AppConfig.modelsDirectory.appendingPathComponent(sanitizedName, isDirectory: true)
        
        do {
            try await activeEngine.loadModel(from: destination)
            logger.info("Active model engine loaded: \(self.activeModelId, privacy: .public)")
        } catch {
            logger.error("Failed to load active model \(self.activeModelId, privacy: .public): \(error.localizedDescription)")
        }
    }
}
