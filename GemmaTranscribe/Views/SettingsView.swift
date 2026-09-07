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
    @AppStorage(AppConfig.cloudflareModeKey) private var cloudflareMode: Int = 0 // 0: Direct Workers AI, 1: Custom Worker
    @AppStorage(AppConfig.cloudflareWorkerUrlKey) private var cloudflareUrl: String = AppConfig.defaultCloudflareWorkerUrl
    @AppStorage(AppConfig.cloudflareApiKeyKey) private var cloudflareApiKey: String = ""
    @AppStorage(AppConfig.cloudflareAccountIdKey) private var cloudflareAccountId: String = ""
    @AppStorage(AppConfig.cloudflareEmailKey) private var cloudflareEmail: String = ""
    @AppStorage(AppConfig.cloudflareDirectModelKey) private var cloudflareModel: String = AppConfig.defaultCloudflareDirectModel
    @AppStorage(AppConfig.huggingFaceTokenKey) private var huggingFaceToken: String = ""
    
    @State private var showingModelManager = false
    @State private var isTestingConnection = false
    @State private var connectionTestResult: (success: Bool, message: String)?
    @State private var isSecureApiKey = true
    @State private var isSecureHfToken = true
    @State private var showGlobalKeyEmail = false
    
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
                    footer: Text("На Cloudflare отправляется только очищенный текст для структурирования и поиска. Аудио никогда не передается в сеть.")
                ) {
                    Picker("Тип подключения", selection: $cloudflareMode) {
                        Text("Direct Workers AI (Прямой API)").tag(0)
                        Text("Собственный Worker").tag(1)
                    }
                    .pickerStyle(.segmented)
                    
                    if cloudflareMode == 0 {
                        // Direct Cloudflare Workers AI
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Account ID (32 символа)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("например: 6d4f2e2b09179bb2068200d4632caaf2", text: $cloudflareAccountId)
                                .font(.system(.subheadline, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .onChange(of: cloudflareAccountId) { newValue in
                                    cleanAccountId(newValue)
                                }
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Модель Cloudflare")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("@cf/meta/llama-3.1-8b-instruct", text: $cloudflareModel)
                                .font(.system(.subheadline, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                    } else {
                        // Custom Worker
                        VStack(alignment: .leading, spacing: 6) {
                            Text("URL Cloudflare Worker")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("https://your-worker.workers.dev", text: $cloudflareUrl)
                                .font(.subheadline)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Token Cloudflare (Bearer)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            if isSecureApiKey {
                                SecureField("Cloudflare API Token", text: $cloudflareApiKey)
                                    .font(.subheadline)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            } else {
                                TextField("Cloudflare API Token", text: $cloudflareApiKey)
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
                    
                    // Toggle for Global API Key Email
                    DisclosureGroup("Использовать Global API Key вместо Token", isExpanded: $showGlobalKeyEmail) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Email учетной записи Cloudflare")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("ваш-email@domain.com", text: $cloudflareEmail)
                                .font(.subheadline)
                                .autocapitalization(.none)
                                .keyboardType(.emailAddress)
                                .disableAutocorrection(true)
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    // Endpoint preview
                    if let resolved = CloudflareBrainService.resolveEndpoint() {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Активный эндпоинт:")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                            Text(resolved.url.absoluteString)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
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
            .onAppear {
                if !cloudflareEmail.isEmpty {
                    showGlobalKeyEmail = true
                }
            }
        }
    }
    
    private func cleanAccountId(_ input: String) {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "(?<=accounts/)[a-fA-F0-9]{32}", options: .regularExpression) {
            trimmed = String(trimmed[range])
        } else if let hexRange = trimmed.range(of: "[a-fA-F0-9]{32}", options: .regularExpression) {
            trimmed = String(trimmed[hexRange])
        }
        if trimmed != input {
            cloudflareAccountId = trimmed
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
