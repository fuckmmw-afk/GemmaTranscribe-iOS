//
//  AppConfig.swift
//  GemmaTranscribe
//
//  Application constants, defaults, and keys.
//

import Foundation

public enum AppConfig {
    public static let appName = "GemmaTranscribe"
    public static let appVersion = "1.0.3"
    
    // UserDefaults Keys
    public static let activeModelKey = "active_model_id"
    public static let huggingFaceTokenKey = "huggingface_api_token"
    public static let cloudflareModeKey = "cloudflare_connection_mode" // 0: Direct Workers AI, 1: Custom Worker
    public static let cloudflareWorkerUrlKey = "cloudflare_worker_url"
    public static let cloudflareApiKeyKey = "cloudflare_api_key"
    public static let cloudflareAccountIdKey = "cloudflare_account_id"
    public static let cloudflareEmailKey = "cloudflare_email"
    public static let cloudflareDirectModelKey = "cloudflare_direct_model"
    public static let audioChunkDurationKey = "audio_chunk_duration_seconds"
    public static let cleanFillersEnabledKey = "clean_fillers_enabled"
    public static let autoSearchEnabledKey = "auto_search_enabled"
    
    // Default Configuration
    public static let defaultModelId = "google/gemma-3n-E2B-it-litert-lm"
    public static let defaultCloudflareWorkerUrl = "https://dicta-brain.workers.dev"
    public static let defaultCloudflareDirectModel = "@cf/meta/llama-3.1-8b-instruct"
    public static let defaultAudioChunkDuration: Double = 1.5 // seconds (between 1.0 and 3.0)
    
    // Audio Parameters
    public static let targetSampleRate: Double = 16000.0
    public static let targetChannels: UInt32 = 1
    
    // Storage Paths
    public static var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelsDir = docs.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return modelsDir
    }
    
    public static var historyFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("transcription_history.json")
    }
}
