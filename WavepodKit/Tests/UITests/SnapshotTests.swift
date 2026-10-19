import AppKit
import Library
import SnapshotTesting
import SwiftUI
import XCTest
@testable import UI

/// Every main view in light and dark, plus the transcript at a large text size.
/// Record new references with `SNAPSHOT_RECORD=1 swift test`.
@MainActor
final class SnapshotTests: XCTestCase {
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
                PlayerBar(model: model, player: model.player)
            }
        }
    }

    func testSidebar() {
        let model = makeModel()
        check("sidebar", size: CGSize(width: 220, height: 420)) { SidebarView(model: model) }
    }

    func testEpisodePane() {
        let model = makeModel()
        check("episode", size: CGSize(width: 300, height: 720)) { EpisodePane(model: model).padding(6) }
    }

    func testTranscript() {
        let model = makeModel()
        check("transcript", size: CGSize(width: 600, height: 700)) { CenterPaneSnapshot(model: model).padding(6) }
    }

    func testTranscriptLargeText() {
        let model = makeModel()
        check("transcript-large", size: CGSize(width: 600, height: 700), scale: 1.5) {
            CenterPaneSnapshot(model: model).padding(6)
        }
    }

    func testSummary() {
        let model = makeModel()
        model.centerTab = .summary
        check("summary", size: CGSize(width: 600, height: 700)) { CenterPaneSnapshot(model: model).padding(6) }
    }

    func testChapters() {
        let model = makeModel()
        model.centerTab = .chapters
        check("chapters", size: CGSize(width: 600, height: 500)) { CenterPaneSnapshot(model: model).padding(6) }
    }

    func testAskPane() {
        let model = makeModel()
        check("ask", size: CGSize(width: 330, height: 700)) { AskPaneSnapshot(model: model).padding(6) }
    }

    func testAskSettings() {
        let model = makeModel()
        let previous = model.askProvider
        defer { model.askProvider = previous }
        model.settingsPane = .ask
        for provider in ["local", "chatgpt"] {
            model.askProvider = provider
            check("ask-settings-\(provider)", size: CGSize(width: 900, height: 620)) { SettingsView(model: model) }
        }
    }

    func testPlayerBar() {
        let model = makeModel()
        check("player", size: CGSize(width: 1100, height: 80)) { PlayerBar(model: model, player: model.player) }
    }
}

// FocusState can only live in a View, so these wrappers own one for the panes that take a focus binding.
private struct CenterPaneSnapshot: View {
    let model: AppModel
    @FocusState var focus: AppModel.FocusTarget?
    var body: some View { CenterPane(model: model, focus: $focus) }
}

private struct AskPaneSnapshot: View {
    let model: AppModel
    @FocusState var focus: AppModel.FocusTarget?
    var body: some View { AskPane(model: model, focus: $focus) }
}

private struct WorkspaceSnapshot: View {
    let model: AppModel
    @FocusState var focus: AppModel.FocusTarget?
    var body: some View { Workspace(model: model, focus: $focus) }
}

@MainActor
final class AppModelTests: XCTestCase {
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
