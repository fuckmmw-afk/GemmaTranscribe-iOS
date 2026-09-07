//
//  SettingsView.swift
//  GemmaTranscribe
//
//  Settings screen: audio pipeline tuning, speech filler filters,
//  Cloudflare endpoint configuration, and runtime diagnostics.
//

import SwiftUI

public struct SettingsView: View {
    @ObservedObject var modelManager = ModelManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage(AppConfig.audioChunkDurationKey) private var chunkDuration: Double = AppConfig.defaultAudioChunkDuration
    @AppStorage(AppConfig.cleanFillersEnabledKey) private var cleanFillers: Bool = true
    @AppStorage(AppConfig.cloudflareWorkerUrlKey) private var cloudflareUrl: String = AppConfig.defaultCloudflareWorkerUrl
    
    @State private var showingModelManager = false
    
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
                
                // Section: Audio & Streaming Pipeline
                Section(header: Text("Параметры Realtime транскрипции"), footer: Text("Интервал между отправками аудиофрагментов в локальную модель. Допустимо от 1.0 до 3.0 секунд (приоритет качества).")) {
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
                    
                    Toggle("Очистка речевого мусора", isOn: $cleanFillers)
                }
                
                // Section: Cloudflare Brain Pipeline
                Section(header: Text("Cloudflare AI & Web Search (После STOP)"), footer: Text("На Cloudflare отправляется только очищенный текст. Аудио никогда не передается в сеть.")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("URL Cloudflare Worker")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("https://...", text: $cloudflareUrl)
                            .font(.subheadline)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
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
}
