import Foundation
import Library
import LLM
import XCTest

final class ParallelPartsTests: XCTestCase {
    private func transcript(parts: Int) -> Transcript {
        Transcript(language: "en", segments: (0..<parts).map { index in
            Segment(id: index, speaker: SpeakerID("S1"), words: [Word(
                text: "Part \(index) says the launch moves. " + String(repeating: "Filler words here. ", count: 100),
                start: Double(index * 600), end: Double(index * 600 + 10))])
        })
    }

    func testPlanSummaryReadsPartsAtTheSameTimeAndKeepsEveryPart() async throws {
        let source = transcript(parts: 9)
        let generator = ParallelGenerator(width: 4)
        let claims = try await EpisodeSummaryStyle.notes(source, generator: generator, contextLimit: 2000)
        let parts = ContextChunks.make(source, limit: 2000).count
        let (calls, peak) = await (generator.calls, generator.peak)
        XCTAssertEqual(calls, parts, "Every part is read exactly once")
        XCTAssertEqual(peak, 4, "No more than four requests at a time, and four when there are enough parts")
        XCTAssertEqual(Set(claims.map(\.start)), Set((0..<9).map { Double($0 * 600) }))
    }

    func testLocalSummaryReadsOnePartAtATime() async throws {
        let generator = ParallelGenerator(width: 1)
        _ = try await EpisodeSummaryStyle.notes(transcript(parts: 5), generator: generator, contextLimit: 2000)
        let peak = await generator.peak
        XCTAssertEqual(peak, 1)
    }

    func testSummaryKeepsValidClaimsWithoutAskingAgain() async throws {
        let generator = ParallelGenerator(width: 1, addInvalidClaim: true)
        let source = transcript(parts: 3)
        let claims = try await EpisodeSummaryStyle.notes(source, generator: generator, contextLimit: 2000)
        let calls = await generator.calls
        XCTAssertEqual(calls, ContextChunks.make(source, limit: 2000).count, "One bad quote does not reread the part")
        XCTAssertEqual(claims.count, 3)
        XCTAssertTrue(claims.allSatisfy { CitationValidator.validates($0, transcript: source) })
    }

    func testAskOnAPlanReadsPartsAtTheSameTimeAndKeepsTheirOrder() async throws {
        let source = transcript(parts: 9)
        let generator = ParallelGenerator(width: 4)
        let claims = try await EpisodeAnswers(generator: generator, contextLimit: 2000).answer(question: "When does the launch move?", language: "en", transcript: source)
        let peak = await generator.peak
        XCTAssertEqual(peak, 4)
        XCTAssertFalse(claims.isEmpty)
        XCTAssertTrue(claims.allSatisfy { CitationValidator.validates($0, transcript: source) })
        XCTAssertEqual(claims.map(\.start), claims.map(\.start).sorted(), "Earlier parts finish last, and their claims still come first")
    }

    func testParallelResultsKeepItemOrderWhenLaterItemsFinishFirst() async throws {
        let order = try await ParallelGenerator(width: 4).forEach(Array(0..<9)) { offset, item in
            try await Task.sleep(for: .milliseconds(10 * (9 - item)))
            return offset
        }
        XCTAssertEqual(order, Array(0..<9))
    }
}

/// Cites the first "Part N says the launch moves" in each prompt, and records how many requests overlap.
private actor ParallelGenerator: TextGenerating {
    nonisolated let parallelRequests: Int
    let addInvalidClaim: Bool
    private(set) var calls = 0, running = 0, peak = 0
    init(width: Int, addInvalidClaim: Bool = false) { parallelRequests = width; self.addInvalidClaim = addInvalidClaim }
    func generate(_ prompt: String) async throws -> String {
        calls += 1; running += 1; peak = max(peak, running)
        defer { running -= 1 }
        let source = prompt.components(separatedBy: "<transcript>").last ?? ""
        // Earlier parts answer last, so results that came back in finishing order would be reversed.
        let first = source.range(of: #"Part ([0-9]+)"#, options: .regularExpression).flatMap { Int(source[$0].dropFirst(5)) } ?? 0
        try await Task.sleep(for: .milliseconds(10 * max(1, 12 - first)))
        let pattern = try NSRegularExpression(pattern: #"\[([0-9.]+)\] (Part [0-9]+ says the launch moves)"#)
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var items = matches.map { match -> [String: Any] in
            let start = Double((source as NSString).substring(with: match.range(at: 1)))!
            return ["claim": "The launch moves.", "quote": (source as NSString).substring(with: match.range(at: 2)), "start": start]
        }
        if addInvalidClaim, let first = items.first { items.append(["claim": "Invented.", "quote": "words nobody said", "start": first["start"]!]) }
        return String(decoding: try JSONSerialization.data(withJSONObject: items), as: UTF8.self)
    }
}
