//
//  AudioSessionCoordinator.swift
//  GemmaTranscribe
//
//  Coordinates AVAudioSession activation, routing, and interruption handling.
//  Adapted from LiveTranscriber's AppAudioSessionCoordinator.
//

import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "AudioSession")

public actor AudioSessionCoordinator {
    public static let shared = AudioSessionCoordinator()
    
    private var isSessionActive = false
    
    private init() {}
    
    public func activateRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers, .allowBluetooth, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(AppConfig.targetSampleRate)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        isSessionActive = true
        
        logger.info("Recording audio session activated: sampleRate=\(session.sampleRate, privacy: .public)")
    }
    
    public func deactivateRecording() {
        guard isSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isSessionActive = false
        logger.info("Recording audio session deactivated")
    }
}
