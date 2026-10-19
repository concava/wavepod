import Engine
import Foundation
import NativeEngine
import Pipeline
import XCTest

final class NativeSmokeTests: XCTestCase {
    func testNativeASRAndDiarizationOnRealAudio() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let models = env["WAVEPOD_NATIVE_MODELS"], let audioPath = env["WAVEPOD_SMOKE_AUDIO"] else {
            throw XCTSkip("Set WAVEPOD_NATIVE_MODELS and WAVEPOD_SMOKE_AUDIO for the opt-in model integration run.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = try AudioDecoder.decode(URL(fileURLWithPath: audioPath), to: root.appendingPathComponent("decoded.wav"))
        let window = try AudioDecoder.slice(asset, start: 0, end: min(45, asset.duration), to: root.appendingPathComponent("window.wav"))
        let engine = NativeEngine(models: URL(fileURLWithPath: models))
        let raw = try await engine.transcribe(window, options: .init(language: env["WAVEPOD_SMOKE_LANGUAGE"] ?? "en"), progress: { _ in })
        XCTAssertFalse(raw.words.isEmpty)
        XCTAssertTrue(raw.words.contains { !$0.word.text.hasPrefix("[") })
        XCTAssertTrue(raw.words.allSatisfy { $0.word.start >= 0 && $0.word.end <= window.duration + 1 })
        let diar = try await engine.diarize(window)
        XCTAssertFalse(diar.turns.isEmpty)
        XCTAssertEqual(diar.embeddings.isEmpty, !OfflineDiarizationSupport.current.isAvailable)
        let cached = try await engine.transcribe(window, options: .init(language: env["WAVEPOD_SMOKE_LANGUAGE"] ?? "en"), progress: { _ in })
        XCTAssertEqual(cached.words, raw.words)
    }
}
