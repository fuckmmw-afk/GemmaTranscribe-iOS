//
//  ModelRepoDownloader.swift
//  GemmaTranscribe
//
//  Streams model weights directly from Hugging Face into app storage.
//  Adapted from Dictus ModelRepoDownloader with byte-accurate progress reporting.
//

import Foundation
import Combine
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "ModelRepoDownloader")

public struct ModelDownloadProgress: Sendable {
    public let bytesDownloaded: Int64
    public let totalBytes: Int64
    public let fraction: Double
    
    public var downloadedMB: Int {
        Int(bytesDownloaded / 1_000_000)
    }
    
    public var totalMB: Int {
        Int(totalBytes / 1_000_000)
    }
    
    public var percentFormatted: String {
        "\(Int(fraction * 100))%"
    }
}

public final class ModelRepoDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    
    private struct HFFile: Codable {
        let type: String
        let path: String
        let size: Int64?
    }
    
    private var downloadTask: URLSessionDownloadTask?
    private var urlSession: URLSession?
    private var progressContinuation: AsyncStream<ModelDownloadProgress>.Continuation?
    
    private var bytesDownloaded: Int64 = 0
    private var totalExpectedBytes: Int64 = 0
    private var destinationDirectory: URL?
    private var targetFileName: String = ""
    private var completionContinuation: CheckedContinuation<Void, Error>?
    
    public func download(
        repoId: String,
        destination: URL,
        progressHandler: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        self.destinationDirectory = destination
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        
        // 1. Fetch repo file tree
        guard let treeURL = URL(string: "https://huggingface.co/api/models/\(repoId)/tree/main") else {
            throw NSError(domain: "ModelRepoDownloader", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid repo URL"])
        }
        
        var treeReq = URLRequest(url: treeURL)
        treeReq.timeoutInterval = 20
        
        let (treeData, _) = try await URLSession.shared.data(for: treeReq)
        let decoder = JSONDecoder()
        let files = (try? decoder.decode([HFFile].self, from: treeData)) ?? []
        
        // Find relevant model files (.litertlm, .bin, .tflite, or largest file)
        let modelFiles = files.filter { $0.type == "file" }
        let chosenFile = modelFiles.first {
            let ext = ($0.path as NSString).pathExtension.lowercased()
            return ext == "litertlm" || ext == "tflite" || ext == "bin"
        } ?? modelFiles.max(by: { ($0.size ?? 0) < ($1.size ?? 0) })
        
        guard let fileToDownload = chosenFile else {
            // If tree is empty or blocked, fallback to direct resolve
            let fallbackName = "model.litertlm"
            self.targetFileName = fallbackName
            self.totalExpectedBytes = 2_450_000_000
            try await startDirectDownload(
                url: URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(fallbackName)")!,
                progressHandler: progressHandler
            )
            return
        }
        
        self.targetFileName = fileToDownload.path
        self.totalExpectedBytes = fileToDownload.size ?? 2_450_000_000
        
        guard let downloadURL = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(fileToDownload.path)") else {
            throw NSError(domain: "ModelRepoDownloader", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid file URL"])
        }
        
        try await startDirectDownload(url: downloadURL, progressHandler: progressHandler)
    }
    
    private func startDirectDownload(
        url: URL,
        progressHandler: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.completionContinuation = continuation
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 3600 // 1 hour for large weights
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.urlSession = session
            
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        }
    }
    
    public func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : self.totalExpectedBytes
        self.bytesDownloaded = totalBytesWritten
        let fraction = expected > 0 ? min(Double(totalBytesWritten) / Double(expected), 1.0) : 0.0
        
        let progress = ModelDownloadProgress(
            bytesDownloaded: totalBytesWritten,
            totalBytes: expected,
            fraction: fraction
        )
        NotificationCenter.default.post(name: .modelDownloadProgressUpdated, object: progress)
    }
    
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destDir = destinationDirectory else { return }
        let finalURL = destDir.appendingPathComponent(targetFileName.isEmpty ? "model.litertlm" : targetFileName)
        
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: location, to: finalURL)
            logger.info("Model file successfully moved to \(finalURL.path, privacy: .public)")
            completionContinuation?.resume()
            completionContinuation = nil
        } catch {
            logger.error("Failed to move downloaded file: \(error.localizedDescription)")
            completionContinuation?.resume(throwing: error)
            completionContinuation = nil
        }
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            logger.error("Download task failed: \(error.localizedDescription)")
            completionContinuation?.resume(throwing: error)
            completionContinuation = nil
        }
    }
}

extension Notification.Name {
    public static let modelDownloadProgressUpdated = Notification.Name("ModelDownloadProgressUpdated")
}
