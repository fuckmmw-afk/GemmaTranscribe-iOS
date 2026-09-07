//
//  SettingsView.swift
//  GemmaTranscribe
//
//  Settings screen: audio pipeline tuning, speech filler filters,
//  Cloudflare endpoint configuration with API Key authentication,
//  Hugging Face token settings, and runtime diagnostics.
//

import SwiftUI

public struct SettingsView: View {
    @ObservedObject var modelManager = ModelManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage(AppConfig.audioChunkDurationKey) private var chunkDuration: Double = AppConfig.defaultAudioChunkDuration
    @AppStorage(AppConfig.cleanFillersEnabledKey) private var cleanFillers: Bool = true
    @AppStorage(AppConfig.cloudflareWorkerUrlKey) private var cloudflareUrl: String = AppConfig.defaultCloudflareWorkerUrl
    @AppStorage(AppConfig.cloudflareApiKeyKey) private var cloudflareApiKey: String = ""
    @AppStorage(AppConfig.cloudflareAccountIdKey) private var cloudflareAccountId: String = ""
    @AppStorage(AppConfig.huggingFaceTokenKey) private var huggingFaceToken: String = ""
    
    @State private var showingModelManager = false
    @State private var isTestingConnection = false
    @State private var connectionTestResult: (success: Bool, message: String)?
    @State private var isSecureApiKey = true
    @State private var isSecureHfToken = true
    
    public var body: some View {
        NavigationStack {
            Form {
                // Section: Local Speech Engine
                Section(header: Text("Локальная модель (On-Device)")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Текущая модель")
                                .font(.subheadline.weight(.semibold))
                            Text(modelManager.activeModelId)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        
                        let isReady = modelManager.isModelDownloaded(modelManager.activeModelId)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(isReady ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(isReady ? "Готова" : "Не загружена")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Button {
                        showingModelManager = true
                    } label: {
                        Label("Открыть менеджер моделей", systemImage: "arrow.down.circle")
                            .foregroundColor(.dictusAccent)
                    }
                }
                
                // Section: Hugging Face Authentication
                Section(
                    header: Text("Hugging Face Авторизация"),
                    footer: Text("Для скачивания официальных моделей Google Gemma требуется согласие с лицензией на сайте huggingface.co и бесплатный User Access Token (hf_...).")
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("User Access Token (hf_...)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            if isSecureHfToken {
                                SecureField("hf_xxxxxxxxxxxxxxxx", text: $huggingFaceToken)
                                    .font(.subheadline)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            } else {
                                TextField("hf_xxxxxxxxxxxxxxxx", text: $huggingFaceToken)
                                    .font(.subheadline)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }
                            Button {
                                isSecureHfToken.toggle()
                            } label: {
                                Image(systemName: isSecureHfToken ? "eye" : "eye.slash")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // Section: Cloudflare Brain Pipeline & Authentication
                Section(
                    header: Text("Cloudflare AI & Web Search (После STOP)"),
                    footer: Text("На Cloudflare отправляется только очищенный текст. Аудио никогда не передается в сеть.")
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("URL Эндпоинта (Worker или Direct REST API)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("https://...", text: $cloudflareUrl)
                            .font(.subheadline)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cloudflare API Key / Bearer Token")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            if isSecureApiKey {
                                SecureField("Bearer токен доступа", text: $cloudflareApiKey)
                                    .font(.subheadline)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            } else {
                                TextField("Bearer токен доступа", text: $cloudflareApiKey)
                                    .font(.subheadline)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }
                            Button {
                                isSecureApiKey.toggle()
                            } label: {
                                Image(systemName: isSecureApiKey ? "eye" : "eye.slash")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Account ID (для Direct REST API)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Необязательно (для api.cloudflare.com)", text: $cloudflareAccountId)
                            .font(.subheadline)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    Button {
                        testCloudflareConnection()
                    } label: {
                        HStack {
                            if isTestingConnection {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "network")
                            }
                            Text("Проверить подключение к Cloudflare")
                        }
                        .foregroundColor(.dictusAccent)
                    }
                    .disabled(isTestingConnection)
                    
                    if let result = connectionTestResult {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(result.success ? .green : .red)
                            Text(result.message)
                                .font(.caption)
                                .foregroundColor(result.success ? .primary : .red)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // Section: Audio & Streaming Pipeline
                Section(
                    header: Text("Параметры Realtime транскрипции"),
                    footer: Text("Интервал между отправками аудиофрагментов в локальную модель. Допустимо от 1.0 до 3.0 секунд (приоритет качества над скоростью).")
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Длина аудио-чанка")
                            Spacer()
                            Text("\(String(format: "%.1f", chunkDuration)) сек")
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $chunkDuration, in: 1.0...3.0, step: 0.5)
                            .tint(.dictusAccent)
                    }
                    
                    Toggle("Очистка речевого мусора (эээ, ааа, повторы)", isOn: $cleanFillers)
                }
                
                // Section: Runtime Diagnostics
                Section(header: Text("Среда выполнения")) {
                    HStack {
                        Text("Целевое устройство")
                        Spacer()
                        Text("iPhone 12 / Apple Silicon")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Runtime")
                        Spacer()
                        Text("Google AI Edge / LiteRT")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Аудио пайплайн")
                        Spacer()
                        Text("16kHz Mono Float32 PCM")
                            .foregroundColor(.secondary)
                    }
                }
                
                // Section: About & Attributions
                Section {
                    NavigationLink {
                        AboutAttributionView()
                    } label: {
                        Label("О приложении и лицензии", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingModelManager) {
                ModelManagerView()
            }
        }
    }
    
    private func testCloudflareConnection() {
        isTestingConnection = true
        connectionTestResult = nil
        
        Task {
            let res = await CloudflareBrainService.testConnection()
            await MainActor.run {
                self.connectionTestResult = res
                self.isTestingConnection = false
            }
        }
    }
}
