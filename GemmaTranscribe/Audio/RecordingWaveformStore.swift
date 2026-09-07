//
//  RecordingWaveformStore.swift
//  GemmaTranscribe
//
//  Maintains real-time audio power levels for BrandWaveform animation.
//  Adapted from LiveTranscriber and Dictus waveform stores.
//

import Foundation
import Combine

@MainActor
public final class RecordingWaveformStore: ObservableObject {
    @Published public private(set) var displayLevels: [Float]
    
    private let barCount: Int
    private let smoothingFactor: Float = 0.3
    
    public init(barCount: Int = 30) {
        self.barCount = barCount
        self.displayLevels = Array(repeating: 0.05, count: barCount)
    }
    
    /// Appends new power level (0.0 ... 1.0) and shifts levels with smoothing
    public func update(power: Float) {
        let clampedPower = min(max(power, 0.02), 1.0)
        
        var updated = displayLevels
        // Shift left
        if updated.count >= barCount {
            updated.removeFirst()
        }
        
        // Smooth transition
        let last = updated.last ?? 0.05
        let smoothed = last + (clampedPower - last) * smoothingFactor
        updated.append(smoothed)
        
        while updated.count < barCount {
            updated.insert(0.05, at: 0)
        }
        
        self.displayLevels = updated
    }
    
    public func reset() {
        self.displayLevels = Array(repeating: 0.05, count: barCount)
    }
}
