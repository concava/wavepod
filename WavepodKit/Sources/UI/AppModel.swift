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
        case general, transcription, ask, queue, models, shows, privacy
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .general: "General"
            case .transcription: "Transcription"
            case .ask: "Ask"
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
            case .ask: "bubble.left.and.text.bubble.right"
            case .queue: "list.bullet.indent"
            case .models: "shippingbox"
            case .shows: "dot.radiowaves.left.and.right"
            case .privacy: "lock.shield"
            }
        }
    }

    /// What the episode view's right-hand pane shows next to the transcript.
    public enum SidePane: String, CaseIterable, Identifiable, Sendable {
        case transcript, chapters, about
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
        public var symbol: String {
            switch self {
            case .transcript: "text.quote"
            case .chapters: "list.number"
            case .about: "info.circle"
            }
        }
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
    public var sidePane: SidePane = .transcript
    public var showSidePane = UserDefaults.standard.object(forKey: "showSidePane") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSidePane, forKey: "showSidePane") }
    }

    /// Opens the side pane on `pane`, or closes it when that pane is already showing.
    public func toggleSidePane(_ pane: SidePane) {
        if showSidePane && sidePane == pane { showSidePane = false } else { sidePane = pane; showSidePane = true }
    }
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
    /// The podcast's feed, when the episode came from one; imported files have none.
    public internal(set) var feedURL: URL?

    // Transcript view options
    public var showSpeakerLabels = true
    public var mergeLines = true {
        didSet { paragraphs = transcript.paragraphs(merge: mergeLines) }
    }
    /// Keep the current paragraph in view while playing. Turned off when the user scrolls away, back on with "Follow".
    public var followPlayback = true
    struct TranscriptLocation: Equatable { let id = UUID(); let time: Seconds }
    var transcriptLocation: TranscriptLocation?

    // Keyboard focus requested by a menu command (⌘K, ⌘J); RootView moves focus and clears it.
    public enum FocusTarget: Sendable { case command, ask, transcript }
    public var focusRequest: FocusTarget?

    // Command field and Ask
    public var commandText = ""
    /// Where answers run. Stored by raw value in `askProvider`.
    public enum AskProvider: String, CaseIterable, Identifiable, Sendable {
        case local, chatgpt, claude
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .local: "On this Mac"
            case .chatgpt: "My ChatGPT plan"
            case .claude: "My Claude plan"
            }
        }
        public var shortTitle: String {
            switch self {
            case .local: "On this Mac"
            case .chatgpt: "ChatGPT"
            case .claude: "Claude"
            }
        }
    }
    /// Whether the chosen plan has what it needs to answer; false sends the user to Settings → Ask.
    var isAskProviderReady: Bool {
        switch AskProvider(rawValue: askProvider) ?? .local {
        case .local: true
        case .chatgpt: chatGPTProfiles.contains { $0.id == chatGPTProfileID && $0.connected }
        case .claude: !claudeExecutable.isEmpty
        }
    }
    public var askProvider = UserDefaults.standard.string(forKey: "askProvider") ?? "local" {
        didSet { UserDefaults.standard.set(askProvider, forKey: "askProvider") }
    }
    public var chatGPTProfileID = UserDefaults.standard.string(forKey: "chatGPTProfile") ?? "" {
        didSet { UserDefaults.standard.set(chatGPTProfileID, forKey: "chatGPTProfile") }
    }
    public var chatGPTModelID = "" {
        didSet { UserDefaults.standard.set(chatGPTModelID, forKey: "chatGPTModel.\(chatGPTProfileID)") }
    }
    public var claudeExecutable = UserDefaults.standard.string(forKey: "claudeExecutable")
        .flatMap { ClaudePlan.isExecutable($0) ? $0 : nil } ?? ClaudePlan.detectedExecutable {
        didSet { UserDefaults.standard.set(claudeExecutable, forKey: "claudeExecutable"); claudeStatus = "Connect your Claude plan." }
    }
    public var claudeModel = UserDefaults.standard.string(forKey: "claudeModel") ?? "sonnet" {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "claudeModel") }
    }
    public var claudeStatus = "Connect your Claude plan."
    public var isConnectingClaude = false
    @ObservationIgnored var claudeConnectionTask: Task<Void, Never>?
    public var chatGPTProfiles: [ChatGPTProfile] = []
    public var chatGPTModels: [ChatGPTModel] = []
    public var chatGPTStatus = "Connect an eligible ChatGPT account to use your plan."
    public var isConnectingChatGPT = false
    public var showChatGPTPlanNotice = false
    @ObservationIgnored var chatGPTConnectionTask: Task<Void, Never>?
    /// The language of the last translation; answers always follow the question's language.
    public var translationLanguage: AskLanguage = .en
    /// One-line status shown under the top bar ("Copied transcript", "Link resolution arrives in Phase 2", …).
    public internal(set) var notice: String?

    var episodeAudioURL: URL?

    public let player: PlayerModel
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    @ObservationIgnored var services: WorkspaceServices?
    @ObservationIgnored private var workspaceTask: Task<Void, Never>?
    @ObservationIgnored private var loadedJobs = false
    @ObservationIgnored var autoNoted: Set<String> = []
    public var isPersistent = false
    public var speakerEvidence: [SpeakerID: [SpeakerEvidence]] = [:]
    public var savedEpisodes: [EpisodeListing] = []
    public var jobs: [TranscriptionJob] = []
    public var subscriptions: [Subscription] = []
    public var resolvedShow: ResolvedShow?
    /// Each followed podcast's feed episodes, fetched when the Podcasts page opens, keyed by feed URL.
    public var podcastEpisodes: [String: [ResolvedEpisode]] = [:]
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
    /// Set once any speaker is named, in any episode (imported files keep no voice profile, so voices alone miss them).
    public var hasNamedSpeaker = UserDefaults.standard.bool(forKey: "hasNamedSpeaker") {
        didSet { if hasNamedSpeaker != oldValue { UserDefaults.standard.set(hasNamedSpeaker, forKey: "hasNamedSpeaker") } }
    }
    /// The first-run welcome. Shown until finished or skipped once.
    public var showOnboarding = false

    public func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        showOnboarding = false
    }
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
        if !persistent, player.episode == nil { player.load(episode) }
        isPersistent = persistent
        if persistent {
            showOnboarding = !UserDefaults.standard.bool(forKey: "onboarded")
            episode = Episode(id: "", showName: "wavepod", title: "Open an episode", pubDate: .now, duration: 0,
                              descriptionHTML: "Paste a podcast link above or open an audio file to begin.", sourceName: "Source", sourceURL: nil, enclosureURL: nil, artworkHue: 0.15)
            speakers = [:]; transcript = Transcript(language: "und", segments: [])
            paragraphs = []; chapters = []; summary = nil; chat = []
            if player.episode == nil { player.load(episode) }
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
                                self.isPowerPaused = PowerPolicy.shouldPause(currentlyPaused: self.isPowerPaused)
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

    func install(_ record: EpisodeRecord) {
        cancelAnswer()
        episode = record.episode; transcript = record.transcript; speakers = record.speakers
        speakerEvidence = record.speakerEvidence
        paragraphs = transcript.paragraphs(merge: mergeLines); chapters = record.chapters
        summary = record.summary; chat = record.chat; feedURL = record.feedURL
        if speakers.values.contains(where: \.isConfirmed) { hasNamedSpeaker = true }
        episodeAudioURL = record.audioURL
        transcriptLocation = nil
        backfillArtwork()
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
                install(record)
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
        hasNamedSpeaker = true
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

    public var isViewingLoadedEpisode: Bool { !episode.id.isEmpty && player.episode?.id == episode.id }
    public var isViewedEpisodePlaying: Bool { isViewingLoadedEpisode && player.isPlaying }
    public var currentParagraphIndex: Int? { isViewingLoadedEpisode ? paragraphs.index(at: player.currentTime) : nil }

    public var currentChapterIndex: Int? {
        isViewingLoadedEpisode ? chapters.lastIndex { $0.start <= player.currentTime } : nil
    }

    public func toggleEpisodePlayback() {
        if isViewedEpisodePlaying { player.pause() }
        else { play(from: isViewingLoadedEpisode ? player.currentTime : 0) }
    }

    public func play(from time: Seconds) {
        guard !episode.id.isEmpty else { return }
        if !isViewingLoadedEpisode { player.load(episode, audioURL: episodeAudioURL) }
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
    public var askProgress = ""
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    public func cancelAnswer() { answerTask?.cancel() }

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
        let id = episode.id, source = transcript, language = "Auto", history = Array(chat.dropLast())
        let provider = askProvider, account = chatGPTProfileID
        let model = chatGPTModelID.isEmpty ? UserDefaults.standard.string(forKey: "chatGPTModel.\(account)") ?? "" : chatGPTModelID
        let claudePath = claudeExecutable, claudeChoice = claudeModel
        askProgress = "Preparing transcript…"
        answerTask = Task { [self] in
            defer { isAnswering = false; askProgress = ""; answerTask = nil }
            do {
                let progress: @Sendable (String) async -> Void = { [weak self] status in
                    await MainActor.run { if self?.episode.id == id { self?.askProgress = status } }
                }
                let claims: [CitedClaim]
                if provider == "chatgpt" {
                    claims = try await EpisodeAnswers(generator: ChatGPTGenerator(plan: services.chatGPT, account: account, model: model), contextLimit: 40_000)
                        .answer(question: q, language: language, history: history, transcript: source, progress: progress)
                } else if provider == "claude" {
                    claims = try await EpisodeAnswers(generator: ClaudeGenerator(plan: services.claude, executable: claudePath, model: claudeChoice), contextLimit: 40_000)
                        .answer(question: q, language: language, history: history, transcript: source, progress: progress)
                } else {
                    claims = try await services.generator.withSession { generator in
                        try await EpisodeAnswers(generator: generator).answer(question: q, language: language, history: history, transcript: source, progress: progress)
                    }
                }
                try Task.checkCancellation()
                saveAskMessage(ChatMessage(role: .assistant, text: claims.isEmpty ? "I read the whole transcript and couldn’t find evidence to answer that question." : claims.map(\.claim).joined(separator: "\n\n"), citations: claims.map(\.citation), date: .now, sections: EpisodeAnswers.sections(from: claims)), episodeID: id)
            } catch is CancellationError {
                saveAskMessage(ChatMessage(role: .assistant, text: "Stopped before completing the answer.", date: .now), episodeID: id)
            } catch {
                let text = Task.isCancelled ? "Stopped before completing the answer." : "I couldn’t complete this answer: \(error.localizedDescription)"
                saveAskMessage(ChatMessage(role: .assistant, text: text, date: .now), episodeID: id)
            }
        }
    }

    private func saveAskMessage(_ message: ChatMessage, episodeID: String) {
        guard let services else { return }
        do {
            guard var record = try services.store.episode(episodeID) else { return }
            record.chat.append(message)
            try services.store.save(record)
            if episode.id == episodeID { chat = record.chat }
        } catch { show(error.localizedDescription) }
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
