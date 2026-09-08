//
//  HomeRecordingView.swift
//  GemmaTranscribe
//
//  Main application screen: Liquid Glass styling, BrandWaveform audio visualizer,
//  real-time captions, tactile mic button, and post-STOP AI cards.
//  Adapted from Dictus HomeView & RecordingView.
//

import SwiftUI

public enum HomeActiveSheet: Identifiable {
    case modelManager
    case history
    case settings
    case postStopResult
    
    public var id: String {
        switch self {
        case .modelManager: return "modelManager"
        case .history: return "history"
        case .settings: return "settings"
        case .postStopResult: return "postStopResult"
        }
    }
}

public struct HomeRecordingView: View {
    @ObservedObject var coordinator = LiveTranscriptionCoordinator.shared
    @ObservedObject var modelManager = ModelManager.shared
    
    @State private var activeSheet: HomeActiveSheet? = nil
    
    public var body: some View {
        NavigationStack {
            ZStack {
                // Liquid Glass Background
                Color.dictusBackground
                    .ignoresSafeArea()
                
                VStack(spacing: 20) {
                    
                    // Top Bar: Model Pill + Action Buttons
                    topBarView
                        .padding(.horizontal)
                        .padding(.top, 8)
                    
                    // Model Missing Alert Banner
                    if !modelManager.isModelReady && coordinator.errorText != nil {
                        Button {
                            activeSheet = .modelManager
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.orange)
                                Text(coordinator.errorText ?? "Загрузите веса Gemma 3n")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(10)
                        }
                        .padding(.horizontal)
                    }
                    
                    // Waveform & Status Section
                    waveformSection
                        .padding(.horizontal)
                    
                    // Live Captions / Transcription Container
                    GlassCard {
                        RealtimeTranscriptView(
                            lines: coordinator.transcriptLines,
                            interimText: coordinator.interimText,
                            isRecording: coordinator.status.isRecordingOrTranscribing
                        )
                    }
                    .padding(.horizontal)
                    
                    Spacer(minLength: 10)
                    
                    // Bottom Controls: Tactile Animated Mic Button
                    bottomControlsView
                        .padding(.bottom, 24)
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .modelManager:
                    ModelManagerView()
                case .history:
                    HistoryView()
                case .settings:
                    SettingsView()
                case .postStopResult:
                    PostStopResultCardView(
                        cleanTranscript: coordinator.currentCleanTranscript,
                        response: coordinator.latestBrainResponse,
                        onDismiss: {
                            activeSheet = nil
                            coordinator.isPostStopSheetPresented = false
                        }
                    )
                }
            }
            .onChange(of: coordinator.isPostStopSheetPresented) { presented in
                if presented {
                    activeSheet = .postStopResult
                }
            }
        }
    }
    
    // MARK: - Top Bar
    
    private var topBarView: some View {
        HStack {
            // Model Selector Pill (strictly Gemma 3n E2B)
            Button {
                activeSheet = .modelManager
            } label: {
                HStack(spacing: 6) {
                    let isReady = modelManager.isModelReady || modelManager.isModelDownloaded(modelManager.activeModelId)
                    let isDownloading = modelManager.downloadingModelId != nil
                    
                    Circle()
                        .fill(isReady ? Color.green : (isDownloading ? Color.blue : Color.orange))
                        .frame(width: 8, height: 8)
                    
                    let title: String = {
                        if isDownloading, let progress = modelManager.currentDownloadProgress {
                            return "Gemma 3n: \(progress.percentFormatted)"
                        } else if isReady {
                            return "Gemma 3n E2B (Активна)"
                        } else {
                            return "Gemma 3n E2B (Не скачана)"
                        }
                    }()
                    
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary)
                    
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground).opacity(0.8))
                .clipShape(Capsule())
            }
            
            Spacer()
            
            // History Button
            Button {
                activeSheet = .history
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 38, height: 38)
                    .background(Color(.secondarySystemBackground).opacity(0.8))
                    .clipShape(Circle())
            }
            
            // Settings Button
            Button {
                activeSheet = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 38, height: 38)
                    .background(Color(.secondarySystemBackground).opacity(0.8))
                    .clipShape(Circle())
            }
        }
    }
    
    // MARK: - Waveform & Timer Section
    
    private var waveformSection: some View {
        VStack(spacing: 12) {
            // Status & Elapsed Time
            HStack {
                if coordinator.status == .recording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.dictusRecording)
                            .frame(width: 8, height: 8)
                        Text(formatDuration(coordinator.elapsedSeconds))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundColor(.dictusRecording)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.dictusRecording.opacity(0.12))
                    .clipShape(Capsule())
                } else if coordinator.status == .processing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Cloudflare AI & Search...")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.purple)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.12))
                    .clipShape(Capsule())
                } else {
                    Text("Готов к записи")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // BrandWaveform View
            BrandWaveform(
                energyLevels: coordinator.audioCapture.waveformStore.displayLevels,
                animation: waveformAnimationForStatus(coordinator.status),
                isActive: coordinator.status.isRecordingOrTranscribing
            )
            .frame(height: 52)
        }
        .padding()
        .background(Color(.secondarySystemBackground).opacity(0.5))
        .cornerRadius(16)
    }
    
    // MARK: - Bottom Controls
    
    private var bottomControlsView: some View {
        VStack(spacing: 12) {
            // Animated Mic / STOP Button
            AnimatedMicButton(
                status: coordinator.status,
                isPill: false
            ) {
                Task {
                    await coordinator.toggleRecording()
                }
            }
            .frame(width: 76, height: 76)
            
            Text(statusActionDescription)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var statusActionDescription: String {
        switch coordinator.status {
        case .recording:
            return "Нажмите, чтобы остановить и обработать в Cloudflare"
        case .transcribing:
            return "Gemma 3n E2B: локальная стенография..."
        case .processing:
            return "Cloudflare: AI структурирование и поиск..."
        case .ready:
            return "Нажмите для новой записи"
        case .idle, .failed:
            return "Нажмите для начала записи"
        default:
            return ""
        }
    }
    
    private func waveformAnimationForStatus(_ status: DictationStatus) -> WaveformAnimation {
        switch status {
        case .recording:
            return .micLevels
        case .transcribing:
            return .sweep
        case .processing:
            return .travellingPeak
        default:
            return .still
        }
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
