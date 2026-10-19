import AppKit
import Library
import Resolver
import SnapshotTesting
import SwiftUI
import XCTest
@testable import UI

/// Every main view in light and dark, plus the transcript at a large text size.
/// Record new references with `SNAPSHOT_RECORD=1 swift test`.
@MainActor
final class SnapshotTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(NSScreen.screens.isEmpty, "Snapshot rendering requires a WindowServer display.")
    }
    override func invokeTest() {
        withSnapshotTesting(record: ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1" ? .all : .missing) {
            super.invokeTest()
        }
    }

    /// A model paused 14 s in, so the second paragraph and its current word are highlighted.
    func makeModel() -> AppModel {
        let model = AppModel()
        model.player.seek(to: SampleData.transcript.segments[1].words[3].start + 0.01)
        return model
    }

    func check<V: View>(_ name: String, size: CGSize, scale: Double = 1,
                        file: StaticString = #filePath, testName: String = #function, line: UInt = #line,
                        @ViewBuilder _ view: () -> V) {
        for dark in [false, true] {
            let root = view()
                .environment(\.typography, Typography(scale: scale))
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                .frame(width: size.width, height: size.height)
                .background(Palette.paper)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            assertSnapshot(of: host, as: .image(precision: 0.995, perceptualPrecision: 0.98),
                           named: "\(name)-\(dark ? "dark" : "light")",
                           file: file, testName: testName, line: line)
        }
    }

    func testWorkspace() {
        let model = makeModel()
        check("workspace", size: CGSize(width: 1280, height: 760)) {
            VStack(spacing: 0) {
                WorkspaceSnapshot(model: model)
                PlayerBar(player: model.player)
            }
        }
    }

    func testSidebar() {
        let model = makeModel()
        check("sidebar", size: CGSize(width: 220, height: 420)) { SidebarView(model: model) }
    }

    func testAboutPane() {
        let model = makeModel()
        model.sidePane = .about
        check("about", size: CGSize(width: 420, height: 600)) { DetailSnapshot(model: model) }
    }

    func testTranscript() {
        let model = makeModel()
        check("transcript", size: CGSize(width: 760, height: 700)) { TranscriptSnapshot(model: model) }
    }

    func testTranscriptLargeText() {
        let model = makeModel()
        check("transcript-large", size: CGSize(width: 600, height: 700), scale: 1.5) {
            TranscriptSnapshot(model: model)
        }
    }

    func testSummary() {
        let model = makeModel()
        check("summary", size: CGSize(width: 620, height: 700)) { SummaryCardSnapshot(model: model) }
    }

    func testChapters() {
        let model = makeModel()
        model.sidePane = .chapters
        check("chapters", size: CGSize(width: 420, height: 500)) { DetailSnapshot(model: model) }
    }

    func testTranscriptCard() {
        let model = makeModel()
        model.sidePane = .transcript
        check("transcript-card", size: CGSize(width: 420, height: 700)) { DetailSnapshot(model: model) }
    }

    func testPodcastCard() {
        let model = makeModel()
        check("podcast", size: CGSize(width: 250, height: 500)) { PodcastCard(model: model).background(Palette.surface) }
    }

    /// A followed podcast with eight episodes shows only the newest five.
    func testPodcastFeedCard() {
        let model = makeModel()
        let feed = URL(string: "https://example.com/feed.xml")!
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let episodes = (0..<8).map { i in
            ResolvedEpisode(title: "Episode \(i + 1): a conversation about building things", feedURL: feed,
                            showTitle: "Example Show", pubDate: start.addingTimeInterval(Double(i) * 604_800),
                            duration: 3600 + Double(i) * 120, guid: "ep-\(i)")
        }
        check("podcast-feed", size: CGSize(width: 760, height: 420)) {
            PodcastFeedCard(model: model, title: "Example Show", feedURL: feed, episodes: episodes,
                            subscription: Subscription(feedURL: feed, title: "Example Show", autoTranscribe: true))
                .padding(20)
        }
    }

    func testOnboarding() {
        let model = makeModel()
        check("onboarding", size: CGSize(width: 680, height: 540)) { OnboardingView(model: model) }
    }

    func testPlayerBarWhileBrowsing() {
        let model = makeModel()
        var episode = SampleData.episode
        episode.id = "browsed"; episode.showName = "A different show"; episode.title = "A different episode"
        episode.artworkHue = 0.8; episode.duration = 7200
        model.open(EpisodeRecord(episode: episode, transcript: SampleData.transcript))
        // The transport must render exactly like its original baseline while another episode is viewed.
        check("player", size: CGSize(width: 1100, height: 80), testName: "testPlayerBar()") { PlayerBar(player: model.player) }
    }

    func testAskSettings() {
        let model = makeModel()
        let previous = model.askProvider, previousClaude = model.claudeExecutable
        defer { model.askProvider = previous; model.claudeExecutable = previousClaude }
        model.claudeExecutable = ""
        model.settingsPane = .ask
        for provider in ["local", "chatgpt", "claude"] {
            model.askProvider = provider
            check("ask-settings-\(provider)", size: CGSize(width: 900, height: 620)) { SettingsView(model: model) }
        }
    }

    func testPlayerBar() {
        let model = makeModel()
        check("player", size: CGSize(width: 1100, height: 80)) { PlayerBar(player: model.player) }
    }
}

// FocusState can only live in a View, so these wrappers own one for the panes that take a focus binding.
private struct TranscriptSnapshot: View {
    let model: AppModel
    @FocusState var focus: AppModel.FocusTarget?
    var body: some View { TranscriptView(model: model, focus: $focus).background(Palette.surface) }
}

private struct SummaryCardSnapshot: View {
    let model: AppModel
    @FocusState var focus: AppModel.FocusTarget?
    var body: some View { SummaryCard(model: model, focus: $focus).background(Palette.surface) }
}

private struct DetailSnapshot: View {
    let model: AppModel
    @FocusState var focus: AppModel.FocusTarget?
    var body: some View { DetailCard(model: model, focus: $focus).background(Palette.surface) }
}

private struct WorkspaceSnapshot: View {
    let model: AppModel
    @FocusState var focus: AppModel.FocusTarget?
    var body: some View { Workspace(model: model, focus: $focus) }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func anotherEpisode() -> EpisodeRecord {
        var episode = SampleData.episode
        episode.id = "another-episode"; episode.title = "Another episode"
        return EpisodeRecord(episode: episode, transcript: SampleData.transcript, chapters: SampleData.chapters)
    }

    func testBrowsingAndRefreshingDoNotReplaceOrPausePlayback() {
        let model = AppModel()
        let playing = model.player.episode
        model.player.seek(to: 42); model.player.rate = 1.5; model.player.volume = 0.4
        model.player.play()
        defer { model.player.pause() }
        let record = anotherEpisode()
        model.open(record)
        model.section = .home
        model.settingsPane = .general
        model.mergeLines = false
        model.install(record) // A refreshed transcript/summary must leave the transport alone too.
        XCTAssertEqual(model.episode.id, record.id)
        XCTAssertEqual(model.player.episode, playing)
        XCTAssertTrue(model.player.isPlaying)
        XCTAssertEqual(model.player.currentTime, 42)
        XCTAssertEqual(model.player.rate, 1.5)
        XCTAssertEqual(model.player.volume, 0.4)
        XCTAssertFalse(model.isViewedEpisodePlaying)
        XCTAssertNil(model.currentParagraphIndex)
        XCTAssertNil(model.currentChapterIndex)
    }

    func testExplicitPlaySwitchesEpisodeAndSameEpisodeResumes() {
        let model = AppModel()
        defer { model.player.pause() }
        model.player.jump(to: 42)
        let record = anotherEpisode()
        model.open(record)
        model.toggleEpisodePlayback()
        XCTAssertEqual(model.player.episode?.id, record.id)
        XCTAssertEqual(model.player.currentTime, 0)
        XCTAssertTrue(model.isViewedEpisodePlaying)
        model.player.seek(to: 25)
        model.toggleEpisodePlayback()
        XCTAssertFalse(model.player.isPlaying)
        model.open(record)
        model.toggleEpisodePlayback()
        XCTAssertEqual(model.player.currentTime, 25)
        XCTAssertTrue(model.isViewedEpisodePlaying)
        XCTAssertNotNil(model.currentParagraphIndex)
    }

    func testOpeningSearchLocationOnlyNavigatesTheTranscript() {
        let model = AppModel()
        model.player.jump(to: 42)
        defer { model.player.pause() }
        let playing = model.player.episode
        model.open(anotherEpisode(), at: 12)
        XCTAssertEqual(model.player.episode, playing)
        XCTAssertTrue(model.player.isPlaying)
        XCTAssertEqual(model.player.currentTime, 42)
        XCTAssertEqual(model.transcriptLocation?.time, 12)
        XCTAssertFalse(model.followPlayback)
    }

    func testTimestampExplicitlySwitchesToViewedEpisode() {
        let model = AppModel()
        defer { model.player.pause() }
        model.player.jump(to: 42)
        let record = anotherEpisode()
        model.open(record)
        model.play(from: 12)
        XCTAssertEqual(model.player.episode?.id, record.id)
        XCTAssertEqual(model.player.currentTime, 12)
        XCTAssertTrue(model.player.isPlaying)
    }

    func testReusingTransportDoesNotResetItsEpisodeOrPosition() {
        let original = AppModel()
        original.player.jump(to: 42)
        defer { original.player.pause() }
        let model = AppModel(player: original.player)
        XCTAssertTrue(model.player.isPlaying)
        XCTAssertEqual(model.player.currentTime, 42)
        XCTAssertEqual(model.player.episode, original.player.episode)
    }

    func testDownloadingViewedAudioDoesNotInterruptCurrentPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try Data("fixture".utf8).write(to: source)
        let model = AppModel()
        model.services = try WorkspaceServices(root: root)
        model.player.jump(to: 42)
        defer { model.player.pause() }
        let playing = model.player.episode
        for id in ["another-episode", playing!.id] {
            var record = anotherEpisode()
            record.episode.id = id
            record.episode.enclosureURL = source
            try model.services!.store.save(record)
            model.open(record)
            model.downloadAudio()
            for _ in 0..<100 {
                if model.episodeAudioURL != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(model.episodeAudioURL)
            XCTAssertEqual(model.player.episode, playing)
            XCTAssertTrue(model.player.isPlaying)
            XCTAssertGreaterThanOrEqual(model.player.currentTime, 42)
            XCTAssertNotNil(try model.services!.store.episode(record.id)?.audioURL)
        }
    }

    func testRenameAppliesEverywhereAndConfirms() {
        let model = AppModel()
        let id = SampleData.producer
        model.rename(id, to: "  Sam Okafor ")
        XCTAssertEqual(model.speaker(id).name, "Sam Okafor")
        XCTAssertTrue(model.speaker(id).isConfirmed)
        XCTAssertTrue(model.plainText().contains("Sam Okafor ["))
        model.rename(id, to: "   ")
        XCTAssertEqual(model.speaker(id).name, "Sam Okafor", "empty names are ignored")
    }

    func testAskReturnsOnlyTranscriptPassagesWithRealTimestamps() {
        let model = AppModel()
        model.ask("What happened with automation in 1988?")
        let answer = model.chat.last!
        XCTAssertEqual(answer.role, .assistant)
        XCTAssertFalse(answer.citations.isEmpty)
        let segments = SampleData.transcript.segments
        for c in answer.citations {
            let segment = segments.first { $0.start == c.start }
            XCTAssertNotNil(segment, "citation must point at a segment start")
            XCTAssertEqual(segment?.words.map(\.text).joined(separator: " "), c.quote)
        }
    }

    func testAskWithNoMatchSaysSo() {
        let model = AppModel()
        model.ask("zebras quantum")
        XCTAssertTrue(model.chat.last!.citations.isEmpty)
    }

    func testMergeToggleRebuildsParagraphs() {
        let model = AppModel()
        let merged = model.paragraphs.count
        model.mergeLines = false
        XCTAssertEqual(model.paragraphs.count, SampleData.transcript.segments.count)
        XCTAssertLessThan(merged, model.paragraphs.count)
    }
}

final class ContrastTests: XCTestCase {
    func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16 & 0xFF) + 0.7152 * channel(hex >> 8 & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testSpeakerColorsMeetAAOnSurfaceAndHighlight() {
        for pair in Palette.speakerHex {
            XCTAssertGreaterThanOrEqual(ratio(pair.light, 0xFFFFFF), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(pair.light, 0xE6F0EE), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(pair.dark, 0x1E2123), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(pair.dark, 0x203A3B), 4.5)
        }
    }
}
