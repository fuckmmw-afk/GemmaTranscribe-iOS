//
//  UnifiedAudioCapture.swift
//  GemmaTranscribe
//
//  Modular AudioPipeline modeled after Google AI Edge:
//  1. AudioCaptureLayer: Microphone hardware access, session activation, permissions.
//  2. AudioPreprocessingLayer: Resampling to standard 16 kHz Float32 mono PCM and RMS power calculation.
//  3. Streaming chunks for on-device Gemma 3n ASR.
//

import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "AudioPipeline")

/// Protocol for hardware audio capture
@MainActor
public protocol AudioCaptureProtocol: AnyObject {
    var isRecording: Bool { get }
    func startCapture(chunkDuration: TimeInterval) async throws
    func stopCapture() async -> [Float]
}

/// Protocol for audio conversion and preprocessing (16kHz mono Float32)
public protocol AudioPreprocessingProtocol: Sendable {
    func convert(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat, converter: AVAudioConverter) -> [Float]?
    func calculateRMS(buffer: AVAudioPCMBuffer) -> Float
}

/// Real-time preprocessor implementation
public struct StandardAudioPreprocessor: AudioPreprocessingProtocol {
    public init() {}
    
    public func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.0 }
        
        var sumSquares: Float = 0.0
        for channel in 0..<channelCount {
            let data = channelData[channel]
            for frame in 0..<frameLength {
                let sample = data[frame]
                sumSquares += sample * sample
            }
        }
        
        let meanSquare = sumSquares / Float(frameLength * channelCount)
        let rms = sqrt(meanSquare)
        let minDb: Float = -60.0
        let db = 20.0 * log10(max(rms, 0.00001))
        let normalized = max(0.0, min(1.0, (db - minDb) / (0.0 - minDb)))
        return normalized
    }
    
    public func convert(
        buffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> [Float]? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 128
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return nil
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
        
        guard error == nil, let channelData = outputBuffer.floatChannelData, outputBuffer.frameLength > 0 else {
            return nil
        }
        
        let frameCount = Int(outputBuffer.frameLength)
        let channelCount = Int(outputBuffer.format.channelCount)
        
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        } else {
            // Downmix multi-channel to mono
            var mono = [Float](repeating: 0, count: frameCount)
            for ch in 0..<channelCount {
                let ptr = channelData[ch]
                for i in 0..<frameCount {
                    mono[i] += ptr[i]
                }
            }
            let scale = 1.0 / Float(channelCount)
            for i in 0..<frameCount {
                mono[i] *= scale
            }
            return mono
        }
    }
}

/// Unified Audio Pipeline coordinating capture and preprocessing
@MainActor
public final class UnifiedAudioCapture: ObservableObject, AudioCaptureProtocol {
    public var onAudioChunkAvailable: (([Float]) -> Void)?
    public var onRawBufferAvailable: ((AVAudioPCMBuffer) -> Void)?
    public var onElapsedSecondsUpdated: ((Double) -> Void)?
    
    @Published public private(set) var isRecording = false
    @Published public private(set) var elapsedSeconds: Double = 0
    public let waveformStore = RecordingWaveformStore()
    
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let preprocessor = StandardAudioPreprocessor()
    private var accumulatedSamples: [Float] = []
    private var totalSessionSamples: [Float] = []
    private var loopTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    
    public init() {
        // Gemma 3n E2B / LiteRT expects 16,000Hz mono Float32 audio
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
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            logger.error("Input node reports unusable hardware format: \(inputFormat, privacy: .public)")
            throw NSError(domain: "GemmaTranscribe.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Аудиовход микрофона недоступен"])
        }
        
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        
        let bufferSize: AVAudioFrameCount = 2048
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRecording else { return }
                self.processIncomingBuffer(buffer)
                self.onRawBufferAvailable?(buffer)
            }
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
        guard isRecording else { return totalSessionSamples }
        
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
        let rms = preprocessor.calculateRMS(buffer: buffer)
        let converted = preprocessor.convert(buffer: buffer, targetFormat: targetFormat, converter: converter)
        
        self.waveformStore.update(power: rms)
        if let samples = converted {
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
}

/// Convenience alias to explicitly represent AudioPipeline
public typealias AudioPipeline = UnifiedAudioCapture
