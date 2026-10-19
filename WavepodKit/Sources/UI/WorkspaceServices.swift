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
    let chatGPT: ChatGPTPlan
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
        chatGPT = ChatGPTPlan(client: client)
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
    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPSBatteryPowerValue || ProcessInfo.processInfo.isLowPowerModeEnabled
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
    public func toggleAuto(_ show: Subscription) {
        guard let services else { return }
        do {
            var updated = show; updated.autoTranscribe.toggle()
            try services.store.put(updated, kind: "subscription", id: show.id)
            subscriptions = try services.store.values(Subscription.self, kind: "subscription")
        } catch { self.show(error.localizedDescription) }
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
        }
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
                if episode.id == id { player.load(episode, audioURL: destination) }
                show("Audio downloaded")
            } catch { show(error.localizedDescription) }
        }
    }
    public func generateNotes(chaptersOnly: Bool = false) {
        guard let services, !isGenerating, !transcript.segments.isEmpty else { return }
        isGenerating = true
        let id = episode.id, source = transcript
        Task {
            defer { isGenerating = false }
            do {
                let claims = try await services.generator.notes(source, chapters: chaptersOnly)
                guard var record = try services.store.episode(id) else { return }
                if chaptersOnly {
                    record.chapters = claims.sorted { $0.start < $1.start }.map { Chapter(title: $0.claim, start: $0.start, summary: $0.quote) }
                } else {
                    record.summary = EpisodeSummary(overview: claims.prefix(3).map(\.claim).joined(separator: " "),
                                                    points: claims.map { SummaryPoint(text: $0.claim, citation: $0.citation) }, quotes: Array(claims.prefix(3).map(\.citation)))
                }
                try services.store.save(record)
                if episode.id == id { install(record, reloadPlayer: false) }
                if claims.isEmpty { show("Not found in this episode: no claims passed citation checking.") }
            } catch { show(error.localizedDescription) }
        }
    }
    public func translate() {
        guard let services, !isGenerating, askLanguage != .auto else { show("Choose a translation language first."); return }
        isGenerating = true
        let source = transcript, language = askLanguage.title
        Task {
            defer { isGenerating = false }
            do {
                translationText = try await services.generator.translation(source, language: language)
                showTranslation = true
            } catch { show(error.localizedDescription) }
        }
    }
}
