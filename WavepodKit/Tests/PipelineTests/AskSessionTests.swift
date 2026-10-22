import Foundation
import Library
import LLM
import XCTest

final class AskSessionTests: XCTestCase {
    private struct Model: AnswerGenerating {
        let generator: any TextGenerating
        func withGenerator<T: Sendable>(_ choice: AnswerChoice, _ body: @Sendable (any TextGenerating, Int) async throws -> T) async throws -> T {
            try await body(generator, 9000)
        }
    }
    private struct Empty: TextGenerating { func generate(_ prompt: String) async throws -> String { "[]" } }
    private struct Slow: TextGenerating {
        func generate(_ prompt: String) async throws -> String { try await Task.sleep(for: .seconds(30)); return "[]" }
    }

    private func store() throws -> LibraryStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        let store = try LibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let words = [Word(text: "Hello", start: 0, end: 1), Word(text: "there", start: 1, end: 2)]
        try store.save(EpisodeRecord(episode: Episode(id: "ep", showName: "Show", title: "Example", pubDate: .now, duration: 2,
                                                      descriptionHTML: "", sourceName: "RSS", sourceURL: nil, enclosureURL: nil, artworkHue: 0),
                                     transcript: Transcript(language: "en", segments: [Segment(id: 0, speaker: SpeakerID("S1"), words: words)])))
        return store
    }

    func testTheQuestionAndItsAnswerAreSavedToTheEpisode() async throws {
        let store = try store()
        let answer = await AskSession(store: store, answers: Model(generator: Empty())).ask("  What?  ", episodeID: "ep", choice: AnswerChoice())
        XCTAssertEqual(answer?.text, AskSession.notFound)
        XCTAssertEqual(try store.episode("ep")?.chat.map(\.text), ["What?", AskSession.notFound])
        XCTAssertEqual(try store.episode("ep")?.chat.map(\.role), [.user, .assistant])
    }

    func testAQuestionAboutAMissingEpisodeSavesNothing() async throws {
        let store = try store()
        try store.delete("ep")
        let answer = await AskSession(store: store, answers: Model(generator: Empty())).ask("What?", episodeID: "ep", choice: AnswerChoice())
        XCTAssertNil(answer)
        XCTAssertNil(try store.episode("ep"))
    }

    func testStopSavesThatItStoppedAndNoPartialAnswer() async throws {
        let store = try store()
        let session = AskSession(store: store, answers: Model(generator: Slow()))
        let task = Task { await session.ask("What?", episodeID: "ep", choice: AnswerChoice()) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let answer = await task.value
        XCTAssertEqual(answer?.text, AskSession.stopped)
        XCTAssertEqual(try store.episode("ep")?.chat.map(\.text), ["What?", AskSession.stopped])
    }
}
