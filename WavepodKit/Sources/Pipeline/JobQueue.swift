import Darwin
import Engine
import Foundation
import Library
import Networking
import OSLog
import Resolver

public struct TranscriptionJob: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case queued, running, paused, failed, cancelled, completed }
    public var id: UUID
    public var episode: ResolvedEpisode
    public var state: State
    public var stage: String
    public var fraction: Double
    public var error: String?
    public var batteryPaused: Bool
    public var engineID: String
    public init(episode: ResolvedEpisode, engineID: String = "native") {
        id = UUID(); self.episode = episode; state = .queued; stage = "Waiting"; fraction = 0
        batteryPaused = false; self.engineID = engineID
    }
}

public actor JobQueue {
    private let store: LibraryStore
    private let directory: URL
    private let client: HTTPClient
    private let engine: any Engine
    private let diarizer: any Diarizing
    private let inferenceGate: InferenceGate
    private var jobs: [TranscriptionJob]
    private var worker: Task<Void, Never>?
    private var current: UUID?
    private var onBattery = false
    private var lease: Int32 = -1
    private let logger = Logger(subsystem: "app.wavepod", category: "Pipeline")
    private var activeStage: OSSignpostIntervalState?
    private let signposter = OSSignposter(subsystem: "app.wavepod", category: "Pipeline")

    public init(store: LibraryStore, directory: URL, client: HTTPClient,
                engine: any Engine = IsolatedEngine(), diarizer: any Diarizing = IsolatedEngine(), inferenceGate: InferenceGate = .shared) throws {
        self.store = store; self.directory = directory; self.client = client
        self.engine = engine; self.diarizer = diarizer; self.inferenceGate = inferenceGate
        jobs = try store.values(TranscriptionJob.self, kind: "job").map {
            var job = $0
            if job.state == .running { job.state = .queued; job.stage = "Resuming checkpoint" }
            return job
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { if lease >= 0 { flock(lease, LOCK_UN); close(lease) } }
    public func shutdown() async {
        onBattery = true
        if let id = current { try? update(id) { $0.state = .queued } }
        worker?.cancel()
        await worker?.value
        if lease >= 0 { flock(lease, LOCK_UN); close(lease); lease = -1 }
    }
    public func hasLease() -> Bool { lease >= 0 }
    public func snapshot() -> [TranscriptionJob] {
        if lease < 0, let saved = try? store.values(TranscriptionJob.self, kind: "job") { return saved }
        if let current, let saved = try? store.values(TranscriptionJob.self, kind: "job"),
           let request = saved.first(where: { $0.id == current }), request.state == .paused || request.state == .cancelled {
            if let index = jobs.firstIndex(where: { $0.id == current }) { jobs[index] = request }
            worker?.cancel()
        }
        return jobs
    }
    public func start() {
        guard worker == nil, !onBattery else { return }
        if lease < 0 {
            let descriptor = open(directory.appendingPathComponent("queue.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return }
            lease = descriptor
            // A background process may have updated the durable queue while we waited for its lease.
            if let saved = try? store.values(TranscriptionJob.self, kind: "job") {
                jobs = saved.map { var job = $0; if job.state == .running { job.state = .queued }; return job }
            }
        }
        guard let next = jobs.first(where: { $0.state == .queued }) else { return }
        current = next.id
        worker = Task { await self.process(next.id) }
    }
    @discardableResult public func enqueue(_ episode: ResolvedEpisode) throws -> UUID {
        jobs = try store.values(TranscriptionJob.self, kind: "job")
        let key = Self.episodeID(episode)
        if let old = jobs.first(where: { Self.episodeID($0.episode) == key && ![.cancelled, .failed].contains($0.state) }) { return old.id }
        let job = TranscriptionJob(episode: episode, engineID: engine.id)
        try store.put(job, kind: "job", id: job.id.uuidString)
        jobs.append(job)
        start()
        return job.id
    }
    public func pause(_ id: UUID) throws {
        try update(id) { $0.state = .paused; $0.batteryPaused = false }
        if current == id { worker?.cancel() }
    }
    public func cancel(_ id: UUID) throws {
        try update(id) { $0.state = .cancelled; $0.batteryPaused = false }
        if current == id { worker?.cancel() }
    }
    public func resume(_ id: UUID) throws {
        if lease < 0 { jobs = try store.values(TranscriptionJob.self, kind: "job") }
        guard let job = jobs.first(where: { $0.id == id }), job.state != .completed, job.state != .running else { return }
        // A different engine's raw checkpoints must never be reused.
        guard job.engineID == engine.id else { throw EngineError.unavailable("Choose the original engine to resume this job.") }
        try update(id) { $0.state = .queued; $0.error = nil; $0.batteryPaused = false }
        start()
    }
    public func setOnBattery(_ value: Bool) throws {
        onBattery = value
        if value, let current {
            try update(current) { $0.state = .paused; $0.batteryPaused = true }
            worker?.cancel()
        } else if !value {
            for job in jobs where job.batteryPaused {
                try update(job.id) { $0.state = .queued; $0.batteryPaused = false }
            }
            start()
        }
    }
    private func update(_ id: UUID, _ mutate: (inout TranscriptionJob) -> Void) throws {
        if lease < 0 { jobs = try store.values(TranscriptionJob.self, kind: "job") }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[index]
        mutate(&job)
        try store.put(job, kind: "job", id: id.uuidString)
        jobs[index] = job
    }
    private func stage(_ id: UUID, _ name: String, _ fraction: Double) throws {
        try Task.checkCancellation()
        if let saved = try store.values(TranscriptionJob.self, kind: "job").first(where: { $0.id == id }),
           saved.state == .paused || saved.state == .cancelled {
            if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index] = saved }
            throw CancellationError()
        }
        if let activeStage { signposter.endInterval("Pipeline stage", activeStage) }
        activeStage = signposter.beginInterval("Pipeline stage", "\(name, privacy: .public)")
        try update(id) { $0.state = .running; $0.stage = name; $0.fraction = fraction }
        logger.info("Stage: \(name, privacy: .public)")
    }
    private func process(_ id: UUID) async {
        let interval = signposter.beginInterval("Transcription job")
        defer {
            if let activeStage { signposter.endInterval("Pipeline stage", activeStage) }
            activeStage = nil
            signposter.endInterval("Transcription job", interval)
        }
        do {
            guard let job = jobs.first(where: { $0.id == id }) else { throw CancellationError() }
            let folder = directory.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let resolver = Resolver(fetcher: URLSessionFetcher(client: client))
            var record: EpisodeRecord?
            // A timed publisher transcript bypasses download, ASR and diarization altogether.
            if job.episode.transcripts.count > 0 {
                try stage(id, "Published transcript", 0.05)
                for link in TranscriptLink.preferred(job.episode.transcripts) {
                    do {
                        let imported = try await resolver.transcript(link)
                        guard imported.hasTimings, !imported.cues.isEmpty else { continue }
                        let segments = imported.cues.enumerated().compactMap { index, cue -> Segment? in
                            guard let start = cue.start, let end = cue.end else { return nil }
                            return Segment(id: index, speaker: SpeakerID(cue.speaker ?? "S1"),
                                           words: [Word(text: cue.text, start: start, end: end, confidence: 0)])
                        }
                        let raw = Transcript(language: job.episode.language ?? "und", segments: segments)
                        record = makeRecord(job.episode, transcript: raw, embeddings: [:], audio: nil)
                        for cue in imported.cues {
                            guard let name = cue.speaker, let start = cue.start,
                                  name.range(of: #"^(?:S\d+|SPEAKER_?\d+|Speaker \d+)$"#, options: [.regularExpression, .caseInsensitive]) == nil else { continue }
                            let speakerID = SpeakerID(name)
                            record?.speakers[speakerID]?.name = name
                            record?.speakers[speakerID]?.suggestionConfidence = 0.9
                            record?.speakerEvidence[speakerID] = [SpeakerEvidence(name: name, source: "publisher", confidence: 0.9, citation: Citation(start: start, quote: cue.text))]
                        }
                        break
                    } catch is CancellationError { throw CancellationError() }
                    catch { logger.notice("Publisher transcript unavailable; trying next source") }
                }
            }
            if record == nil {
                let decodedURL = folder.appendingPathComponent("decoded.wav")
                let asset: AudioAsset
                if let data = try? Data(contentsOf: folder.appendingPathComponent("decoded.json")),
                   let cached = try? JSONDecoder().decode(AudioAsset.self, from: data), FileManager.default.fileExists(atPath: cached.url.path) {
                    asset = cached
                } else {
                    guard let enclosure = job.episode.enclosureURL else { throw EngineError.unavailable("This episode has no downloadable audio.") }
                    let source = folder.appendingPathComponent("source.\(enclosure.pathExtension.isEmpty ? "audio" : enclosure.pathExtension)")
                    try stage(id, "Downloading", 0.05)
                    if !FileManager.default.fileExists(atPath: source.path) {
                        if enclosure.isFileURL {
                            let staging = source.appendingPathExtension(UUID().uuidString + ".importing")
                            defer { try? FileManager.default.removeItem(at: staging) }
                            try FileManager.default.copyItem(at: enclosure, to: staging)
                            try FileManager.default.moveItem(at: staging, to: source)
                        }
                        else { try await client.allow(enclosure); try await client.download(enclosure, to: source) }
                    }
                    try stage(id, "Decoding 16 kHz mono", 0.1)
                    asset = try await Task.detached { try AudioDecoder.decode(source, to: decodedURL) }.value
                    try JSONEncoder().encode(asset).write(to: folder.appendingPathComponent("decoded.json"), options: .atomic)
                }
                let inferenceID = UUID()
                try await inferenceGate.acquire(inferenceID)
                do {
                    let transcriber = WindowedTranscriber(engine: engine, diarizer: diarizer,
                                                          aligner: engine.id.hasPrefix("scriberr") ? IsolatedEngine() : nil)
                    let combined = try await transcriber.run(asset, language: job.episode.language, folder: folder) { name, fraction in
                        try await self.stage(id, name, fraction)
                    }
                    let transcript = try WordAlignment.render(combined)
                    record = makeRecord(job.episode, transcript: transcript, embeddings: combined.embeddings, audio: asset.url, audioDuration: asset.duration)
                    await inferenceGate.release(inferenceID)
                } catch { await inferenceGate.release(inferenceID); throw error }
            }
            try stage(id, "Saving library", 0.95)
            guard var record else { throw EngineError.invalidResult }
            if let chapters = job.episode.chaptersURL {
                record.chapters = (try? await resolver.chapters(chapters))?.map { Chapter(title: $0.title, start: $0.start, summary: "") } ?? []
            }
            try Task.checkCancellation()
            try store.save(record)
            try update(id) { $0.state = .completed; $0.stage = "Complete"; $0.fraction = 1; $0.error = nil }
        } catch is CancellationError {
            // Explicit paused/cancelled state was persisted before cancelling the worker.
        } catch {
            logger.error("Job failed: \(error.localizedDescription, privacy: .public)")
            try? update(id) { $0.state = .failed; $0.error = error.localizedDescription }
        }
        current = nil; worker = nil
        start()
    }
    public nonisolated static func episodeID(_ episode: ResolvedEpisode) -> String {
        // GUIDs are only unique within a feed. Never use a title or Swift's process-random hash as an ID.
        (episode.feedURL?.absoluteString ?? "file") + "|" + (episode.guid ?? episode.enclosureURL?.absoluteString ?? episode.title)
    }
    private func makeRecord(_ resolved: ResolvedEpisode, transcript: Transcript, embeddings: [String: [Float]], audio: URL?, audioDuration: Double = 0) -> EpisodeRecord {
        // Speakers stay anonymous here; naming them from voices and introductions is Phase 4.
        var speakers: [SpeakerID: Speaker] = [:]
        for (index, id) in Set(transcript.segments.map(\.speaker)).sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
            speakers[id] = Speaker(id: id, name: "Speaker \(index + 1)", isConfirmed: false, colorIndex: index)
        }
        let episode = Episode(id: Self.episodeID(resolved), showName: resolved.showTitle ?? "Imported audio", title: resolved.title,
                              pubDate: resolved.pubDate ?? .now, duration: max(resolved.duration ?? 0, transcript.duration, audioDuration),
                              descriptionHTML: resolved.descriptionHTML ?? "", sourceName: "Source", sourceURL: resolved.feedURL,
                              enclosureURL: resolved.enclosureURL, artworkHue: 0.15)
        return EpisodeRecord(episode: episode, transcript: transcript, speakers: speakers, audioURL: audio,
                             feedURL: resolved.feedURL, embeddings: embeddings)
    }
}
