import AppKit
import Engine
import LLM
import Networking
import Pipeline
import Resolver
import Speakers
import ServiceManagement
import Library
import Observation
import Player
import UniformTypeIdentifiers

@MainActor
@Observable
public final class AppModel {
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case home, library, shows, search
        public var id: String { rawValue }
        /// Episode opens from Home or Recent and Search from the command field, so the sidebar lists only these.
        public static let sidebar: [Section] = [.home, .shows]
        public var title: String {
            switch self {
            case .home: "Home"
            case .library: "Episode"
            case .shows: "Podcasts"
            case .search: "Search"
            }
        }
        public var symbol: String {
            switch self {
            case .home: "house"
            case .library: "text.quote"
            case .shows: "square.stack"
            case .search: "magnifyingglass"
            }
        }
    }

    public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
        case general, transcription, queue, models, shows, privacy
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .general: "General"
            case .transcription: "Transcription"
            case .queue: "Queue"
            case .models: "Models"
            case .shows: "Podcasts"
            case .privacy: "Data and Privacy"
            }
        }
        public var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .transcription: "waveform"
            case .queue: "list.bullet.indent"
            case .models: "shippingbox"
            case .shows: "dot.radiowaves.left.and.right"
            case .privacy: "lock.shield"
            }
        }
    }

    public enum CenterTab: String, CaseIterable, Identifiable, Sendable {
        case transcript, summary, chapters
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    public enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark
    }

    public enum AskLanguage: String, CaseIterable, Identifiable, Sendable {
        case auto, en, es, ca, fr, de, pt, it
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .auto: "Auto"
            case .en: "English"
            case .es: "Español"
            case .ca: "Català"
            case .fr: "Français"
            case .de: "Deutsch"
            case .pt: "Português"
            case .it: "Italiano"
            }
        }
    }

    // Navigation and layout
    public var section: Section = .home
    /// The sidebar shrinks to an icon rail instead of disappearing.
    public var sidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed") {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed") }
    }
    public var showSettings = false
    public var settingsPane: SettingsPane = .general
    public var hideSetup = UserDefaults.standard.bool(forKey: "hideSetup") {
        didSet { UserDefaults.standard.set(hideSetup, forKey: "hideSetup") }
    }
    public var centerTab: CenterTab = .transcript
    public var appearance: Appearance = .system
    public var textScale: Double = 1

    // Episode in the workspace
    public internal(set) var episode: Episode
    public internal(set) var speakers: [SpeakerID: Speaker]
    public internal(set) var transcript: Transcript
    public internal(set) var paragraphs: [Paragraph]
    public internal(set) var chapters: [Chapter]
    public internal(set) var summary: EpisodeSummary?
    public internal(set) var chat: [ChatMessage]

    // Transcript view options
    public var showSpeakerLabels = true
    public var mergeLines = true {
        didSet { paragraphs = transcript.paragraphs(merge: mergeLines) }
    }
    /// Keep the current paragraph in view while playing. Turned off when the user scrolls away, back on with "Follow".
    public var followPlayback = true

    // Keyboard focus requested by a menu command (⌘K, ⌘J); RootView moves focus and clears it.
    public enum FocusTarget: Sendable { case command, ask, transcript }
    public var focusRequest: FocusTarget?

    // Command field and Ask
    public var commandText = ""
    public var askLanguage: AskLanguage = .auto
    /// One-line status shown under the top bar ("Copied transcript", "Link resolution arrives in Phase 2", …).
    public internal(set) var notice: String?

    public let player: PlayerModel
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    @ObservationIgnored var services: WorkspaceServices?
    @ObservationIgnored private var workspaceTask: Task<Void, Never>?
    @ObservationIgnored private var loadedJobs = false
    public var isPersistent = false
    public var speakerEvidence: [SpeakerID: [SpeakerEvidence]] = [:]
    public var savedEpisodes: [EpisodeListing] = []
    public var jobs: [TranscriptionJob] = []
    public var subscriptions: [Subscription] = []
    public var resolvedShow: ResolvedShow?
    public var resolutionCandidates: [ScoredCandidate] = []
    public var searchHits: [SearchHit] = []
    public var meaningSearch = false
    public var isPowerPaused = false
    public var isRefreshing = false
    public var isResolving = false
    public var isIndexing = false
    public var isGenerating = false
    public var isInstalling = false
    public var modelStatus = "Models are downloaded once and run on this Mac."
    public var networkEntries: [NetworkEntry] = []
    public var engineChoice = UserDefaults.standard.string(forKey: "engine") ?? "native"
    public var scriberrURL = UserDefaults.standard.string(forKey: "scriberrURL") ?? "http://localhost:8080"
    public var scriberrKey = ""
    public var backgroundChecks = SMAppService.agent(plistName: "app.wavepod.feeds.plist").status == .enabled
    public var namedVoices = 0
    public var installedModels: Set<String> = []
    public var translationText = ""
    public var showTranslation = false

    public init(player: PlayerModel = PlayerModel(), persistent: Bool = false) {
        self.player = player
        episode = SampleData.episode
        speakers = SampleData.speakers
        transcript = SampleData.transcript
        paragraphs = SampleData.transcript.paragraphs(merge: true)
        chapters = SampleData.chapters
        summary = SampleData.summary
        chat = SampleData.chat
        player.load(episode)
        isPersistent = persistent
        if persistent {
            episode = Episode(id: "", showName: "wavepod", title: "Open an episode", pubDate: .now, duration: 0,
                              descriptionHTML: "Paste a podcast link above or open an audio file to begin.", sourceName: "Source", sourceURL: nil, enclosureURL: nil, artworkHue: 0.15)
            speakers = [:]; transcript = Transcript(language: "und", segments: [])
            paragraphs = []; chapters = []; summary = nil; chat = []
            player.load(episode)
            do {
                services = try WorkspaceServices(root: WorkspaceServices.defaultRoot)
                savedEpisodes = try services!.store.items()
                if let item = savedEpisodes.first, let record = try services!.store.episode(item.id) { install(record) }
                workspaceTask = Task { [weak self] in
                    var checks = 0
                    while !Task.isCancelled {
                        guard let self else { return }
                        if let services = self.services {
                            do {
                                self.isPowerPaused = WorkspaceServices.onBattery()
                                try await services.queue.setOnBattery(self.isPowerPaused)
                                await services.queue.start()
                            } catch { self.show(error.localizedDescription) }
                        }
                        checks += 1
                        if checks % 3600 == 0 { self.refreshShows() }
                        await self.refreshWorkspace()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                refreshShows()
            } catch { show("Could not open the library: \(error.localizedDescription)") }
        }
    }

    func install(_ record: EpisodeRecord, reloadPlayer: Bool = true) {
        episode = record.episode; transcript = record.transcript; speakers = record.speakers
        speakerEvidence = record.speakerEvidence
        paragraphs = transcript.paragraphs(merge: mergeLines); chapters = record.chapters
        summary = record.summary; chat = record.chat
        if reloadPlayer { player.load(episode, audioURL: record.audioURL) }
    }

    func refreshWorkspace() async {
        guard let services else { return }
        do {
            let latestJobs = await services.queue.snapshot()
            // Jobs completed before launch are history, not news: only a completion seen while running opens the episode.
            let newCompletion = loadedJobs ? Set(latestJobs.filter { $0.state == .completed }.map(\.id))
                .subtracting(jobs.filter { $0.state == .completed }.map(\.id)) : []
            jobs = latestJobs
            loadedJobs = true
            let previous = savedEpisodes.first(where: { $0.id == episode.id })
            savedEpisodes = try services.store.items()
            if let latest = savedEpisodes.first(where: { $0.id == episode.id }),
               previous?.summarized != latest.summarized || previous?.notesPending != latest.notesPending,
               let record = try services.store.episode(latest.id) {
                install(record, reloadPlayer: false)
            }
            subscriptions = try services.store.values(Subscription.self, kind: "subscription")
            networkEntries = await services.client.log()
            namedVoices = (try? services.store.values(VoiceProfile.self, kind: "voice").count) ?? 0
            let models = services.root.appendingPathComponent("models")
            installedModels = Set(["parakeet", "language", "embeddings"].filter {
                FileManager.default.fileExists(atPath: models.appendingPathComponent($0).path)
            })
            if let job = jobs.first(where: { newCompletion.contains($0.id) }),
               let record = savedEpisodes.first(where: { $0.id == JobQueue.episodeID(job.episode) }) {
                open(record)
                if FileManager.default.fileExists(atPath: services.root.appendingPathComponent("models/embeddings/config.json").path) { indexLibrary() }
            }
        } catch { show(error.localizedDescription) }
    }

    func persistWorkspace() {
        guard let services, !episode.id.isEmpty else { return }
        do {
            guard var record = try services.store.episode(episode.id) else { return }
            record.speakers = speakers; record.chat = chat
            try services.store.save(record)
            savedEpisodes = try services.store.items()
        } catch { show(error.localizedDescription) }
    }

    // MARK: Speakers

    public func speaker(_ id: SpeakerID) -> Speaker {
        speakers[id] ?? Speaker(id: id, name: id.rawValue, isConfirmed: false, colorIndex: 0)
    }

    /// Renames a speaker everywhere: transcript, summary, exports. Empty names are ignored.
    public func rename(_ id: SpeakerID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var speaker = speakers[id] else { return }
        let previousName = speaker.name
        let wasConfirmed = speaker.isConfirmed
        speaker.name = trimmed
        speaker.isConfirmed = true
        speaker.suggestionConfidence = nil
        speakers[id] = speaker
        persistWorkspace()
        if let services {
            do {
                if let record = try services.store.episode(episode.id), let embedding = record.embeddings[id.rawValue], let feed = record.feedURL {
                    if wasConfirmed, previousName != trimmed {
                        try services.store.remove(kind: "voice", id: feed.absoluteString + "|" + previousName.lowercased())
                    }
                    let profileID = feed.absoluteString + "|" + trimmed.lowercased()
                    let profile = VoiceProfile(id: profileID, showID: feed.absoluteString, name: trimmed, embedding: embedding)
                    try services.store.put(profile, kind: "voice", id: profileID)
                }
            } catch { show(error.localizedDescription) }
        }
    }

    public func confirm(_ id: SpeakerID) {
        guard let speaker = speakers[id] else { return }
        rename(id, to: speaker.name)
    }

    // MARK: Playback helpers

    public var currentParagraphIndex: Int? { paragraphs.index(at: player.currentTime) }

    public var currentChapterIndex: Int? {
        chapters.lastIndex { $0.start <= player.currentTime }
    }

    public func play(from time: Seconds) {
        followPlayback = true
        player.jump(to: time)
    }

    // MARK: Copy and export

    public func plainText() -> String {
        paragraphs.map { p in
            showSpeakerLabels
                ? "\(speaker(p.speaker).name) [\(Timecode.format(p.start))]\n\(p.text)"
                : "[\(Timecode.format(p.start))] \(p.text)"
        }.joined(separator: "\n\n")
    }

    public func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText(), forType: .string)
        show("Transcript copied")
    }

    public func export(_ format: ExportFormat) {
        guard format.isAvailable else {
            show("Word export is not available yet")
            return
        }
        let data: Data
        do {
            data = try TranscriptExport.render(format, episode: episode, transcript: transcript,
                                               speakers: speakers, mergeLines: mergeLines)
        } catch {
            show("Export failed: \(error.localizedDescription)")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(episode.title).\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            show("Exported \(url.lastPathComponent)")
        } catch {
            show("Could not save: \(error.localizedDescription)")
        }
    }

    // MARK: Command field

    /// Resolve URLs; search text across the saved library.
    public func submitCommand() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text.hasPrefix("/") || text.hasPrefix("~/") { importFile(URL(fileURLWithPath: (text as NSString).expandingTildeInPath)); return }
        if let url = URL(string: text), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            if url.isFileURL { importFile(url); return }
            guard let services, !isResolving else { return }
            isResolving = true
            Task {
                defer { isResolving = false }
                do {
                    if case .youtube = LinkClassifier.classify(text) {
                        let executable = services.root.appendingPathComponent("tools/yt-dlp")
                        if !FileManager.default.isExecutableFile(atPath: executable.path) {
                            show("Installing the verified YouTube extractor…")
                            _ = try await YtDlpInstaller(fetcher: URLSessionFetcher(client: services.client)).install(in: executable.deletingLastPathComponent())
                        }
                    }
                    switch try await services.resolver.resolve(text) {
                    case .episode(let episode): enqueue(episode)
                    case .show(let show): resolvedShow = show; section = .shows
                    case .needsConfirmation(let candidates): resolutionCandidates = candidates; section = .shows
                    case .notFound(let reason): show(reason)
                    }
                } catch { show(error.localizedDescription) }
            }
        } else { section = .search; performSearch() }
    }

    public func openSettings(_ pane: SettingsPane? = nil) {
        if let pane { settingsPane = pane }
        showSettings = true
    }

    // MARK: Ask this episode

    public var isAnswering = false

    public func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAnswering else { return }
        chat.append(ChatMessage(role: .user, text: q, date: .now))
        guard let services else {
            let matches = PassageSearch.best(for: q, in: transcript, limit: 2)
            chat.append(ChatMessage(role: .assistant, text: matches.isEmpty ? "I couldn't find anything about that in this episode." : "Matching transcript passages:",
                                    citations: matches.map { Citation(start: $0.start, quote: $0.words.map(\.text).joined(separator: " ")) }, date: .now))
            return
        }
        persistWorkspace()
        isAnswering = true
        let id = episode.id, source = transcript, language = askLanguage.title
        Task {
            defer { isAnswering = false }
            do {
                var context = PassageSearch.best(for: q, in: source, limit: 12)
                // Semantic retrieval supplies cross-language and paraphrase matches when installed/indexed.
                if FileManager.default.fileExists(atPath: services.root.appendingPathComponent("models/embeddings/config.json").path) {
                    let vector = try await services.embeddings.encode([q], query: true).first ?? []
                    let hits = try services.store.semanticSearch(vector, model: services.embeddings.modelID, episodeID: id, limit: 12)
                    let ids = Set(hits.map(\.segmentID))
                    let semantic = source.segments.filter { ids.contains($0.id) }
                    let semanticIDs = Set(semantic.map(\.id))
                    context = Array((semantic + context.filter { !semanticIDs.contains($0.id) }).prefix(12))
                }
                let passages = context
                let claims = try await services.generator.withSession { generator in
                    try await GroundedAnswers(generator: generator).answer(
                        instruction: "Answer this question in \(language): \(q)", context: passages, transcript: source)
                }
                let answer = ChatMessage(role: .assistant, text: claims.isEmpty ? "Not found in this episode." : claims.map(\.claim).joined(separator: "\n\n"), citations: claims.map(\.citation), date: .now)
                guard var record = try services.store.episode(id) else { return }
                record.chat.append(answer)
                try services.store.save(record)
                if episode.id == id { chat = record.chat }
            } catch { show(error.localizedDescription) }
        }
    }

    // MARK: Appearance and notices

    public func cycleAppearance() {
        let all = Appearance.allCases
        appearance = all[(all.firstIndex(of: appearance)! + 1) % all.count]
        show("\(appearance.rawValue.capitalized) mode")
    }

    public func adjustTextSize(by step: Int) {
        let scales = Typography.scales
        let current = scales.firstIndex { $0 >= textScale } ?? 1
        textScale = scales[min(max(0, current + step), scales.count - 1)]
    }

    public func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

/// Keyword retrieval remains available before the optional embedding model is installed.
enum PassageSearch {
    static let stopwords: Set<String> = ["the", "and", "that", "this", "what", "when", "where", "which", "with",
                                         "were", "was", "did", "does", "about", "from", "they", "their", "there",
                                         "have", "how", "why", "who", "would", "could", "more", "than", "then"]

    static func terms(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) })
    }

    static func best(for question: String, in transcript: Transcript, limit: Int) -> [Segment] {
        let q = terms(question)
        guard !q.isEmpty else { return [] }
        var scored: [(segment: Segment, score: Int)] = []
        for segment in transcript.segments {
            let text = segment.words.map(\.text).joined(separator: " ")
            let score = terms(text).intersection(q).count
            if score > 0 { scored.append((segment, score)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.segment.start < b.segment.start }
        let top: [Segment] = scored.prefix(limit).map(\.segment)
        return top.sorted { $0.start < $1.start }
    }
}
