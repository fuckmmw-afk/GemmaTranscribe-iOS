//
//  AboutAttributionView.swift
//  GemmaTranscribe
//
//  About screen and mandatory open-source attributions.
//

import SwiftUI

public struct AboutAttributionView: View {
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // App identity
                VStack(alignment: .center, spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.dictusAccent)
                    
                    Text("GemmaTranscribe")
                        .font(.title2.weight(.bold))
                    
                    Text("Версия \(AppConfig.appVersion)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("Локальная речь в текст на базе Google Gemma 3n E2B (LiteRT) и Cloudflare Brain.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
                
                Divider()
                
                // Open-Source Attributions
                VStack(alignment: .leading, spacing: 16) {
                    Text("Использованные открытые проекты")
                        .font(.headline)
                    
                    // LiveTranscriber attribution (Mandatory by license)
                    attributionCard(
                        title: "LiveTranscriber",
                        author: "William Li",
                        notice: "Based on LiveTranscriber by William Li.\nOriginal project: https://github.com/iamwilliamli/LiveTranscriber",
                        url: "https://github.com/iamwilliamli/LiveTranscriber"
                    )
                    
                    // Dictus attribution
                    attributionCard(
                        title: "Dictus iOS",
                        author: "PIVI Solutions (MIT License)",
                        notice: "SwiftUI interface, Model Manager, and audio capture architecture adapted from Dictus iOS.",
                        url: "https://github.com/getdictus/dictus-ios"
                    )
                    
                    // LiquidGlass attribution
                    attributionCard(
                        title: "LiquidGlass",
                        author: "rguillen-dev (MIT License)",
                        notice: "Modern iOS 26 Liquid Glass components and frosted styling.",
                        url: "https://github.com/rguillen-dev/LiquidGlass"
                    )
                    
                    // Google AI Edge / LiteRT attribution
                    attributionCard(
                        title: "Google AI Edge & LiteRT",
                        author: "Google LLC (Apache 2.0)",
                        notice: "On-device runtime engine for Google Gemma 3n E2B models.",
                        url: "https://github.com/google-ai-edge/LiteRT-LM"
                    )
                }
            }
            .padding()
        }
        .navigationTitle("О приложении")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func attributionCard(title: String, author: String, notice: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Spacer()
                if let linkURL = URL(string: url) {
                    Link(destination: linkURL) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundColor(.dictusAccent)
                    }
                }
            }
            
            Text(author)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
            
            Text(notice)
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.85))
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}
