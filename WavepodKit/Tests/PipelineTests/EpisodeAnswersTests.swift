import Foundation
import Library
import LLM
import XCTest

final class EpisodeAnswersTests: XCTestCase {
    func testCitationCannotChangeOneCriticalWordInsideAnOtherwiseMatchingQuote() {
        let source = Transcript(language: "en", segments: [Segment(id: 0, speaker: SpeakerID("S1"), words: [
            Word(text: "The final decision is to open in October with a budget of sixty thousand euros.", start: 10, end: 20)])])
        XCTAssertFalse(CitationValidator.validates(.init(claim: "Budget", quote: "The final decision is to open in October with a budget of forty thousand euros", start: 10), transcript: source))
        XCTAssertTrue(CitationValidator.validates(.init(claim: "Budget", quote: "OCTOBER, with a budget of sixty thousand euros!", start: 10), transcript: source))
    }
    func testFourHourTranscriptIncludesBeginningMiddleAndEndWithoutSearchMatches() async throws {
        let segments = (0..<480).map { index in
            Segment(id: index, speaker: SpeakerID("S1"), words: [Word(
                text: "Section \(index): " + String(repeating: "The group discussed unrelated practical details about their work. ", count: 12),
                start: Double(index * 30), end: Double(index * 30 + 29))])
        }
        let transcript = Transcript(language: "en", segments: segments)
        let generator = CoverageGenerator()
        let history = [ChatMessage(role: .user, text: "Tell me about the revised launch plan.", date: .now),
                       ChatMessage(role: .assistant, text: "They considered several launch dates.", date: .now)]
        let result = try await EpisodeAnswers(generator: generator).answer(question: "How did it change?", language: "Auto", history: history, transcript: transcript)
        let reviewed = await generator.reviewed
        XCTAssertEqual(reviewed, Set(0..<480), "Every section, including the last minutes, must be supplied")
        let prompts = await generator.prompts
        XCTAssertTrue(prompts.allSatisfy { $0.contains("revised launch plan") && $0.contains("How did it change?") })
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy { CitationValidator.validates($0, transcript: transcript) })
    }

    func testSynthesisPreservesEvidenceAtBothEndsAndCannotTurnItIntoNotFound() async throws {
        let a = Segment(id: 0, speaker: SpeakerID("S1"), words: [Word(text: "Opening is in June.", start: 0, end: 1)])
        let b = Segment(id: 1, speaker: SpeakerID("S1"), words: [Word(text: String(repeating: "Filler discussion. ", count: 180), start: 6000, end: 6001)])
        let c = Segment(id: 2, speaker: SpeakerID("S1"), words: [Word(text: "Opening moved to October.", start: 14_370, end: 14_371)])
        let transcript = Transcript(language: "en", segments: [a, b, c])
        let generator = ChangesGenerator()
        let claims = try await EpisodeAnswers(generator: generator, contextLimit: 2000).answer(question: "How did the opening date change?", language: "English", transcript: transcript)
        XCTAssertEqual(Set(claims.map(\.start)), [0, 14_370])
        XCTAssertTrue(claims.allSatisfy { CitationValidator.validates($0, transcript: transcript) })
    }

    func testNotFoundRequiresReadingEveryChunkAndInvalidOutputIsAnError() async throws {
        let transcript = Transcript(language: "en", segments: (0..<30).map {
            Segment(id: $0, speaker: SpeakerID("S1"), words: [Word(text: String(repeating: "Source words. ", count: 100), start: Double($0 * 480), end: Double($0 * 480 + 10))])
        })
        let generator = EmptyGenerator()
        let result = try await EpisodeAnswers(generator: generator, contextLimit: 2000).answer(question: "Who won?", language: "en", transcript: transcript)
        let calls = await generator.calls
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(calls, ContextChunks.make(transcript, limit: 2000).count)
        do {
            _ = try await EpisodeAnswers(generator: BrokenGenerator()).answer(question: "Who won?", language: "en", transcript: transcript)
            XCTFail("Malformed generation must not become a false absence claim")
        } catch GroundedAnswerError.invalidCitations {}
    }

    func testCannotCiteAnUnseenPassageEvenIfItExistsElsewhereInTheTranscript() async throws {
        let source = Transcript(language: "en", segments: [
            Segment(id: 0, speaker: SpeakerID("S1"), words: [Word(text: "Unrelated source.", start: 0, end: 1)]),
            Segment(id: 1, speaker: SpeakerID("S1"), words: [Word(text: "Opening moved to October.", start: 14_370, end: 14_371)])])
        let generator = FixedGenerator(text: "[{\"claim\":\"Changed\",\"quote\":\"Opening moved to October\",\"start\":14370}]")
        do {
            _ = try await GroundedAnswers(generator: generator).answer(instruction: "Answer", context: [source.segments[0]], transcript: source)
            XCTFail("Source validation must be scoped to the evidence actually supplied")
        } catch GroundedAnswerError.invalidCitations {}
    }

    func testCancellationDoesNotContinueReadingTheEpisode() async throws {
        let transcript = Transcript(language: "en", segments: [Segment(id: 0, speaker: SpeakerID("S1"), words: [Word(text: "Source words", start: 0, end: 1)])])
        let generator = EmptyGenerator()
        let task = Task {
            try Task.checkCancellation()
            return try await EpisodeAnswers(generator: generator).answer(question: "Explain", language: "en", transcript: transcript)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
    }
}

private actor CoverageGenerator: TextGenerating {
    var reviewed = Set<Int>()
    var prompts: [String] = []
    func generate(_ prompt: String) async throws -> String {
        prompts.append(prompt)
        if prompt.contains("<findings>") { return "[]" } // Exercise non-shrinking synthesis fallback.
        let regex = try NSRegularExpression(pattern: "Section ([0-9]+):")
        let matches = regex.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt))
        let ids = matches.compactMap { Range($0.range(at: 1), in: prompt).flatMap { Int(prompt[$0]) } }
        reviewed.formUnion(ids)
        guard let id = ids.first else { return "[]" }
        let claim = CitedClaim(claim: "Section \(id) covered practical details.", quote: "Section \(id)", start: Double(id * 30))
        return String(decoding: try JSONEncoder().encode([claim]), as: UTF8.self)
    }
}
private struct ChangesGenerator: TextGenerating {
    func generate(_ prompt: String) async throws -> String {
        if prompt.contains("<findings>") { return "[]" }
        var claims: [CitedClaim] = []
        if prompt.contains("Opening is in June.") { claims.append(.init(claim: "Initially June.", quote: "Opening is in June", start: 0)) }
        if prompt.contains("Opening moved to October.") { claims.append(.init(claim: "Later October.", quote: "Opening moved to October", start: 14_370)) }
        return String(decoding: try JSONEncoder().encode(claims), as: UTF8.self)
    }
}
private actor EmptyGenerator: TextGenerating {
    var calls = 0
    func generate(_ prompt: String) async throws -> String { calls += 1; return "[]" }
}
private struct BrokenGenerator: TextGenerating { func generate(_ prompt: String) async throws -> String { "not JSON" } }
private struct FixedGenerator: TextGenerating { let text: String; func generate(_ prompt: String) async throws -> String { text } }
