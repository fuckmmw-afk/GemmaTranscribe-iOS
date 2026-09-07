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
        case waveformAppeared(refreshID: Int, isProcessing: Bool, energyCount: Int, killedState: Bool)
        case waveformDisappeared(refreshID: Int, renderTick: Int)
        case waveformStall(gapMs: Int, renderTick: Int, energyCount: Int)
        case waveformHeartbeat(renderTick: Int, avgLevel: Float, energyCount: Int, maxGapMs: Int)
        case rapidTapRejected
    }
    
    public static func log(_ event: Event) {
        #if DEBUG
        switch event {
        case .waveformAppeared(let refreshID, let isProcessing, let energyCount, let killedState):
            logger.debug("Waveform appeared: refreshID=\(refreshID), isProcessing=\(isProcessing), count=\(energyCount), killed=\(killedState)")
        case .waveformDisappeared(let refreshID, let renderTick):
            logger.debug("Waveform disappeared: refreshID=\(refreshID), renderTick=\(renderTick)")
        case .waveformStall(let gapMs, let renderTick, let energyCount):
            logger.debug("Waveform stall: gap=\(gapMs)ms, renderTick=\(renderTick), count=\(energyCount)")
        case .waveformHeartbeat(let renderTick, let avgLevel, let energyCount, let maxGapMs):
            logger.debug("Waveform heartbeat: renderTick=\(renderTick), avg=\(avgLevel), count=\(energyCount), maxGap=\(maxGapMs)ms")
        case .rapidTapRejected:
            logger.debug("Rapid tap rejected")
        }
        #endif
    }
}
