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
    
    public var formattedSpeedOrSize: String {
        "\(downloadedMB) MB / \(totalMB > 0 ? "\(totalMB) MB" : "...")"
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
    
    private var bytesDownloaded: Int64 = 0
    private var totalExpectedBytes: Int64 = 0
    private var destinationDirectory: URL?
    private var targetFileName: String = ""
    private var currentRepoId: String = ""
    private var completionContinuation: CheckedContinuation<Void, Error>?
    private var progressHandler: (@Sendable (ModelDownloadProgress) -> Void)?
    
    public func download(
        repoId: String,
        destination: URL,
        progressHandler: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        self.destinationDirectory = destination
        self.currentRepoId = repoId
        self.progressHandler = progressHandler
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        
        // 1. Fetch repo file tree
        guard let treeURL = URL(string: "https://huggingface.co/api/models/\(repoId)/tree/main") else {
            throw NSError(domain: "ModelRepoDownloader", code: 400, userInfo: [NSLocalizedDescriptionKey: "Неверный URL репозитория: \(repoId)"])
        }
        
        var treeReq = URLRequest(url: treeURL)
        treeReq.timeoutInterval = 25
        
        let hfToken = UserDefaults.standard.string(forKey: AppConfig.huggingFaceTokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hfToken.isEmpty {
            treeReq.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
        }
        
        let (treeData, treeResponse) = try await URLSession.shared.data(for: treeReq)
        if let httpRes = treeResponse as? HTTPURLResponse {
            if httpRes.statusCode == 401 || httpRes.statusCode == 403 {
                throw NSError(domain: "ModelRepoDownloader", code: httpRes.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Доступ ограничен (HTTP \(httpRes.statusCode)). Для \(repoId) требуется указать Hugging Face User Access Token (hf_...) в Настройках и подтвердить лицензию на huggingface.co/\(repoId)."
                ])
            }
        }
        
        let decoder = JSONDecoder()
        let files = (try? decoder.decode([HFFile].self, from: treeData)) ?? []
        
        // Find relevant model files (.litertlm, .bin, .tflite, or largest file)
        let modelFiles = files.filter { $0.type == "file" }
        let chosenFile = modelFiles.first {
            let ext = ($0.path as NSString).pathExtension.lowercased()
            return ext == "litertlm" || ext == "tflite" || ext == "bin"
        } ?? modelFiles.max(by: { ($0.size ?? 0) < ($1.size ?? 0) })
        
        guard let fileToDownload = chosenFile else {
            // Fallback to direct model.litertlm
            let fallbackName = "gemma-3n-E2B-it-int4.litertlm"
            self.targetFileName = fallbackName
            self.totalExpectedBytes = 2_450_000_000
            try await startDirectDownload(
                url: URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(fallbackName)")!,
                hfToken: hfToken
            )
            return
        }
        
        self.targetFileName = fileToDownload.path
        self.totalExpectedBytes = fileToDownload.size ?? 2_450_000_000
        
        guard let downloadURL = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(fileToDownload.path)") else {
            throw NSError(domain: "ModelRepoDownloader", code: 400, userInfo: [NSLocalizedDescriptionKey: "Неверный URL файла модели"])
        }
        
        try await startDirectDownload(url: downloadURL, hfToken: hfToken)
    }
    
    private func startDirectDownload(
        url: URL,
        hfToken: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.completionContinuation = continuation
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 7200 // 2 hours for large weights
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.urlSession = session
            
            var request = URLRequest(url: url)
            if !hfToken.isEmpty {
                request.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
            }
            
            let task = session.downloadTask(with: request)
            self.downloadTask = task
            task.resume()
        }
    }
    
    public func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        completionContinuation?.resume(throwing: NSError(domain: "ModelRepoDownloader", code: -999, userInfo: [NSLocalizedDescriptionKey: "Загрузка отменена"]))
        completionContinuation = nil
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
        
        // Directly invoke registered progress handler
        self.progressHandler?(progress)
        NotificationCenter.default.post(name: .modelDownloadProgressUpdated, object: progress)
    }
    
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Check HTTP response status
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                let err = NSError(domain: "ModelRepoDownloader", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Ошибка авторизации Hugging Face (HTTP \(httpResponse.statusCode)). Укажите токен доступа (hf_...) в Настройках приложения и примите лицензию на сайте Hugging Face."
                ])
                completionContinuation?.resume(throwing: err)
                completionContinuation = nil
                return
            } else if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                let err = NSError(domain: "ModelRepoDownloader", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Сервер вернул ошибку скачивания: HTTP \(httpResponse.statusCode)"
                ])
                completionContinuation?.resume(throwing: err)
                completionContinuation = nil
                return
            }
        }
        
        // Validate file size to prevent saving tiny error responses or HTML
        let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
        let actualSize = (attributes?[.size] as? Int64) ?? 0
        
        if actualSize < 5_000_000 { // Less than 5MB
            let contentSnippet = (try? String(contentsOf: location, encoding: .utf8)) ?? ""
            logger.error("Downloaded file too small (\(actualSize) bytes): \(contentSnippet.prefix(100), privacy: .public)")
            
            let err = NSError(domain: "ModelRepoDownloader", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Загруженный файл не является весами модели (размер \(actualSize) байт). Требуется авторизация Hugging Face: \(contentSnippet.prefix(120))"
            ])
            try? FileManager.default.removeItem(at: location)
            completionContinuation?.resume(throwing: err)
            completionContinuation = nil
            return
        }
        
        guard let destDir = destinationDirectory else {
            completionContinuation?.resume(throwing: NSError(domain: "ModelRepoDownloader", code: 500, userInfo: [NSLocalizedDescriptionKey: "Директория назначения не найдена"]))
            completionContinuation = nil
            return
        }
        
        let finalURL = destDir.appendingPathComponent(targetFileName.isEmpty ? "model.litertlm" : targetFileName)
        
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: location, to: finalURL)
            logger.info("Model file successfully moved to \(finalURL.path, privacy: .public), size=\(actualSize) bytes")
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
