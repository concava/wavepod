import Foundation
import Library
import LLM
import Pipeline
import Networking
import Resolver
import XCTest

actor NotesCalls {
    var chapters: [Bool] = []
    func append(_ value: Bool) { chapters.append(value) }
}
struct FakeNotes: NotesGenerating {
    let isAvailable: Bool
    let calls: NotesCalls
    var fails = false
    func notes(_ transcript: Transcript, chapters: Bool) async throws -> [CitedClaim] {
        await calls.append(chapters)
        if fails { throw CocoaError(.fileReadCorruptFile) }
        return [CitedClaim(claim: chapters ? "Chapter" : "Summary", quote: "hello", start: 1)]
    }
}

final class AutomationTests: XCTestCase {
    func record(_ id: String, date: Double = 0, feed: URL) -> EpisodeRecord {
        EpisodeRecord(episode: Episode(id: id, showName: "Show", title: id, pubDate: Date(timeIntervalSince1970: date),
                                      duration: 2, descriptionHTML: "", sourceName: "RSS", sourceURL: feed, enclosureURL: nil, artworkHue: 0),
                      transcript: Transcript(language: "en", segments: [Segment(id: 0, speaker: SpeakerID("S1"), words: [Word(text: "hello", start: 1, end: 2)])]), feedURL: feed)
    }
    func testOldSubscriptionDecodingPreservesOptInAndDefaults() throws {
        for enabled in [true, false] {
            let json = "{\"feedURL\":\"https://example.com/rss\",\"title\":\"Show\",\"autoTranscribe\":\(enabled),\"seen\":[\"old\"]}"
            let show = try JSONDecoder().decode(Subscription.self, from: Data(json.utf8))
            XCTAssertEqual(show.autoTranscribe, enabled)
            XCTAssertFalse(show.autoDownload)
            XCTAssertFalse(show.autoSummarize)
            XCTAssertNil(show.keepLatest)
            XCTAssertEqual(show.seen, ["old"])
        }
        let show = Subscription(feedURL: URL(string: "https://example.com/rss")!, title: "New")
        XCTAssertTrue(show.autoDownload && show.autoTranscribe && show.autoSummarize)
        let decoded = try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(show))
        XCTAssertTrue(decoded.autoDownload && decoded.autoTranscribe && decoded.autoSummarize)
    }
    func testRetentionDeletesOnlyOldAudioForThisShow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let feed = URL(string: "https://example.com/rss")!
        for index in 0..<4 {
            var item = record("\(index)", date: Double(index), feed: index == 3 ? URL(string: "https://other.example/rss")! : feed)
            item.audioURL = folder.appendingPathComponent("\(index).mp3")
            item.summary = EpisodeSummary(overview: "Saved", points: [], quotes: [])
            try Data("audio".utf8).write(to: item.audioURL!)
            try store.save(item)
        }
        var show = Subscription(feedURL: feed, title: "Show")
        try AudioRetention.prune(show, store: store, directory: folder)
        XCTAssertEqual(try store.episodes().filter { $0.audioURL != nil }.count, 4)
        show.keepLatest = 1
        try AudioRetention.prune(show, store: store, directory: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("0.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("1.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("3.mp3").path))
        XCTAssertEqual(try store.episodes().count, 4)
        XCTAssertEqual(try store.episode("0")?.transcript.segments.count, 1)
        XCTAssertEqual(try store.episode("0")?.summary?.overview, "Saved")
        XCTAssertNil(try store.episode("0")?.audioURL)
        let listing = try XCTUnwrap(store.items().first(where: { $0.id == "0" }))
        XCTAssertFalse(listing.downloaded)
        XCTAssertTrue(listing.summarized)
    }
    func testRetentionDefersActiveJobsAndRemovesOnlyAudioCheckpoints() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let feed = URL(string: "https://example.com/rss")!
        let resolved = ResolvedEpisode(title: "Episode", feedURL: feed)
        var job = TranscriptionJob(episode: resolved)
        job.state = .running
        try store.put(job, kind: "job", id: job.id.uuidString)
        var item = record(JobQueue.episodeID(resolved), feed: feed)
        let checkpoint = folder.appendingPathComponent("jobs/\(job.id.uuidString)")
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        for name in ["decoded.wav", "source.mp3", "words.json"] { try Data("saved".utf8).write(to: checkpoint.appendingPathComponent(name)) }
        item.audioURL = checkpoint.appendingPathComponent("decoded.wav")
        try store.save(item)
        let show = Subscription(feedURL: feed, title: "Show", keepLatest: 0)
        try AudioRetention.prune(show, store: store, directory: folder)
        XCTAssertNotNil(try store.episode(item.id)?.audioURL)
        job.state = .completed
        try store.put(job, kind: "job", id: job.id.uuidString)
        try AudioRetention.prune(show, store: store, directory: folder)
        XCTAssertNil(try store.episode(item.id)?.audioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.appendingPathComponent("decoded.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.appendingPathComponent("source.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.appendingPathComponent("words.json").path))
        XCTAssertEqual(try store.episode(item.id)?.transcript.segments.count, 1)
    }
    func testPendingNotesSkipMissingModelThenGenerateBothOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        var item = record("episode", feed: URL(string: "https://example.com/rss")!)
        item.notesPending = true
        try store.save(item)
        let calls = NotesCalls()
        try await EpisodeNotesService(store: store, generator: FakeNotes(isAvailable: false, calls: calls)).completePending(item.id)
        let skipped = await calls.chapters
        XCTAssertEqual(skipped, [])
        XCTAssertEqual(try store.episode(item.id)?.notesPending, true)
        let service = EpisodeNotesService(store: store, generator: FakeNotes(isAvailable: true, calls: calls))
        try await service.completePending(item.id)
        try await service.completePending(item.id)
        let generated = await calls.chapters
        XCTAssertEqual(generated, [false, true])
        XCTAssertEqual(try store.episode(item.id)?.summary?.overview, "Summary")
        XCTAssertEqual(try store.episode(item.id)?.chapters.first?.title, "Chapter")
        XCTAssertEqual(try store.episode(item.id)?.notesPending, false)
    }
    func testQueueRetriesDurablePendingNotesOnlyForOptedInShows() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        for enabled in [false, true] {
            let feed = URL(string: "https://example.com/\(enabled)/rss")!
            let show = Subscription(feedURL: feed, title: "Show", autoSummarize: enabled)
            try store.put(show, kind: "subscription", id: show.id)
            var item = record("\(enabled)", feed: feed)
            item.notesPending = true
            try store.save(item)
        }
        let calls = NotesCalls()
        let queue = try JobQueue(store: store, directory: folder.appendingPathComponent("jobs"), client: HTTPClient(),
                                 notesGenerator: FakeNotes(isAvailable: true, calls: calls))
        await queue.start()
        await queue.retryPendingSummaries()
        XCTAssertEqual(try store.episode("true")?.notesPending, false)
        XCTAssertEqual(try store.episode("false")?.notesPending, true)
        let generated = await calls.chapters
        XCTAssertEqual(generated, [false, true])
        await queue.shutdown()
    }
    func testNotesFailureRemainsPending() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        var item = record("episode", feed: URL(string: "https://example.com/rss")!)
        item.notesPending = true
        try store.save(item)
        do {
            try await EpisodeNotesService(store: store, generator: FakeNotes(isAvailable: true, calls: NotesCalls(), fails: true)).completePending(item.id)
            XCTFail("Expected failure")
        } catch {}
        XCTAssertEqual(try store.episode(item.id)?.notesPending, true)
    }
}
