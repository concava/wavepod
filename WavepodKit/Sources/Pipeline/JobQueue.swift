import Darwin
import Engine
import Foundation
import Library
import LLM
import Networking
import OSLog
import Resolver
import Speakers

public struct TranscriptionJob: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case queued, running, paused, failed, cancelled, completed }
    public var id: UUID
    public var episode: ResolvedEpisode
    public var state: State
    public var stage: String
    public var fraction: Double
    public var error: String?
    public var batteryPaused: Bool
    public var automation: SubscriptionAutomation?
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
    private let notes: EpisodeNotesService
    private var lastNotesCheck: Date?
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
                engine: any Engine = IsolatedEngine(), diarizer: any Diarizing = IsolatedEngine(), notesGenerator: (any NotesGenerating)? = nil, inferenceGate: InferenceGate = .shared) throws {
        self.store = store; self.directory = directory; self.client = client
        notes = EpisodeNotesService(store: store, generator: notesGenerator ?? LocalGenerator(directory: directory.deletingLastPathComponent().appendingPathComponent("models/language")))
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
    public func isBusy() -> Bool { worker != nil }
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
    @discardableResult public func enqueue(_ episode: ResolvedEpisode, automation: SubscriptionAutomation? = nil) throws -> UUID {
        jobs = try store.values(TranscriptionJob.self, kind: "job")
        let key = Self.episodeID(episode)
        let needsTranscript = automation?.transcribe ?? true
        let hasTranscript = try store.episode(key)?.transcript.segments.isEmpty == false
        if let old = jobs.first(where: { Self.episodeID($0.episode) == key && ![.cancelled, .failed].contains($0.state)
            && ($0.state != .completed || !needsTranscript || hasTranscript) }) { return old.id }
        var job = TranscriptionJob(episode: episode, engineID: engine.id)
        job.automation = automation
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
            let previous = try store.episode(Self.episodeID(job.episode))
            var record = job.automation != nil && previous?.transcript.segments.isEmpty == false ? previous : nil
            var downloaded = previous?.audioURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            if job.automation?.download == true, downloaded == nil {
                guard let enclosure = job.episode.enclosureURL else { throw EngineError.unavailable("This episode has no downloadable audio.") }
                let destination = directory.deletingLastPathComponent().appendingPathComponent("audio/\(id.uuidString).\(enclosure.pathExtension.isEmpty ? "audio" : enclosure.pathExtension)")
                try stage(id, "Downloading for offline playback", 0.02)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    if enclosure.isFileURL {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: enclosure, to: destination)
                    } else { try await client.allow(enclosure); try await client.download(enclosure, to: destination) }
                }
                downloaded = destination
            }
            if let downloaded, previous?.audioURL != downloaded {
                var offline = previous ?? makeRecord(job.episode, transcript: Transcript(language: job.episode.language ?? "und", segments: []), embeddings: [:], audio: downloaded)
                offline.audioURL = downloaded
                try store.save(offline)
            }
            if job.automation?.transcribe == false, record == nil {
                record = makeRecord(job.episode, transcript: Transcript(language: job.episode.language ?? "und", segments: []), embeddings: [:], audio: downloaded)
            }
            // A timed publisher transcript bypasses decode, ASR and diarization.
            if record == nil, job.episode.transcripts.count > 0 {
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
                    catch { logger.notice("No publisher transcript. Trying the next source") }
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
                    let source = downloaded ?? folder.appendingPathComponent("source.\(enclosure.pathExtension.isEmpty ? "audio" : enclosure.pathExtension)")
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
            try Task.checkCancellation()
            if let downloaded { record.audioURL = downloaded }
            if let previous {
                record.chat = previous.chat
                record.summary = previous.summary
                if !previous.speakers.isEmpty { record.speakers = previous.speakers; record.speakerEvidence = previous.speakerEvidence }
            }
            record.notesPending = job.automation?.summarize == true || previous?.notesPending == true
            if job.automation != nil, downloaded == nil { record.audioURL = nil }
            try store.save(record)
            if job.automation != nil {
                for name in try FileManager.default.contentsOfDirectory(atPath: folder.path)
                    where name == "decoded.wav" || name.hasPrefix("source.") {
                    try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                }
            }
            if job.automation?.summarize == true, record.notesPending == true {
                try stage(id, "Summarizing", 0.97)
                do { try await notes.completePending(record.id) }
                catch is CancellationError { throw CancellationError() }
                catch { logger.notice("Summary pending: \(error.localizedDescription, privacy: .public)") }
            }
            try update(id) { $0.state = .completed; $0.stage = "Complete"; $0.fraction = 1; $0.error = nil }
            do {
                if let show = try store.values(Subscription.self, kind: "subscription").first(where: { $0.feedURL == record.feedURL }) {
                    try AudioRetention.prune(show, store: store, directory: directory.deletingLastPathComponent())
                }
            } catch { logger.notice("Audio retention: \(error.localizedDescription, privacy: .public)") }
        } catch is CancellationError {
            // Explicit paused/cancelled state was persisted before cancelling the worker.
        } catch {
            logger.error("Job failed: \(error.localizedDescription, privacy: .public)")
            try? update(id) { $0.state = .failed; $0.error = error.localizedDescription }
            if let feed = jobs.first(where: { $0.id == id })?.episode.feedURL,
               let shows = try? store.values(Subscription.self, kind: "subscription"),
               let show = shows.first(where: { $0.feedURL == feed }) {
                try? AudioRetention.prune(show, store: store, directory: directory.deletingLastPathComponent())
            }
        }
        current = nil; worker = nil
        start()
        await retryPendingSummaries()
    }
    public func retryPendingSummaries(force: Bool = false) async {
        guard lease >= 0, worker == nil, !onBattery else { return }
        if !force, let lastNotesCheck, Date().timeIntervalSince(lastNotesCheck) < 3600 { return }
        lastNotesCheck = .now
        let task = Task { await self.completePendingSummaries() }
        worker = task
        await task.value
        worker = nil
        start()
    }
    private func completePendingSummaries() async {
        do {
            let shows = try store.values(Subscription.self, kind: "subscription")
            for record in try store.episodes() where record.notesPending == true {
                guard shows.contains(where: { $0.feedURL == record.feedURL && $0.autoSummarize }) else { continue }
                do {
                    try Task.checkCancellation()
                    try await notes.completePending(record.id)
                } catch is CancellationError { return }
                catch { logger.notice("Summary pending: \(error.localizedDescription, privacy: .public)") }
            }
        } catch { logger.notice("Summary pending: \(error.localizedDescription, privacy: .public)") }
    }
    public nonisolated static func episodeID(_ episode: ResolvedEpisode) -> String {
        // GUIDs are only unique within a feed. Never use a title or Swift's process-random hash as an ID.
        (episode.feedURL?.absoluteString ?? "file") + "|" + (episode.guid ?? episode.enclosureURL?.absoluteString ?? episode.title)
    }
    private func makeRecord(_ resolved: ResolvedEpisode, transcript: Transcript, embeddings: [String: [Float]], audio: URL?, audioDuration: Double = 0) -> EpisodeRecord {
        let showID = resolved.feedURL?.absoluteString ?? "file"
        let profiles = (try? store.values(VoiceProfile.self, kind: "voice")) ?? []
        var speakers: [SpeakerID: Speaker] = [:]
        var evidence: [SpeakerID: [SpeakerEvidence]] = [:]
        for (index, id) in Set(transcript.segments.map(\.speaker)).sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
            let voice = embeddings[id.rawValue].flatMap { SpeakerIdentity.match($0, showID: showID, profiles: profiles) }
            let candidates = SpeakerIdentity.candidates(names: resolved.persons.map(\.name), description: resolved.descriptionHTML ?? "", transcript: transcript, speaker: id)
            let suggestions = (voice.map { [$0] } ?? []) + candidates
            evidence[id] = suggestions.map { SpeakerEvidence(name: $0.name, source: $0.source.rawValue, confidence: $0.confidence, citation: $0.evidence) }
            let suggestion = suggestions.first { $0.source == .voice || $0.source == .introduction }
            speakers[id] = Speaker(id: id, name: suggestion?.name ?? "Speaker \(index + 1)", isConfirmed: false,
                                   suggestionConfidence: suggestion?.confidence, colorIndex: index)
        }
        let episode = Episode(id: Self.episodeID(resolved), showName: resolved.showTitle ?? "Imported audio", title: resolved.title,
                              pubDate: resolved.pubDate ?? .now, duration: max(resolved.duration ?? 0, transcript.duration, audioDuration),
                              descriptionHTML: resolved.descriptionHTML ?? "", sourceName: "Source", sourceURL: resolved.feedURL,
                              enclosureURL: resolved.enclosureURL, artworkHue: 0.15, artworkURL: resolved.artwork)
        return EpisodeRecord(episode: episode, transcript: transcript, speakers: speakers, audioURL: audio,
                             feedURL: resolved.feedURL, embeddings: embeddings, speakerEvidence: evidence)
    }
}
