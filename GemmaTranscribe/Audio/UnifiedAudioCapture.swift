//
//  UnifiedAudioCapture.swift
//  GemmaTranscribe
//
//  Realtime audio capture engine using AVAudioEngine, 16kHz mono Float32 conversion,
//  and streaming chunk emission. Adapted from Dictus UnifiedAudioEngine.
//

import Foundation
import AVFoundation
import Combine
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "UnifiedAudioCapture")

@MainActor
public final class UnifiedAudioCapture: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var elapsedSeconds: Double = 0
    
    public let waveformStore = RecordingWaveformStore(barCount: 30)
    
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    
    private var accumulatedSamples: [Float] = []
    private var chunkEmissionTimer: Timer?
    private var elapsedTimer: Timer?
    private var recordingStartTime: Date?
    
    // Callback when an audio chunk is ready for transcription
    public var onAudioChunkAvailable: (([Float]) -> Void)?
    
    public init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AppConfig.targetSampleRate,
            channels: AppConfig.targetChannels,
            interleaved: false
        ) else {
            fatalError("Failed to initialize target 16kHz mono Float32 AVAudioFormat")
        }
        self.targetFormat = format
    }
    
    public func startCapture(chunkDuration: Double = AppConfig.defaultAudioChunkDuration) async throws {
        guard !isRecording else { return }
        
        // Request microphone permission if needed
        let permissionGranted: Bool
        if #available(iOS 17.0, *) {
            permissionGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            permissionGranted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
        guard permissionGranted else {
            logger.error("Microphone permission denied")
            throw NSError(domain: "GemmaTranscribe.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }
        
        try await AudioSessionCoordinator.shared.activateRecording()
        
        // Reset buffers
        accumulatedSamples.removeAll(keepingCapacity: true)
        elapsedSeconds = 0
        waveformStore.reset()
        
        // Rebuild engine if needed
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = AVAudioEngine()
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            logger.error("Input node reports unusable hardware format")
            throw NSError(domain: "GemmaTranscribe.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Hardware audio input not available"])
        }
        
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        
        let bufferSize: AVAudioFrameCount = 2048
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processIncomingBuffer(buffer)
        }
        
        try engine.start()
        isRecording = true
        recordingStartTime = Date()
        
        // Timer for elapsed seconds
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.recordingStartTime else { return }
            self.elapsedSeconds = Date().timeIntervalSince(start)
        }
        
        // Timer for streaming chunks (1-3s window)
        let interval = max(1.0, min(chunkDuration, 3.0))
        chunkEmissionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.emitAccumulatedChunk()
        }
        
        logger.info("Audio capture started: target 16kHz Float32 mono, chunkInterval=\(interval)s")
    }
    
    public func stopCapture() async -> [Float] {
        guard isRecording else { return [] }
        
        isRecording = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        chunkEmissionTimer?.invalidate()
        chunkEmissionTimer = nil
        
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        await AudioSessionCoordinator.shared.deactivateRecording()
        
        let finalSamples = accumulatedSamples
        accumulatedSamples.removeAll()
        waveformStore.reset()
        
        logger.info("Audio capture stopped: captured \(finalSamples.count) samples (~ \(String(format: "%.2f", Double(finalSamples.count) / AppConfig.targetSampleRate))s)")
        return finalSamples
    }
    
    private func processIncomingBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        
        // Calculate RMS power for waveform
        let rms = calculateRMS(buffer: buffer)
        Task { @MainActor in
            self.waveformStore.update(power: rms)
        }
        
        // Convert to 16kHz mono Float32
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 128
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return
        }
        
        var error: NSError?
        var hasProvidedInput = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !hasProvidedInput {
                hasProvidedInput = true
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        if let error = error {
            logger.error("Audio conversion failed: \(error.localizedDescription)")
            return
        }
        
        guard let floatData = outputBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
        
        Task { @MainActor in
            self.accumulatedSamples.append(contentsOf: samples)
        }
    }
    
    private func emitAccumulatedChunk() {
        guard !accumulatedSamples.isEmpty else { return }
        let chunk = accumulatedSamples
        // Emit chunk for realtime speech transcription
        onAudioChunkAvailable?(chunk)
    }
    
    private func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData?[0] else { return 0.05 }
        let length = Int(buffer.frameLength)
        guard length > 0 else { return 0.05 }
        
        var sum: Float = 0
        for i in 0..<length {
            let sample = floatData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(length))
        // Map 0.0...1.0 with non-linear boost for speech
        return min(max(rms * 5.0, 0.05), 1.0)
    }
}
