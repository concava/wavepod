@preconcurrency import AVFoundation
import Foundation
import Darwin
import Engine

public enum AudioDecoder {
    /// Bounded buffers all the way from compressed input to 16 kHz mono float WAV.
    public static func decode(_ source: URL, to destination: URL) throws -> AudioAsset {
        try atomicAudio(to: destination) { try decodeUncommitted(source, to: $0) }
    }
    private static func decodeUncommitted(_ source: URL, to destination: URL) throws -> AudioAsset {
        let input = try AVAudioFile(forReading: source)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let incoming = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65536),
              let outgoing = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else {
            throw EngineError.unavailable("This audio format could not be decoded.")
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: destination, settings: settings)
        var readError: Error?
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: outgoing, error: &conversionError) { requested, status in
                do {
                    guard input.framePosition < input.length else { status.pointee = .endOfStream; return nil }
                    try input.read(into: incoming, frameCount: min(requested, incoming.frameCapacity))
                    status.pointee = incoming.frameLength > 0 ? .haveData : .endOfStream
                    return incoming.frameLength > 0 ? incoming : nil
                } catch { readError = error; status.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if outgoing.frameLength > 0 { try output.write(from: outgoing) }
            if status == .endOfStream { break }
            if status == .error { throw EngineError.invalidResult }
        }
        guard output.length > 0 else { throw EngineError.unavailable("The file contains no decodable audio.") }
        return AudioAsset(url: destination, duration: Double(output.length) / 16000)
    }

    public static func slice(_ source: AudioAsset, start: Double, end: Double, to destination: URL) throws -> AudioAsset {
        try atomicAudio(to: destination) { try sliceUncommitted(source, start: start, end: end, to: $0) }
    }
    private static func sliceUncommitted(_ source: AudioAsset, start: Double, end: Double, to destination: URL) throws -> AudioAsset {
        let input = try AVAudioFile(forReading: source.url)
        input.framePosition = AVAudioFramePosition(start * 16000)
        let output = try AVAudioFile(forWriting: destination, settings: input.processingFormat.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65536) else { throw EngineError.invalidResult }
        var remaining = AVAudioFramePosition((end - start) * 16000)
        while remaining > 0 {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 65536)))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return AudioAsset(url: destination, duration: Double(output.length) / 16000)
    }
    private static func atomicAudio(to destination: URL, write: (URL) throws -> AudioAsset) throws -> AudioAsset {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).working.wav")
        defer { try? FileManager.default.removeItem(at: staging) }
        let asset = try write(staging)
        try Task.checkCancellation()
        let status = staging.path.withCString { source in destination.path.withCString { target in rename(source, target) } }
        guard status == 0 else { throw CocoaError(.fileWriteUnknown) }
        return AudioAsset(url: destination, duration: asset.duration)
    }

}
