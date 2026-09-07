//
//  UnifiedAudioCapture.swift
//  GemmaTranscribe
//
//  Unified 16kHz mono audio capture engine with real-time waveform RMS calculation.
//  Adapted from LiveTranscriber UnifiedAudioPipeline.
//

import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "UnifiedAudioCapture")

@MainActor
public final class UnifiedAudioCapture: ObservableObject {
    public var onAudioChunkAvailable: (([Float]) -> Void)?
    public var onRawBufferAvailable: ((AVAudioPCMBuffer) -> Void)?
    public var onElapsedSecondsUpdated: ((Double) -> Void)?
    
    @Published public private(set) var isRecording = false
    @Published public private(set) var elapsedSeconds: Double = 0
    public let waveformStore = RecordingWaveformStore()
    
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private var accumulatedSamples: [Float] = []
    private var totalSessionSamples: [Float] = []
    private var loopTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    
    public init() {
        // Gemma 3n E2B expects 16,000Hz mono Float32 audio
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AppConfig.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }
    
    public func startCapture(chunkDuration: TimeInterval = AppConfig.defaultAudioChunkDuration) async throws {
        guard !isRecording else { return }
        
        let permissionGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard permissionGranted else {
            logger.error("Microphone permission denied by user")
            throw NSError(domain: "GemmaTranscribe.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Доступ к микрофону запрещен в настройках"])
        }
        
        try await AudioSessionCoordinator.shared.activateRecording()
        
        // Reset state
        accumulatedSamples.removeAll(keepingCapacity: true)
        totalSessionSamples.removeAll(keepingCapacity: true)
        elapsedSeconds = 0
        onElapsedSecondsUpdated?(0)
        waveformStore.reset()
        
        // Rebuild engine safely
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = AVAudioEngine()
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            logger.error("Input node reports unusable hardware format: \(inputFormat, privacy: .public)")
            throw NSError(domain: "GemmaTranscribe.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Аудиовход микрофона недоступен"])
        }
        
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        
        let bufferSize: AVAudioFrameCount = 2048
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processIncomingBuffer(buffer)
            self?.onRawBufferAvailable?(buffer)
        }
        
        engine.prepare()
        try engine.start()
        
        isRecording = true
        let start = Date()
        recordingStartTime = start
        
        let interval = max(1.0, min(chunkDuration, 3.0))
        
        // Concurrency-safe timer and chunk loop independent of RunLoop modes
        loopTask?.cancel()
        loopTask = Task { [weak self, start, interval] in
            var lastChunkEmission = start
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                guard let self = self, self.isRecording else { break }
                
                let now = Date()
                let elapsed = now.timeIntervalSince(start)
                self.elapsedSeconds = elapsed
                self.onElapsedSecondsUpdated?(elapsed)
                
                if now.timeIntervalSince(lastChunkEmission) >= interval {
                    self.emitAccumulatedChunk()
                    lastChunkEmission = now
                }
            }
        }
        
        logger.info("Audio capture started successfully: 16kHz Float32 mono, chunkInterval=\(interval)s")
    }
    
    public func stopCapture() async -> [Float] {
        guard isRecording else { return [] }
        
        isRecording = false
        loopTask?.cancel()
        loopTask = nil
        
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        await AudioSessionCoordinator.shared.deactivateRecording()
        
        let allSamples = totalSessionSamples
        accumulatedSamples.removeAll()
        totalSessionSamples.removeAll()
        waveformStore.reset()
        
        logger.info("Audio capture stopped: captured \(allSamples.count) samples")
        return allSamples
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
            self.totalSessionSamples.append(contentsOf: samples)
        }
    }
    
    private func emitAccumulatedChunk() {
        guard !accumulatedSamples.isEmpty else { return }
        let chunk = accumulatedSamples
        accumulatedSamples.removeAll(keepingCapacity: true)
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
        return min(max(rms * 5.0, 0.05), 1.0)
    }
}
