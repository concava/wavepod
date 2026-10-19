import Foundation
import Library
import LLM
import XCTest

final class EpisodeAnswerModelSmokeTests: XCTestCase {
    func testLocalModelCombinesEarlyAndLateEvidence() async throws {
        guard let root = ProcessInfo.processInfo.environment["WAVEPOD_AI_MODELS"] else {
            throw XCTSkip("Set WAVEPOD_AI_MODELS to run the installed local model against a multi-section episode.")
        }
        let transcript = Transcript(language: "en", segments: [
            Segment(id: 0, speaker: SpeakerID("Mara"), words: [Word(text: "Initially we planned to open the library in June with a budget of forty thousand euros.", start: 10, end: 20)]),
            Segment(id: 1, speaker: SpeakerID("Mara"), words: [Word(text: String(repeating: "They reviewed maps and schedules for the library. ", count: 500), start: 3600, end: 10_800)]),
            Segment(id: 2, speaker: SpeakerID("Mara"), words: [Word(text: "The final decision is to open in October with a budget of sixty thousand euros because renovations were delayed.", start: 14_370, end: 14_390)])])
        let generator = LocalGenerator(directory: URL(fileURLWithPath: root).appendingPathComponent("language"))
        let claims = try await generator.withSession { session in
            try await EpisodeAnswers(generator: session).answer(question: "Compare the original and final opening dates and budgets. Why did the plan change?", language: "English", transcript: transcript)
        }
        let text = claims.map(\.claim).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("june"), text)
        XCTAssertTrue(text.contains("october"), text)
        XCTAssertTrue(text.contains("forty") || text.contains("40"), text)
        XCTAssertTrue(text.contains("sixty") || text.contains("60"), text)
        XCTAssertTrue(text.contains("renovation") || text.contains("delay"), text)
        XCTAssertTrue(claims.contains { $0.start >= 14_370 })
        XCTAssertTrue(claims.contains { $0.start <= 20 })
        XCTAssertTrue(claims.allSatisfy { CitationValidator.validates($0, transcript: transcript) })
    }
}
