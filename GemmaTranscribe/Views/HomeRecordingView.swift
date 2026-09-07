//
//  HomeRecordingView.swift
//  GemmaTranscribe
//
//  Main application screen: Liquid Glass styling, BrandWaveform audio visualizer,
//  real-time captions, tactile mic button, and post-STOP AI cards.
//  Adapted from Dictus HomeView & RecordingView.
//

import SwiftUI

public struct HomeRecordingView: View {
    @ObservedObject var coordinator = LiveTranscriptionCoordinator.shared
    @ObservedObject var modelManager = ModelManager.shared
    
    @State private var showingModelManager = false
    @State private var showingHistory = false
    @State private var showingSettings = false
    
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
                    
                    // Waveform & Status Section
                    waveformSection
                        .padding(.horizontal)
                    
                    // Live Captions / Transcription Container
                    GlassCard(cornerRadius: 20) {
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
            .sheet(isPresented: $showingModelManager) {
                ModelManagerView()
            }
            .sheet(isPresented: $showingHistory) {
                HistoryView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $coordinator.isPostStopSheetPresented) {
                PostStopResultCardView(
                    cleanTranscript: coordinator.currentCleanTranscript,
                    response: coordinator.latestBrainResponse,
                    onDismiss: {
                        coordinator.isPostStopSheetPresented = false
                    }
                )
            }
        }
    }
    
    // MARK: - Top Bar
    
    private var topBarView: some View {
        HStack {
            // Model Selector Pill
            Button {
                showingModelManager = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(modelManager.isModelDownloaded(modelManager.activeModelId) ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    
                    let shortName = modelManager.activeModelId.components(separatedBy: "/").last?
                        .replacingOccurrences(of: "-it-litert-lm", with: "")
                        .replacingOccurrences(of: "gemma-3n-", with: "Gemma 3n ") ?? "Gemma 3n E2B"
                    
                    Text(shortName)
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
                showingHistory = true
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
                showingSettings = true
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
                        Text(formatDuration(coordinator.audioCapture.elapsedSeconds))
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
                
                if let error = coordinator.errorText {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
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
            return "Завершение локальной транскрипции..."
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
            return .processingSine
        case .processing:
            return .processingPeak
        default:
            return .micLevels
        }
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
