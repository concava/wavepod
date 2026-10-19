import AppKit
import UniformTypeIdentifiers
import Engine
import Foundation
import IOKit.ps
import Library
import LLM
import Networking
import Pipeline
import Resolver
import ServiceManagement
import Speakers

struct WorkspaceServices: Sendable {
    let root: URL
    let store: LibraryStore
    let client: HTTPClient
    let queue: JobQueue
    let subscriptions: SubscriptionMonitor
    var resolver: Resolver {
        let executable = root.appendingPathComponent("tools/yt-dlp")
        return Resolver(fetcher: URLSessionFetcher(client: client), extractor: FileManager.default.isExecutableFile(atPath: executable.path) ? YtDlpExtractor(executable: executable) : nil)
    }
    var generator: LocalGenerator { LocalGenerator(directory: root.appendingPathComponent("models/language")) }
    var embeddings: LocalEmbeddings { LocalEmbeddings(directory: root.appendingPathComponent("models/embeddings")) }
    init(root: URL) throws {
        self.root = root
        store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
        client = HTTPClient(logURL: root.appendingPathComponent("network.json"))
        let engine: any Engine
        if UserDefaults.standard.string(forKey: "engine") == "scriberr",
           let value = UserDefaults.standard.string(forKey: "scriberrURL"), let url = URL(string: value) {
            engine = try ScriberrEngine(base: url, client: client)
        } else { engine = IsolatedEngine() }
        queue = try JobQueue(store: store, directory: root.appendingPathComponent("jobs"), client: client, engine: engine)
        subscriptions = SubscriptionMonitor(store: store, client: client, queue: queue)
    }
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("wavepod")
    }
}

extension AppModel {
    public func importFile(_ url: URL) {
        guard url.isFileURL else { return }
        enqueue(ResolvedEpisode(title: url.deletingPathExtension().lastPathComponent, enclosureURL: url, source: .file))
    }
    public func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importFile(url) }
    }
    public func open(_ item: EpisodeListing, at start: Double? = nil) {
        guard let services else { return }
        do {
            if let record = try services.store.episode(item.id) { open(record, at: start) }
        } catch { show(error.localizedDescription) }
    }
    public func open(_ record: EpisodeRecord, at start: Double? = nil) {
        install(record)
        section = .library
        if let start { play(from: start) }
        writeMissingNotes()
    }

    /// Opens the podcast's page, with its full episode list and Follow.
    public func openPodcast() {
        guard let feedURL else { return }
        commandText = feedURL.absoluteString
        submitCommand()
        commandText = ""
    }
    public func enqueue(_ episode: ResolvedEpisode) {
        guard let services else { show("Open the app to import an episode."); return }
        Task {
            do { try await services.queue.enqueue(episode); section = .home; show("Transcribing \(episode.title)"); await refreshWorkspace() }
            catch { show(error.localizedDescription) }
        }
    }
    public func choose(_ candidate: ScoredCandidate) {
        guard let services else { return }
        Task {
            do { enqueue(try await services.resolver.resolve(candidate)); resolutionCandidates = [] }
            catch { show(error.localizedDescription) }
        }
    }
    public func manageJob(_ job: TranscriptionJob, action: String) {
        guard let services else { return }
        Task {
            do {
                switch action {
                case "pause": try await services.queue.pause(job.id)
                case "cancel": try await services.queue.cancel(job.id)
                default: try await services.queue.resume(job.id)
                }
                await refreshWorkspace()
            } catch { show(error.localizedDescription) }
        }
    }
    public func subscribe() {
        guard let services, let show = resolvedShow else { return }
        do {
            try services.store.put(Subscription(feedURL: show.feedURL, title: show.title,
                                                seen: Set(show.episodes.map(JobQueue.episodeID))), kind: "subscription", id: show.feedURL.absoluteString)
            subscriptions = try services.store.values(Subscription.self, kind: "subscription")
            self.resolvedShow = nil
        } catch { self.show(error.localizedDescription) }
    }
    public func updateSubscription(_ show: Subscription, download: Bool? = nil, transcribe: Bool? = nil,
                                   summarize: Bool? = nil, keepLatest: Int? = nil, setRetention: Bool = false) {
        guard let services else { return }
        do {
            guard var updated = try services.store.values(Subscription.self, kind: "subscription").first(where: { $0.id == show.id }) else { return }
            if let download { updated.autoDownload = download }
            if let transcribe { updated.autoTranscribe = transcribe; if !transcribe { updated.autoSummarize = false } }
            if let summarize { updated.autoSummarize = summarize; if summarize { updated.autoTranscribe = true } }
            if setRetention { updated.keepLatest = keepLatest }
            try services.store.put(updated, kind: "subscription", id: show.id)
            if setRetention { try AudioRetention.prune(updated, store: services.store, directory: services.root) }
            subscriptions = try services.store.values(Subscription.self, kind: "subscription")
            savedEpisodes = try services.store.items()
        } catch { self.show(error.localizedDescription) }
    }
    public func episodeStatus(_ id: String) -> String {
        var states: [String] = []
        if let item = savedEpisodes.first(where: { $0.id == id }) {
            if item.downloaded { states.append("Downloaded") }
            if item.notesPending { states.append("Summary pending") }
            else if item.summarized { states.append("Summarized") }
        }
        if let job = jobs.last(where: { JobQueue.episodeID($0.episode) == id && $0.state != .completed && $0.state != .cancelled }) {
            states.append(job.state == .running ? (job.automation?.transcribe == false || job.stage == "Summarizing" || job.stage.hasPrefix("Download") ? job.stage : "Transcribing · \(job.stage)") : job.state.rawValue.capitalized)
        }
        return states.joined(separator: " · ")
    }
    public func unsubscribe(_ subscription: Subscription) {
        guard let services else { return }
        do {
            try services.store.remove(kind: "subscription", id: subscription.id)
            subscriptions = try services.store.values(Subscription.self, kind: "subscription")
        } catch { show(error.localizedDescription) }
    }
    public func refreshShows() {
        guard let services, !isRefreshing else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            do { try await services.subscriptions.refresh(force: true); await refreshWorkspace() }
            catch { show(error.localizedDescription) }
            podcastEpisodes = [:]
            loadPodcastEpisodes()
        }
    }
    /// Fetches the feed of every followed podcast whose episodes are not loaded yet.
    public func loadPodcastEpisodes() {
        guard let services else { return }
        for show in subscriptions where podcastEpisodes[show.id] == nil {
            podcastEpisodes[show.id] = []
            Task {
                if case .show(let feed) = try? await services.resolver.resolve(show.feedURL.absoluteString) {
                    podcastEpisodes[show.id] = feed.episodes
                } else { podcastEpisodes[show.id] = nil }
            }
        }
    }
    public func isFollowing(_ feedURL: URL) -> Bool { subscriptions.contains { $0.feedURL == feedURL } }
    /// Where one feed episode stands: in the library, being transcribed, or not started.
    public func status(of episode: ResolvedEpisode) -> PodcastEpisodeStatus {
        let id = JobQueue.episodeID(episode)
        if let saved = savedEpisodes.first(where: { $0.id == id }) { return .saved(saved) }
        if let job = jobs.first(where: { JobQueue.episodeID($0.episode) == id && $0.state != .cancelled && $0.state != .completed }) {
            return job.state == .running ? .running(job.fraction) : .waiting(job.state == .failed ? "Failed" : job.state.rawValue.capitalized)
        }
        return .new
    }
    public func performSearch() {
        guard let services else { return }
        let query = commandText
        let semantic = meaningSearch
        Task {
            do {
                if semantic {
                    let vector = try await services.embeddings.encode([query], query: true).first ?? []
                    let hits = try services.store.semanticSearch(vector, model: services.embeddings.modelID)
                    if query == commandText { searchHits = hits }
                } else { searchHits = try services.store.search(query) }
            } catch { show(error.localizedDescription) }
        }
    }
    public func openHit(_ hit: SearchHit) {
        guard let record = savedEpisodes.first(where: { $0.id == hit.episodeID }) else { return }
        open(record, at: hit.start)
    }
    public func indexLibrary() {
        guard let services, !isIndexing else { return }
        isIndexing = true
        Task {
            defer { isIndexing = false }
            do {
                for item in savedEpisodes {
                    if let record = try services.store.episode(item.id) { try await services.embeddings.index([record], store: services.store) }
                }
                show("Meaning search index updated")
            }
            catch { show(error.localizedDescription) }
        }
    }
    public func installModels(_ kind: String) {
        guard let services, !isInstalling else { return }
        isInstalling = true
        modelStatus = "Preparing download…"
        Task {
            defer { isInstalling = false }
            do {
                let installer = ModelInstaller(client: services.client, root: services.root.appendingPathComponent("models"))
                let specs = kind == "native" ? ModelSpec.native : [kind == "language" ? .language : .embeddings]
                for spec in specs {
                    try await installer.install(spec) { status in
                        Task { @MainActor [weak self] in self?.modelStatus = status }
                    }
                }
                modelStatus = "Models installed"
                if kind == "embeddings" { indexLibrary() }
                if kind == "language" { await services.queue.retryPendingSummaries(force: true); await refreshWorkspace() }
            } catch { modelStatus = error.localizedDescription }
        }
    }
    public func saveEngine() {
        do {
            if engineChoice == "scriberr" {
                guard let url = URL(string: scriberrURL), let services else { return }
                _ = try ScriberrEngine(base: url, client: services.client)
                try APIKeyStore.set(scriberrKey, host: url.absoluteString)
            }
            UserDefaults.standard.set(engineChoice, forKey: "engine")
            UserDefaults.standard.set(scriberrURL, forKey: "scriberrURL")
            scriberrKey = ""
            show("Engine saved. Restart wavepod after current jobs finish to apply it.")
        } catch { show(error.localizedDescription) }
    }
    public func setBackgroundChecks(_ enabled: Bool) {
        do {
            let service = SMAppService.agent(plistName: "app.wavepod.feeds.plist")
            if enabled { try service.register() } else { try service.unregister() }
            backgroundChecks = enabled
        } catch { show("Background checks: \(error.localizedDescription)") }
    }
    public func downloadAudio() {
        guard let services, let url = episode.enclosureURL else { return }
        let id = episode.id
        Task {
            do {
                let destination = services.root.appendingPathComponent("audio/\(UUID().uuidString).\(url.pathExtension)")
                if url.isFileURL { try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true); try FileManager.default.copyItem(at: url, to: destination) }
                else { try await services.client.allow(url); try await services.client.download(url, to: destination) }
                guard var record = try services.store.episode(id) else { return }
                record.audioURL = destination
                try services.store.save(record)
                if let subscription = try services.store.values(Subscription.self, kind: "subscription").first(where: { $0.feedURL == record.feedURL }) {
                    try AudioRetention.prune(subscription, store: services.store, directory: services.root)
                }
                let retained = try services.store.episode(id)?.audioURL
                if episode.id == id { player.load(episode, audioURL: retained) }
                show(retained == nil ? "Audio removed by this show's retention setting" : "Audio downloaded")
            } catch { show(error.localizedDescription) }
        }
    }
    public func generateNotes(chaptersOnly: Bool = false) {
        Task { await writeNotes(chaptersOnly ? [.chapters] : [.summary]) }
    }

    enum NoteKind { case summary, chapters }

    /// Writes the summary and chapters an episode lacks, once per episode per launch, when the language model is
    /// installed. Called when a transcription finishes and when an episode opens.
    func writeMissingNotes() {
        guard installedModels.contains("language"), !episode.id.isEmpty, !autoNoted.contains(episode.id) else { return }
        var kinds: [NoteKind] = []
        if summary == nil { kinds.append(.summary) }
        if chapters.isEmpty { kinds.append(.chapters) }
        guard !kinds.isEmpty else { return }
        autoNoted.insert(episode.id)
        Task { await writeNotes(kinds) }
    }

    func writeNotes(_ kinds: [NoteKind]) async {
        guard let services, !isGenerating, !transcript.segments.isEmpty else { return }
        isGenerating = true
        defer { isGenerating = false }
        let id = episode.id
        let notes = EpisodeNotesService(store: services.store, generator: services.generator)
        for kind in kinds {
            do {
                let claims = try await notes.generate(id, chapters: kind == .chapters)
                guard let record = try services.store.episode(id) else { return }
                if episode.id == id { install(record, reloadPlayer: false) }
                if claims.isEmpty { show("Not found in this episode: no claims passed citation checking.") }
            } catch { show(error.localizedDescription) }
        }
    }
    public func translate(to target: AskLanguage) {
        guard let services, !isGenerating, target != .auto else { return }
        translationLanguage = target
        isGenerating = true
        let source = transcript, language = target.title
        Task {
            defer { isGenerating = false }
            do {
                translationText = try await services.generator.translation(source, language: language)
                showTranslation = true
            } catch { show(error.localizedDescription) }
        }
    }
}

public enum PodcastEpisodeStatus {
    case new, waiting(String), running(Double), saved(EpisodeListing)
}

extension ResolvedShow {
    /// The newest `count` episodes, newest first.
    func latest(_ count: Int = 5) -> [ResolvedEpisode] { Self.latest(episodes, count) }
    static func latest(_ episodes: [ResolvedEpisode], _ count: Int = 5) -> [ResolvedEpisode] {
        Array(episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }.prefix(count))
    }
}
