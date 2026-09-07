//
//  ModelCardView.swift
//  GemmaTranscribe
//
//  Card view displaying model metadata, accuracy/speed gauges, download actions,
//  and active model status. Adapted from Dictus ModelCardView.
//

import SwiftUI

public struct ModelCardView: View {
    let model: ModelInfo
    let isDownloaded: Bool
    let isActive: Bool
    let isDownloading: Bool
    let downloadProgress: ModelDownloadProgress?
    
    let onDownload: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            
            // Header: Title & Badges
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.displayName)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        if model.isDefaultRecommended {
                            Text("Рекомендуемая")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.dictusAccent)
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text("by \(model.author) • \(model.format)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Size Badge
                Text(model.sizeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.dictusAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.dictusAccent.opacity(0.12))
                    .clipShape(Capsule())
            }
            
            // Description
            Text(model.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            // Metrics (Accuracy & Speed)
            HStack(spacing: 20) {
                metricGauge(label: "Точность", value: model.accuracyScore, color: .green)
                metricGauge(label: "Скорость", value: model.speedScore, color: .blue)
                
                Spacer()
                
                if model.downloads > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        Text("\(model.downloads)")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
            }
            
            // Progress Bar if Downloading
            if isDownloading, let progress = downloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .tint(.dictusAccent)
                    
                    HStack {
                        Text("\(progress.downloadedMB) MB / \(progress.totalMB) MB")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text(progress.percentFormatted)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.dictusAccent)
                    }
                }
            }
            
            Divider()
            
            // Action Buttons
            HStack {
                if isDownloaded {
                    if isActive {
                        Label("Активная модель", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.green)
                    } else {
                        Button {
                            onSelect()
                        } label: {
                            Text("Выбрать модель")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    
                    Spacer()
                    
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .foregroundColor(.red.opacity(0.8))
                    }
                } else if isDownloading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Скачивание...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button {
                        onDownload()
                    } label: {
                        Label("Скачать на устройство", systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.dictusAccent)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isActive ? Color.green.opacity(0.5) : Color.clear, lineWidth: 2)
        )
    }
    
    private func metricGauge(label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            
            HStack(spacing: 4) {
                ProgressView(value: value)
                    .tint(color)
                    .frame(width: 50)
                
                Text("\(Int(value * 100))%")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(color)
            }
        }
    }
}
