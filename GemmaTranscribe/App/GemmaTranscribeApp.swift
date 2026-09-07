//
//  GemmaTranscribeApp.swift
//  GemmaTranscribe
//
//  Application entry point for GemmaTranscribe.
//

import SwiftUI

@main
struct GemmaTranscribeApp: App {
    @StateObject private var coordinator = LiveTranscriptionCoordinator.shared
    @StateObject private var modelManager = ModelManager.shared
    @StateObject private var historyStore = TranscriptionHistoryStore.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .environmentObject(modelManager)
                .environmentObject(historyStore)
                .preferredColorScheme(.dark) // Sleek modern dark Liquid Glass theme by default
        }
    }
}
