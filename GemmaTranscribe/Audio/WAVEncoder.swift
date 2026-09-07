//
//  WAVEncoder.swift
//  GemmaTranscribe
//
//  Lightweight encoder from Float PCM samples to 16kHz 16-bit mono WAV.
//

import Foundation

public enum WAVEncoder {
    public static func encode(samples: [Float], sampleRate: Int = 16000) -> Data {
        let sampleCount = samples.count
        let byteRate = sampleRate * 2 // 16-bit mono = 2 bytes per sample
        let dataSize = sampleCount * 2
        let fileSize = 36 + dataSize
        
        var data = Data(capacity: 44 + dataSize)
        
        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        
        // "fmt " chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Subchunk1Size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // AudioFormat = 1 (PCM)
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // NumChannels = 1
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })  // BlockAlign = 2
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // BitsPerSample = 16
        
        // "data" chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        
        // Convert Float32 [-1.0, 1.0] to Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: intSample.littleEndian) { Array($0) })
        }
        
        return data
    }
}
