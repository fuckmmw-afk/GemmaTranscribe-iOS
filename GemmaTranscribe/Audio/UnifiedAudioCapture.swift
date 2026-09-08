//
//  UnifiedAudioCapture.swift
//  GemmaTranscribe
//
//  Audio capture and preprocessing architecture modeled after Google AI Edge.
//  Coordinates hardware AVAudioEngine microphone input, converts to 16,000Hz mono Float32,
//  and computes real-time RMS power levels for BrandWaveform.
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
    
    public func convert(
        buffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> [Float]? {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)
        )
        guard frameCapacity > 0,
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return nil
        }
        
        var error: NSError?
        var hasProvidedData = false
        
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if !hasProvidedData {
                hasProvidedData = true
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        if let error = error {
            logger.error("Audio conversion failed: \(error.localizedDescription)")
            return nil
        }
        
        guard let channelData = convertedBuffer.floatChannelData else { return nil }
        let channelCount = Int(convertedBuffer.format.channelCount)
        let frameLength = Int(convertedBuffer.frameLength)
        
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        } else {
            // Downmix multi-channel to mono
            var mono = [Float](repeating: 0, count: frameLength)
            for ch in 0..<channelCount {
                let ptr = channelData[ch]
                for i in 0..<frameLength {
                    mono[i] += ptr[i]
                }
            }
            let scale = 1.0 / Float(channelCount)
            for i in 0..<frameLength {
                mono[i] *= scale
            }
            return mono
        }
    }
    
    public func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let ptr = channelData[0]
        let length = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<length {
            sum += ptr[i] * ptr[i]
        }
        let rms = sqrt(sum / Float(length))
        return min(max(rms * 5.0, 0), 1) // Scaled normalized energy
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
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }
    
    public func startCapture(chunkDuration: TimeInterval = 2.0) async throws {
        guard !isRecording else { return }
        
        try await AudioSessionCoordinator.shared.activateRecording()
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "UnifiedAudioCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "Недопустимый формат аудио оборудования"])
        }
        
        self.converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        self.accumulatedSamples.removeAll()
        self.totalSessionSamples.removeAll()
        self.waveformStore.reset()
        self.recordingStartTime = Date()
        self.elapsedSeconds = 0
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processIncomingBuffer(buffer)
        }
        
        try engine.start()
        isRecording = true
        logger.info("Audio capture started with sampleRate: \(inputFormat.sampleRate)Hz -> 16000Hz mono")
        
        startEmissionLoop(interval: chunkDuration)
    }
    
    public func stopCapture() async -> [Float] {
        guard isRecording else { return totalSessionSamples }
        
        loopTask?.cancel()
        loopTask = nil
        
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        
        isRecording = false
        await AudioSessionCoordinator.shared.deactivateRecording()
        
        // Return full session samples (16kHz Float32 mono)
        let captured = totalSessionSamples
        logger.info("Audio capture stopped. Total session samples collected: \(captured.count)")
        
        accumulatedSamples.removeAll()
        totalSessionSamples.removeAll()
        waveformStore.reset()
        
        return captured
    }
    
    private func startEmissionLoop(interval: TimeInterval) {
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self = self, self.isRecording else { break }
                
                if let start = self.recordingStartTime {
                    let elapsed = Date().timeIntervalSince(start)
                    self.elapsedSeconds = elapsed
                    self.onElapsedSecondsUpdated?(elapsed)
                }
                
                // Emit chunk if samples are available
                if !self.accumulatedSamples.isEmpty {
                    let chunk = self.accumulatedSamples
                    self.accumulatedSamples.removeAll()
                    self.onAudioChunkAvailable?(chunk)
                }
            }
        }
    }
    
    nonisolated private func processIncomingBuffer(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor [weak self] in
            guard let self = self, self.isRecording else { return }
            self.onRawBufferAvailable?(buffer)
        }
        
        guard let converter = self.converter else { return }
        
        // Calculate RMS power for waveform
        let rms = preprocessor.calculateRMS(buffer: buffer)
        let converted = preprocessor.convert(buffer: buffer, targetFormat: targetFormat, converter: converter)
        
        Task { @MainActor in
            self.waveformStore.update(power: rms)
            if let samples = converted {
                self.accumulatedSamples.append(contentsOf: samples)
                self.totalSessionSamples.append(contentsOf: samples)
            }
        }
    }
}

/// Typealias for compatibility with existing codebase
public typealias AudioPipeline = UnifiedAudioCapture
