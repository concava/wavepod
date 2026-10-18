import AppKit
import Library
import Observation
import Player
import UniformTypeIdentifiers

@MainActor
@Observable
public final class AppModel {
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case library, shows, queue, search, settings
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .library: "Library"
            case .shows: "Shows"
            case .queue: "Queue"
            case .search: "Search"
            case .settings: "Settings"
            }
        }
        public var symbol: String {
            switch self {
            case .library: "books.vertical"
            case .shows: "square.stack"
            case .queue: "list.bullet.indent"
            case .search: "magnifyingglass"
            case .settings: "gearshape"
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
    public var section: Section = .library
    public var centerTab: CenterTab = .transcript
    public var appearance: Appearance = .system
    public var textScale: Double = 1

    // Episode in the workspace
    public private(set) var episode: Episode
    public private(set) var speakers: [SpeakerID: Speaker]
    public private(set) var transcript: Transcript
    public private(set) var paragraphs: [Paragraph]
    public private(set) var chapters: [Chapter]
    public private(set) var summary: EpisodeSummary?
    public private(set) var chat: [ChatMessage]

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
    public private(set) var notice: String?

    public let player: PlayerModel
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    public init(player: PlayerModel = PlayerModel()) {
        self.player = player
        episode = SampleData.episode
        speakers = SampleData.speakers
        transcript = SampleData.transcript
        paragraphs = SampleData.transcript.paragraphs(merge: true)
        chapters = SampleData.chapters
        summary = SampleData.summary
        chat = SampleData.chat
        player.load(episode)
    }

    // MARK: Speakers

    public func speaker(_ id: SpeakerID) -> Speaker {
        speakers[id] ?? Speaker(id: id, name: id.rawValue, isConfirmed: false, colorIndex: 0)
    }

    /// Renames a speaker everywhere: transcript, summary, exports. Empty names are ignored.
    public func rename(_ id: SpeakerID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var speaker = speakers[id] else { return }
        speaker.name = trimmed
        speaker.isConfirmed = true
        speaker.suggestionConfidence = nil
        speakers[id] = speaker
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

    /// A pasted link goes to link resolution (Phase 2); anything else is a search.
    public func submitCommand() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
            show("Opening links arrives with link resolution (Phase 2): \(url.host ?? text)")
        } else {
            section = .search
        }
    }

    // MARK: Ask this episode

    public var isAnswering = false

    /// Until the local model ships (Phase 5) this returns the passages that best match the question, each with its
    /// timestamp, and says so. It never writes an answer the transcript does not contain.
    public func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        chat.append(ChatMessage(role: .user, text: q, date: .now))
        let matches = PassageSearch.best(for: q, in: transcript, limit: 2)
        if matches.isEmpty {
            chat.append(ChatMessage(role: .assistant,
                                    text: "I couldn't find anything about that in this episode.", date: .now))
        } else {
            chat.append(ChatMessage(
                role: .assistant,
                text: "The local model isn't installed yet, so here are the passages that best match your question.",
                citations: matches.map { Citation(start: $0.start, quote: $0.words.map(\.text).joined(separator: " ")) },
                date: .now))
        }
    }

    // MARK: Appearance and notices

    public func cycleAppearance() {
        let all = Appearance.allCases
        appearance = all[(all.firstIndex(of: appearance)! + 1) % all.count]
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

/// Keyword overlap over transcript segments. A placeholder for the embedding retrieval in Phase 5.
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
