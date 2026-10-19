import Engine
import Foundation
import NativeEngine
import XCTest

final class DiarizationSupportTests: XCTestCase {
    func testCapabilitiesFollowTheOSBoundary() async throws {
        for major in [14, 15, 26] {
            let support = OfflineDiarizationSupport(macOSVersion: .init(majorVersion: major, minorVersion: 8, patchVersion: 9))
            XCTAssertEqual(support.isAvailable, major >= 15)
            XCTAssertEqual(support.explanation == nil, major >= 15)
            let engines: [any Engine] = [
                NativeEngine(models: URL(fileURLWithPath: "/nonexistent"), diarizationSupport: support),
                IsolatedEngine(diarizationSupport: support)
            ]
            for engine in engines {
                let capabilities = try await engine.capabilities()
                XCTAssertTrue(capabilities.wordTimestamps)
                XCTAssertEqual(capabilities.diarization, major >= 15)
                XCTAssertEqual(capabilities.embeddings, major >= 15)
            }
        }
    }

    func testMacOS14NeverNeedsModelsAudioOrAnXPCService() async throws {
        let support = OfflineDiarizationSupport(macOSVersion: .init(majorVersion: 14, minorVersion: 8, patchVersion: 9))
        let engines: [any Diarizing] = [
            NativeEngine(models: URL(fileURLWithPath: "/nonexistent"), diarizationSupport: support),
            IsolatedEngine(diarizationSupport: support)
        ]
        for engine in engines {
            let result = try await engine.diarize(AudioAsset(url: URL(fileURLWithPath: "/nonexistent.wav"), duration: 42))
            XCTAssertEqual(result.turns, [SpeakerTurn(speaker: "S1", start: 0, end: 42)])
            XCTAssertTrue(result.embeddings.isEmpty)
        }
    }

    func testMacOS15StillLoadsNativeDiarizationModels() async throws {
        let support = OfflineDiarizationSupport(macOSVersion: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        let engine = NativeEngine(models: URL(fileURLWithPath: "/nonexistent"), diarizationSupport: support)
        do {
            _ = try await engine.diarize(AudioAsset(url: URL(fileURLWithPath: "/nonexistent.wav"), duration: 42))
            XCTFail("Supported systems must attempt real diarization")
        } catch EngineError.unavailable(let message) {
            XCTAssertTrue(message.contains("diarizer/"))
        }
    }
}
