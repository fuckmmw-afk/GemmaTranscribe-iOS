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
    @Published public private(set) var isModelReady: Bool = false
    
    private var downloader: ModelRepoDownloader?
    private var cancellables = Set<AnyCancellable>()
    
    // Dedicated Gemma 3n E2B Engine
    public private(set) var gemmaEngine: LiteRTGemmaEngine
    
    // Active speech engine (always Gemma 3n)
    public var activeEngine: SpeechModelEngine {
        gemmaEngine
    }
    
    public init() {
        let storedModel = UserDefaults.standard.string(forKey: AppConfig.activeModelKey) ?? AppConfig.defaultModelId
        self.activeModelId = storedModel
        self.gemmaEngine = LiteRTGemmaEngine(modelId: storedModel)
        
        refreshDownloadedModels()
        
        NotificationCenter.default.publisher(for: .modelDownloadProgressUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                if let progress = note.object as? ModelDownloadProgress {
                    self?.currentDownloadProgress = progress
                }
            }
            .store(in: &cancellables)
            
        // Automatically attempt to find and initialize Gemma 3n weights
        Task {
            await self.loadActiveEngine()
        }
    }
    
    public func isModelDownloaded(_ identifier: String) -> Bool {
        if downloadedModelIds.contains(identifier) {
            return true
        }
        // If any genuine Gemma 3n weights are present on disk, count as downloaded
        return !downloadedModelIds.isEmpty
    }
    
    public func isActiveModel(_ identifier: String) -> Bool {
        activeModelId == identifier
    }
    
    public func refreshDownloadedModels() {
        let modelsDir = AppConfig.modelsDirectory
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        var downloaded = Set<String>()
        
        // 1. Check directories in models/
        if let subdirs = try? FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil) {
            for dir in subdirs {
                let sanitizedName = dir.lastPathComponent
                let modelId = sanitizedName.replacingOccurrences(of: "___", with: "/")
                
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                        var totalBytes: Int64 = 0
                        for file in files {
                            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                            totalBytes += Int64(size)
                        }
                        
                        if totalBytes >= 50_000_000 {
                            downloaded.insert(modelId)
                        } else if totalBytes > 0 && totalBytes < 5_000_000 {
                            logger.warning("Purging corrupted download for \(modelId, privacy: .public)")
                            try? FileManager.default.removeItem(at: dir)
                        }
                    } else {
                        // Direct file in modelsDir
                        let size = (try? dir.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        if size >= 50_000_000 {
                            downloaded.insert(AppConfig.defaultModelId)
                        }
                    }
                }
            }
        }
        
        // 2. Also check Documents directory for any pre-existing model weights
        if let docFiles = try? FileManager.default.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in docFiles {
                let ext = file.pathExtension.lowercased()
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if (ext == "litertlm" || ext == "bin" || ext == "tflite") && size >= 50_000_000 {
                    downloaded.insert(AppConfig.defaultModelId)
                }
            }
        }
        
        self.downloadedModelIds = downloaded
        
        // If default model wasn't set, but another Gemma model was downloaded, activate it
        if !downloaded.isEmpty && !downloaded.contains(activeModelId) {
            if let first = downloaded.first {
                self.activeModelId = first
            }
        }
    }
    
    public func locateModelFile() -> URL? {
        let modelsDir = AppConfig.modelsDirectory
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        let sanitizedName = activeModelId.replacingOccurrences(of: "/", with: "___")
        let preferredDir = modelsDir.appendingPathComponent(sanitizedName, isDirectory: true)
        
        let candidateDirs = [preferredDir, modelsDir, docsDir]
        
        for dir in candidateDirs {
            if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
                var found: [(url: URL, size: Int64)] = []
                for case let fileURL as URL in enumerator {
                    guard let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                          vals.isDirectory == false else { continue }
                    let size = Int64(vals.fileSize ?? 0)
                    let ext = fileURL.pathExtension.lowercased()
                    if (ext == "litertlm" || ext == "tflite" || ext == "bin" || size > 50_000_000) && size > 5_000_000 {
                        found.append((fileURL, size))
                    }
                }
                if let best = found.max(by: { $0.size < $1.size }) {
                    return best.url
                }
            }
        }
        return nil
    }
    
    public func selectActiveModel(_ identifier: String) async {
        guard activeModelId != identifier else { return }
        
        logger.info("Switching active model to \(identifier, privacy: .public)")
        await gemmaEngine.unload()
        
        activeModelId = identifier
        UserDefaults.standard.set(identifier, forKey: AppConfig.activeModelKey)
        
        self.gemmaEngine = LiteRTGemmaEngine(modelId: identifier)
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
                Task { @MainActor [weak self] in
                    self?.currentDownloadProgress = progress
                }
            }
            
            refreshDownloadedModels()
            downloadingModelId = nil
            currentDownloadProgress = nil
            self.downloader = nil
            
            await selectActiveModel(model.identifier)
            logger.info("Model download finished successfully: \(model.identifier, privacy: .public)")
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
                await gemmaEngine.unload()
                self.isModelReady = false
            }
        }
        logger.info("Model deleted: \(identifier, privacy: .public)")
    }
    
    public func loadActiveEngine() async {
        refreshDownloadedModels()
        
        guard let modelFileURL = locateModelFile() else {
            self.isModelReady = false
            logger.warning("Gemma 3n E2B model weights not found on disk")
            return
        }
        
        logger.info("Loading Gemma 3n E2B weights from \(modelFileURL.path, privacy: .public)...")
        do {
            try await gemmaEngine.loadModel(from: modelFileURL)
            self.isModelReady = gemmaEngine.isLoaded
            logger.info("Gemma 3n E2B engine loaded successfully and is ready for on-device transcription!")
        } catch {
            logger.error("Failed to load Gemma 3n engine: \(error.localizedDescription)")
            self.isModelReady = false
        }
    }
}
