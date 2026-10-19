import Engine
import Foundation
import Networking
import Library
import Pipeline
import Resolver
import XCTest

private final class Fixtures: @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    var handler: @Sendable (URLRequest) -> (Int, [String: String], Data) = { _ in (200, [:], Data()) }
    func respond(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.lock(); requests.append(request); let closure = handler; lock.unlock()
        return closure(request)
    }
    func configure(_ handler: @escaping @Sendable (URLRequest) -> (Int, [String: String], Data)) {
        lock.lock(); requests = []; self.handler = handler; lock.unlock()
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = Fixtures()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, data) = Self.fixtures.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class NetworkTests: XCTestCase {
    func client() -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return HTTPClient(configuration: configuration)
    }
    func testScriberrRecordedEnvelopeAndWordSpeakers() throws {
        // Response shape from Scriberr a353078 GetTranscript, with an invented WhisperX utterance.
        let fixture = Data(#"{"job_id":"fixture","available":true,"status":"completed","transcript":{"language":"en","segments":[{"start":1,"end":2,"text":"Hello","words":[{"word":"Hello","start":1,"end":2,"score":0.9,"speaker":"SPEAKER_00"}]}]}}"#.utf8)
        let transcript = try ScriberrEngine.parse(fixture, language: "en")
        XCTAssertEqual(transcript.words.first?.speaker, "SPEAKER_00")
        XCTAssertEqual(transcript.words.first?.word.confidence, 0.9)
        XCTAssertEqual(transcript.turns.first?.start, 1)
        XCTAssertThrowsError(try ScriberrEngine.parse(Data(#"{"available":false,"transcript":null}"#.utf8), language: "en"))
    }
    func testPublishedTranscriptBypassesAudioAndNativeInference() async throws {
        FixtureProtocol.fixtures.configure { _ in
            (200, ["Content-Type": "text/vtt"], Data("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n<v Alex>Hello from the publisher.</v>\n".utf8))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let queue = try JobQueue(store: store, directory: folder.appendingPathComponent("jobs"), client: client())
        let episode = ResolvedEpisode(title: "Publisher transcript", transcripts: [TranscriptLink(url: URL(string: "https://feed.example/transcript.vtt")!, type: "text/vtt")])
        try await queue.enqueue(episode)
        for _ in 0..<100 {
            if await queue.snapshot().first?.state == .completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let jobs = await queue.snapshot()
        XCTAssertEqual(jobs.first?.state, .completed, jobs.first?.error ?? "")
        let saved = try store.episodes().first
        XCTAssertEqual(saved?.transcript.segments.first?.start, 1)
        XCTAssertEqual(saved?.speakers[SpeakerID("Alex")]?.name, "Alex")
        XCTAssertEqual(FixtureProtocol.fixtures.count(), 1)
        await queue.shutdown()
    }
    func testUnapprovedHostIsRejectedBeforeSending() async throws {
        FixtureProtocol.fixtures.configure { _ in (200, [:], Data()) }
        do {
            _ = try await client().data(URLRequest(url: URL(string: "https://unapproved.example/audio")!), purpose: "audio")
            XCTFail("Unapproved request was sent")
        } catch is NetworkError {}
        XCTAssertEqual(FixtureProtocol.fixtures.count(), 0)
    }
    func testScriberrRedirectCannotSendAudioOrCredentialsToPublicHost() async throws {
        FixtureProtocol.fixtures.configure { _ in (302, ["Location": "https://public.example/stolen"], Data()) }
        let engine = try ScriberrEngine(base: URL(string: "http://127.0.0.1:8080")!, client: client())
        do { _ = try await engine.capabilities(); XCTFail("Public redirect was accepted") } catch is NetworkError {}
        XCTAssertEqual(FixtureProtocol.fixtures.count(), 1)
    }
    func testRangeDownloadResumesPartialFileAndAtomicallyCompletes() async throws {
        FixtureProtocol.fixtures.configure { request in
            if request.httpMethod == "HEAD" { return (200, ["ETag": "stable", "Content-Length": "11"], Data()) }
            guard request.value(forHTTPHeaderField: "Range") == "bytes=6-",
                  request.value(forHTTPHeaderField: "If-Range") == "stable" else { return (400, [:], Data()) }
            return (206, ["Content-Range": "bytes 6-10/11", "Content-Length": "5"], Data("world".utf8))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("audio")
        try Data("hello ".utf8).write(to: destination.appendingPathExtension("partial"))
        try "stable".write(to: destination.appendingPathExtension("etag"), atomically: true, encoding: .utf8)
        let client = client(), url = URL(string: "https://feed.example/audio")!
        try await client.allow(url)
        try await client.download(url, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "hello world")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }
    func testChangedResourceRestartsInsteadOfAppendingToOldPartial() async throws {
        FixtureProtocol.fixtures.configure { _ in (200, ["ETag": "new", "Content-Length": "3"], Data("new".utf8)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("audio")
        try Data("stale".utf8).write(to: destination.appendingPathExtension("partial"))
        try "old".write(to: destination.appendingPathExtension("etag"), atomically: true, encoding: .utf8)
        let client = client(), url = URL(string: "https://feed.example/audio")!
        try await client.allow(url)
        try await client.download(url, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
    }
}
