import Engine
import Foundation
import Library
import Pipeline
import XCTest

final class OfflineDiarizationTests: XCTestCase {
    func testMacOS14UsesOneSpeakerAcrossWindowsAndIgnoresOldDiarization() async throws {
        for (hasOldCheckpoint, includeASRSpeakers) in [(false, false), (false, true), (true, true)] {
            let folder = try fixture(includeASRSpeakers: includeASRSpeakers)
            if hasOldCheckpoint {
                // Even an unreadable old checkpoint must not affect the macOS 14 fallback.
                try Data("old checkpoint".utf8).write(to: folder.appendingPathComponent("diar-0.json"))
            }
            let diarizer = RecordingDiarizer()
            var transcriber = WindowedTranscriber(engine: UnusedEngine(), diarizer: diarizer,
                diarizationSupport: .init(macOSVersion: .init(majorVersion: 14, minorVersion: 8, patchVersion: 9)))
            transcriber.windowLength = 2
            transcriber.overlap = 1
            let result = try await transcriber.run(AudioAsset(url: folder.appendingPathComponent("unused.wav"), duration: 3),
                                                   language: "en", folder: folder) { _, _ in }
            let calls = await diarizer.calls
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(result.language, "en")
            XCTAssertEqual(result.words.map(\.word.text), ["hello", "again"])
            XCTAssertEqual(result.words.map(\.word.start), [0.2, 1.7])
            XCTAssertEqual(Set(result.words.compactMap(\.speaker)), ["S1"])
            XCTAssertTrue(result.words.allSatisfy { !$0.word.overlap })
            XCTAssertEqual(result.turns, [SpeakerTurn(speaker: "S1", start: 0, end: 3)])
            XCTAssertTrue(result.embeddings.isEmpty)
            let rendered = try WordAlignment.render(result)
            XCTAssertEqual(Set(rendered.segments.map(\.speaker.rawValue)), ["S1"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("diar-1.json").path),
                           "Fallback must not prevent real diarization after an OS upgrade")
            if hasOldCheckpoint {
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("diar-0.json")), Data("old checkpoint".utf8))
            } else {
                // Resume the same ASR checkpoints after upgrading: diarization must run for every window.
                transcriber.diarizationSupport = .init(macOSVersion: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0))
                _ = try await transcriber.run(AudioAsset(url: folder.appendingPathComponent("unused.wav"), duration: 3),
                                               language: "en", folder: folder) { _, _ in }
                let resumedCalls = await diarizer.calls
                XCTAssertEqual(resumedCalls, 2)
            }
        }
    }

    func testMacOS15DetectsSpeakersAndReusesDiarizationCheckpoints() async throws {
        let folder = try fixture(includeASRSpeakers: false)
        let diarizer = RecordingDiarizer()
        var transcriber = WindowedTranscriber(engine: UnusedEngine(), diarizer: diarizer,
            diarizationSupport: .init(macOSVersion: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
        transcriber.windowLength = 2
        transcriber.overlap = 1
        let audio = AudioAsset(url: folder.appendingPathComponent("unused.wav"), duration: 3)
        let result = try await transcriber.run(audio, language: "en", folder: folder) { _, _ in }
        XCTAssertEqual(result.embeddings.count, 2)
        XCTAssertEqual(Set(result.turns.map(\.speaker)).count, 2)
        let cached = try await transcriber.run(audio, language: "en", folder: folder) { _, _ in }
        let calls = await diarizer.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(cached.turns, result.turns)
        XCTAssertEqual(cached.embeddings, result.embeddings)
    }

    private func fixture(includeASRSpeakers: Bool = true) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<2 {
            // Window files and ASR results are already checkpointed: these tests need no model or audio hardware.
            try Data().write(to: folder.appendingPathComponent("window-\(index).wav"))
            let label = "remote-\(index)"
            var word = Word(text: index == 0 ? "hello" : "again", start: index == 0 ? 0.2 : 0.7, end: index == 0 ? 0.5 : 1)
            word.overlap = true
            let raw = RawTranscript(language: "en", words: [RawWord(word, speaker: includeASRSpeakers ? label : nil)],
                turns: includeASRSpeakers ? [SpeakerTurn(speaker: label, start: 0, end: 2)] : [],
                // Distinct cached voices would otherwise stitch into S1 and S2.
                embeddings: includeASRSpeakers ? [label: index == 0 ? [1, 0] : [0, 1]] : [:])
            try JSONEncoder().encode(raw).write(to: folder.appendingPathComponent("asr-\(index).json"))
        }
        return folder
    }
}

private struct UnusedEngine: Engine {
    let id = "unused"
    func capabilities() async throws -> EngineCapabilities { .init(wordTimestamps: true, diarization: false, embeddings: false) }
    func transcribe(_ audio: AudioAsset, options: TranscribeOptions, progress: @Sendable @escaping (Double) -> Void) async throws -> RawTranscript {
        XCTFail("ASR checkpoints should be reused")
        throw EngineError.invalidResult
    }
}

private actor RecordingDiarizer: Diarizing {
    var calls = 0
    func diarize(_ audio: AudioAsset) async throws -> RawTranscript {
        calls += 1
        return RawTranscript(language: "", words: [], turns: [SpeakerTurn(speaker: "A", start: 0, end: 1), SpeakerTurn(speaker: "B", start: 1, end: 2)],
                             embeddings: ["A": [1, 0], "B": [0, 1]])
    }
}
