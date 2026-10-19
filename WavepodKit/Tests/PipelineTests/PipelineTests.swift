import AVFoundation
import Engine
import Foundation
import Library
import LLM
import Networking
import Pipeline
import Resolver
import Speakers
import XCTest

final class PipelineTests: XCTestCase {
    func temporary() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    func transcript() -> Transcript {
        Transcript(language: "en", segments: [Segment(id: 0, speaker: SpeakerID("S1"), words: [
            Word(text: "Welcome", start: 10, end: 10.5), Word(text: "to", start: 10.5, end: 11),
            Word(text: "our", start: 11, end: 11.5), Word(text: "podcast", start: 11.5, end: 12)
        ])])
    }
    func record() -> EpisodeRecord {
        EpisodeRecord(episode: Episode(id: "ep", showName: "Show", title: "Example", pubDate: .now, duration: 12,
                                       descriptionHTML: "", sourceName: "RSS", sourceURL: nil, enclosureURL: nil, artworkHue: 0), transcript: transcript())
    }
    func testAlignmentChoosesShortestOverlapAndBreaksAtPauses() throws {
        let raw = RawTranscript(language: "en", words: [
            RawWord(Word(text: "one", start: 0, end: 1)), RawWord(Word(text: "two", start: 1, end: 2)),
            RawWord(Word(text: "three", start: 4, end: 5)), RawWord(Word(text: "four", start: 7, end: 8))
        ], turns: [SpeakerTurn(speaker: "host", start: 0, end: 6), SpeakerTurn(speaker: "guest", start: 1, end: 2)])
        let result = try WordAlignment.render(raw)
        XCTAssertEqual(result.segments.map(\.speaker.rawValue), ["host", "guest", "host", "host"])
        XCTAssertTrue(result.segments[1].words[0].overlap)
        XCTAssertFalse(result.segments[0].words[0].overlap)
        XCTAssertEqual(result.segments.last?.words[0].text, "four")
        XCTAssertThrowsError(try WordAlignment.render(RawTranscript(language: "en", words: [RawWord(Word(text: "bad", start: .nan, end: 1))])))
    }
    func testWindowStitchDoesNotDuplicateOverlapAndUsesVoiceIdentity() {
        var combined = RawTranscript(language: "en", words: [])
        let first = RawTranscript(language: "en", words: [RawWord(Word(text: "keep", start: 1794, end: 1795), speaker: "A"), RawWord(Word(text: "overlap", start: 1796, end: 1797), speaker: "A")], turns: [SpeakerTurn(speaker: "A", start: 0, end: 1800)], embeddings: ["A": [1, 0]])
        WindowStitcher.append(first, start: 0, keepFrom: 0, keepUntil: 1795, to: &combined)
        let second = RawTranscript(language: "en", words: [RawWord(Word(text: "overlap", start: 6, end: 7), speaker: "B")], turns: [SpeakerTurn(speaker: "B", start: 0, end: 20)], embeddings: ["B": [1, 0]])
        WindowStitcher.append(second, start: 1790, keepFrom: 1795, keepUntil: 1810, to: &combined)
        XCTAssertEqual(combined.words.map(\.word.text), ["keep", "overlap"])
        XCTAssertEqual(Set(combined.turns.map(\.speaker)).count, 1)
    }
    func testCitationRejectsWrongTimeNoncontiguousAndInventedWords() {
        let source = transcript()
        XCTAssertTrue(CitationValidator.validates(CitedClaim(claim: "Greeting", quote: "Welcome to our podcast!", start: 10), transcript: source))
        XCTAssertFalse(CitationValidator.validates(CitedClaim(claim: "Greeting", quote: "Welcome to our podcast", start: 30), transcript: source))
        XCTAssertFalse(CitationValidator.validates(CitedClaim(claim: "Greeting", quote: "Welcome podcast", start: 10), transcript: source))
        let cue = Transcript(language: "en", segments: [Segment(id: 0, speaker: SpeakerID("S1"), words: [Word(text: "Welcome to our podcast", start: 10, end: 12)])])
        XCTAssertTrue(CitationValidator.validates(CitedClaim(claim: "Greeting", quote: "our podcast", start: 11), transcript: cue))
        XCTAssertFalse(CitationValidator.validates(CitedClaim(claim: "Invented", quote: "They announced a merger", start: 10), transcript: source))
        // A quote from the middle of a segment may cite the segment's start; the located time is the quote's own.
        XCTAssertEqual(CitationValidator.locate(CitedClaim(claim: "Name", quote: "our podcast", start: 9), transcript: source), 11)
        XCTAssertNil(CitationValidator.locate(CitedClaim(claim: "Name", quote: "our podcast", start: 14), transcript: source))
    }
    func testInvalidCitationsAreAnErrorInsteadOfFalseNotFound() async throws {
        let generator = ScriptedGenerator(responses: ["garbage", "[{\"claim\":\"Made up\",\"quote\":\"aliens arrived\",\"start\":10}]"])
        do {
            _ = try await GroundedAnswers(generator: generator).answer(instruction: "Summarize", context: transcript().segments, transcript: transcript())
            XCTFail("Invalid model output must not be reported as absent evidence")
        } catch GroundedAnswerError.invalidCitations {}
        let calls = await generator.calls
        XCTAssertEqual(calls, 2)
    }
    func testExplicitEmptyAnswerIsAcceptedWithoutRetry() async throws {
        let generator = ScriptedGenerator(responses: ["[]"])
        let claims = try await GroundedAnswers(generator: generator).answer(instruction: "Who won the match?", context: transcript().segments, transcript: transcript())
        XCTAssertTrue(claims.isEmpty)
        let calls = await generator.calls
        XCTAssertEqual(calls, 1)
    }
    func testVoiceProfilesAreRestrictedToShowAndRejectAmbiguousMatches() {
        let a = VoiceProfile(showID: "show-a", name: "Alex", embedding: [1, 0])
        XCTAssertEqual(SpeakerIdentity.match([1, 0], showID: "show-a", profiles: [a])?.name, "Alex")
        XCTAssertNil(SpeakerIdentity.match([1, 0], showID: "show-b", profiles: [a]))
        let b = VoiceProfile(showID: "show-a", name: "Blair", embedding: [0.99, 0.01])
        XCTAssertNil(SpeakerIdentity.match([1, 0], showID: "show-a", profiles: [a, b]))
        XCTAssertNil(VectorMath.cosine([0, 0], [1, 0]))
        XCTAssertNil(VectorMath.cosine([.nan], [1]))
    }
    func testDatabaseReopensFTSAndPreservesVectorsAcrossSpeakerRename() throws {
        let url = try temporary().appendingPathComponent("library.sqlite")
        let store = try LibraryStore(url: url)
        var episode = record()
        try store.save(episode)
        try store.setVector([1, 0], model: "test", episodeID: "ep", segmentID: 0)
        episode.speakers[SpeakerID("S1")] = Speaker(id: SpeakerID("S1"), name: "Alex", isConfirmed: true, colorIndex: 0)
        try store.save(episode)
        let reopened = try LibraryStore(url: url)
        XCTAssertEqual(try reopened.items().first?.episode.title, "Example")
        XCTAssertEqual(try reopened.search("podcast").first?.start, 10)
        XCTAssertEqual(try reopened.semanticSearch([1, 0], model: "test").count, 1)
        XCTAssertEqual(try reopened.episode("ep")?.speakers[SpeakerID("S1")]?.name, "Alex")
        XCTAssertTrue(try reopened.search("\" OR * --").isEmpty)
        try reopened.delete("ep")
        XCTAssertTrue(try reopened.search("podcast").isEmpty)
        XCTAssertTrue(try reopened.semanticSearch([1, 0], model: "test").isEmpty)
    }
    func testLANPolicyDoesNotAcceptPublicOrMalformedHosts() {
        for host in ["localhost", "127.0.0.1", "10.0.0.4", "172.16.0.1", "192.168.1.9", "fd00::1", "studio.local"] { XCTAssertTrue(HTTPClient.isPrivateHost(host), host) }
        for host in ["example.com", "8.8.8.8", "172.32.0.1", "192.169.0.1", "localhost.example.com", "fdgarbage::oops", "10.0.0.999", "10.nope.0.0.1", "10..0.0.1", "010.0.0.1", "+10.0.0.1"] { XCTAssertFalse(HTTPClient.isPrivateHost(host), host) }
    }
    func testAppNetworkCallsAreCentralized() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        for case let file as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" && !file.path.contains("/Networking/") {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(source.range(of: #"\bURLSession\s*[.(]"#, options: .regularExpression), file.path)
        }
    }
    func testDecoderKeepsEntireAudioAndWindowSlices() throws {
        let directory = try temporary()
        let source = directory.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
            buffer.frameLength = 88200
            for i in 0..<88200 { buffer.floatChannelData![0][i] = 0.1; buffer.floatChannelData![1][i] = 0.2 }
            try file.write(from: buffer)
        }
        let audio = try AudioDecoder.decode(source, to: directory.appendingPathComponent("mono.wav"))
        XCTAssertEqual(audio.duration, 2, accuracy: 0.005)
        let slice = try AudioDecoder.slice(audio, start: 0.5, end: 1.5, to: directory.appendingPathComponent("slice.wav"))
        XCTAssertEqual(slice.duration, 1, accuracy: 0.001)
    }
    func testNoSpeechMarkerDoesNotTriggerRealignment() async throws {
        let directory = try temporary()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let source = directory.appendingPathComponent("silence.wav")
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            try file.write(from: buffer)
        }
        let audio = try AudioDecoder.decode(source, to: directory.appendingPathComponent("mono.wav"))
        let aligner = CountingEngine()
        let transcriber = WindowedTranscriber(engine: SilentEngine(), diarizer: SilentEngine(), aligner: aligner)
        let raw = try await transcriber.run(audio, language: "en", folder: directory) { _, _ in }
        XCTAssertEqual(raw.words.map(\.word.text), ["[No speech recognized]"])
        let calls = await aligner.calls
        XCTAssertEqual(calls, 0, "The pipeline's own untimed marker must not cost a second transcription")
    }
    func testQueueResumesASRCheckpointAfterDiarizerFailure() async throws {
        let directory = try temporary()
        let source = directory.appendingPathComponent("input.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            for i in 0..<16000 { buffer.floatChannelData![0][i] = 0.1 }
            try file.write(from: buffer)
        }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let engine = CountingEngine()
        let diarizer = FailingDiarizer()
        let queue = try JobQueue(store: store, directory: directory.appendingPathComponent("jobs"), client: HTTPClient(), engine: engine, diarizer: diarizer, inferenceGate: InferenceGate())
        let episode = ResolvedEpisode(title: "Original audio", enclosureURL: source, language: "en", source: .file)
        let id = try await queue.enqueue(episode)
        for _ in 0..<200 {
            if await queue.snapshot().first?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let failed = await queue.snapshot()
        XCTAssertEqual(failed.first?.state, .failed)
        await queue.shutdown()
        let recovered = try JobQueue(store: store, directory: directory.appendingPathComponent("jobs"), client: HTTPClient(), engine: engine, diarizer: diarizer, inferenceGate: InferenceGate())
        try await recovered.resume(id)
        for _ in 0..<200 {
            if await recovered.snapshot().first?.state == .completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let jobs = await recovered.snapshot()
        XCTAssertEqual(jobs.first?.state, .completed, jobs.first?.error ?? "")
        let calls = await engine.calls
        XCTAssertEqual(calls, 1, "ASR must be recovered from disk rather than repeated")
        XCTAssertEqual(try store.episodes().first?.transcript.segments.first?.words.first?.text, "hello")
        await recovered.shutdown()
    }
    func testCancelledInferenceWaiterDoesNotBlockTheNextRequest() async throws {
        let gate = InferenceGate()
        let first = UUID(), second = UUID(), third = UUID()
        try await gate.acquire(first)
        let cancelled = Task { try await gate.acquire(second) }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled waiter acquired the gate") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        await gate.release(first)
        try await gate.acquire(third)
        await gate.release(third)
    }

}


private actor ScriptedGenerator: TextGenerating {
    var responses: [String]
    var calls = 0
    init(responses: [String]) { self.responses = responses }
    func generate(_ prompt: String) async throws -> String { calls += 1; return responses.removeFirst() }
}

private actor CountingEngine: Engine {
    nonisolated let id = "test"
    var calls = 0
    func capabilities() async throws -> EngineCapabilities { EngineCapabilities(wordTimestamps: true, diarization: false, embeddings: false) }
    func transcribe(_ audio: AudioAsset, options: TranscribeOptions, progress: @Sendable @escaping (Double) -> Void) async throws -> RawTranscript {
        calls += 1
        return RawTranscript(language: "en", words: [RawWord(Word(text: "hello", start: 0, end: 0.5))])
    }
}
private struct SilentEngine: Engine, Diarizing {
    let id = "silent"
    func capabilities() async throws -> EngineCapabilities { EngineCapabilities(wordTimestamps: true, diarization: true, embeddings: false) }
    func transcribe(_ audio: AudioAsset, options: TranscribeOptions, progress: @Sendable @escaping (Double) -> Void) async throws -> RawTranscript {
        RawTranscript(language: "en", words: [RawWord(Word(text: "[No speech recognized]", start: 0, end: audio.duration, confidence: 0))])
    }
    func diarize(_ audio: AudioAsset) async throws -> RawTranscript { RawTranscript(language: "", words: []) }
}
private actor FailingDiarizer: Diarizing {
    var calls = 0
    func diarize(_ audio: AudioAsset) async throws -> RawTranscript {
        calls += 1
        if calls == 1 { throw EngineError.remoteFailure("Simulated helper crash") }
        return RawTranscript(language: "en", words: [], turns: [SpeakerTurn(speaker: "S1", start: 0, end: 1)], embeddings: ["S1": [1, 0]])
    }
}

final class LocalAISmokeTests: XCTestCase {
    func testRealLocalGenerationAndMultilingualEmbeddings() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WAVEPOD_AI_MODELS"] else {
            throw XCTSkip("Set WAVEPOD_AI_MODELS for the opt-in local AI integration run.")
        }
        let root = URL(fileURLWithPath: directory)
        if ProcessInfo.processInfo.environment["WAVEPOD_INSTALL_AI"] == "1" {
            let installer = ModelInstaller(client: HTTPClient(), root: root)
            try await installer.install(.language, progress: { _ in })
            try await installer.install(.embeddings, progress: { _ in })
        }
        let source = Transcript(language: "en", segments: [Segment(id: 0, speaker: SpeakerID("S1"), words: [Word(text: "The train leaves at noon.", start: 10, end: 12)])])
        let generator = LocalGenerator(directory: root.appendingPathComponent("language"))
        let claims = try await generator.withSession { session in
            try await GroundedAnswers(generator: session).answer(instruction: "When does the train leave?", context: source.segments, transcript: source)
        }
        XCTAssertFalse(claims.isEmpty, "The real model must produce at least one valid citation")
        let embeddings = LocalEmbeddings(directory: root.appendingPathComponent("embeddings"))
        let vectors = try await embeddings.encode(["The train leaves at noon.", "El tren sale al mediodía.", "Chocolate cake recipe."])
        XCTAssertEqual(vectors.count, 3)
        XCTAssertEqual(vectors[0].count, 384)
        XCTAssertGreaterThan(VectorMath.cosine(vectors[0], vectors[1]) ?? 0, VectorMath.cosine(vectors[0], vectors[2]) ?? 1)
    }
}
