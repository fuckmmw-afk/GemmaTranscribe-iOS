//
//  PersistentLog.swift
//  GemmaTranscribe
//
//  Diagnostic logging wrapper for waveform and UI lifecycle events.
//

import Foundation
import os.log

public enum PersistentLog {
    private static let logger = Logger(subsystem: "com.gemmatranscribe.app", category: "PersistentLog")
    
    public enum Event {
        case waveformAppeared(bars: Int, animation: String)
        case waveformDisappeared(bars: Int)
        case waveformStall(gapSeconds: Double)
        case waveformHeartbeat(activeBars: Int, maxGapSeconds: Double)
        case rapidTapRejected
    }
    
    public static func log(_ event: Event) {
        #if DEBUG
        switch event {
        case .waveformAppeared(let bars, let animation):
            logger.debug("Waveform appeared: \(bars) bars, animation=\(animation)")
        case .waveformDisappeared(let bars):
            logger.debug("Waveform disappeared: \(bars) bars")
        case .waveformStall(let gap):
            logger.debug("Waveform stall: gap=\(gap)s")
        case .waveformHeartbeat(let activeBars, let maxGap):
            logger.debug("Waveform heartbeat: \(activeBars) active bars, maxGap=\(maxGap)s")
        case .rapidTapRejected:
            logger.debug("Rapid tap rejected")
        }
        #endif
    }
}
