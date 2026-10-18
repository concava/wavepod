import XCTest
@testable import Library

final class TimecodeTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(Timecode.format(0), "00:00")
        XCTAssertEqual(Timecode.format(247.9), "04:07")
        XCTAssertEqual(Timecode.format(3723), "1:02:03")
        XCTAssertEqual(Timecode.format(-5), "00:00")
    }
}

final class TranscriptTests: XCTestCase {
    let a = SpeakerID("A"), b = SpeakerID("B")

    func segment(_ id: Int, _ speaker: SpeakerID, _ start: Double, _ end: Double) -> Segment {
        Segment(id: id, speaker: speaker, words: [Word(text: "w\(id)", start: start, end: end)])
    }

    func testMergeJoinsSameSpeakerAndBreaksOnSpeakerOrPause() {
        let t = Transcript(language: "en", segments: [
            segment(0, a, 0, 1), segment(1, a, 1.2, 2),  // same speaker, short gap: merge
            segment(2, a, 4, 5),                         // 2 s pause: new paragraph
            segment(3, b, 5.1, 6),                       // speaker change
        ])
        XCTAssertEqual(t.paragraphs(merge: true).map(\.segments.count), [2, 1, 1])
        XCTAssertEqual(t.paragraphs(merge: false).count, 4)
    }

    func testParagraphIndexAtTime() {
        let paragraphs = Transcript(language: "en", segments: [
            segment(0, a, 0, 1), segment(1, b, 2, 3), segment(2, a, 4, 5),
        ]).paragraphs(merge: true)
        XCTAssertNil(paragraphs.index(at: -1))
        XCTAssertEqual(paragraphs.index(at: 0.5), 0)
        XCTAssertEqual(paragraphs.index(at: 2), 1)
        XCTAssertEqual(paragraphs.index(at: 3.5), 1)  // in a gap: the last paragraph that started
        XCTAssertEqual(paragraphs.index(at: 99), 2)
    }

    func testSampleTimestampsAreOrdered() {
        let words = SampleData.transcript.segments.flatMap(\.words)
        XCTAssertFalse(words.isEmpty)
        for (x, y) in zip(words, words.dropFirst()) {
            XCTAssertLessThan(x.start, x.end)
            XCTAssertLessThanOrEqual(x.end, y.start)
        }
        // Every summary and chapter timestamp points at the start of a real segment.
        let starts = Set(SampleData.transcript.segments.map(\.start))
        for t in SampleData.chapters.map(\.start) + SampleData.summary.points.map(\.citation.start) {
            XCTAssertTrue(t == 0 || starts.contains(t), "\(t) is not a segment start")
        }
    }
}

final class SafeHTMLTests: XCTestCase {
    func text(_ html: String) -> String { String(SafeHTML.render(html).characters) }

    func testDropsScriptsStylesAndUnknownTags() {
        XCTAssertEqual(text("<p>Hi <span onclick='x()'>there</span></p><script>alert(1)</script><style>p{}</style>"),
                       "Hi there")
        XCTAssertEqual(text("<iframe src='https://evil'>inside</iframe>ok"), "ok")
    }

    func testParagraphsListsAndEntities() {
        XCTAssertEqual(text("<p>One</p><p>Two &amp; three</p><ul><li>a</li><li>b</li></ul>"),
                       "One\n\nTwo & three\n\n• a\n• b")
        XCTAssertEqual(text("caf&#233; &#x2014; &lt;b&gt;"), "café — <b>")
    }

    func testWhitespaceBetweenBlocksAddsNoBlankLines() {
        XCTAssertEqual(text("<p>One</p>\n  <ul>\n<li>a</li>\n<li>b</li></ul>\n<p>Two</p>\n<script>x</script>\n"),
                       "One\n\n• a\n• b\n\nTwo")
    }

    func testOnlyHTTPLinksSurvive() {
        let rendered = SafeHTML.render("<a href=\"javascript:alert(1)\">bad</a> <a href='https://ok.example/x'>good</a>")
        let links = rendered.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://ok.example/x")!])
    }

    func testFormatting() {
        let rendered = SafeHTML.render("<b>bold</b> <i>it</i>")
        let intents = rendered.runs.compactMap(\.inlinePresentationIntent)
        XCTAssertEqual(intents, [.stronglyEmphasized, .emphasized])
    }

    func testUnclosedAngleBracketIsText() {
        XCTAssertEqual(text("a < b"), "a < b")
    }
}

final class ExportTests: XCTestCase {
    func render(_ f: ExportFormat) throws -> String {
        String(decoding: try TranscriptExport.render(f, episode: SampleData.episode, transcript: SampleData.transcript,
                                                     speakers: SampleData.speakers), as: UTF8.self)
    }

    func testStamps() {
        XCTAssertEqual(TranscriptExport.stamp(3723.4567, ","), "01:02:03,457")
        XCTAssertEqual(TranscriptExport.stamp(0, "."), "00:00:00.000")
    }

    func testSRTAndVTTUseSpeakerNames() throws {
        let srt = try render(.srt)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:02,000 --> "))
        XCTAssertTrue(srt.contains("Marta Vidal: This is Low Tide"))
        let vtt = try render(.vtt)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("<v Jordi Serra>"))
    }

    func testRenameShowsUpInExports() throws {
        var speakers = SampleData.speakers
        speakers[SampleData.producer]?.name = "Sam Okafor"
        let md = String(decoding: try TranscriptExport.render(.markdown, episode: SampleData.episode,
                                                             transcript: SampleData.transcript, speakers: speakers),
                        as: UTF8.self)
        XCTAssertTrue(md.contains("**Sam Okafor**"))
        XCTAssertFalse(md.contains("Speaker 3"))
    }

    func testJSONRoundTripsWordCount() throws {
        let data = try TranscriptExport.render(.json, episode: SampleData.episode,
                                               transcript: SampleData.transcript, speakers: SampleData.speakers)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let segments = object["segments"] as! [[String: Any]]
        let words = segments.flatMap { $0["words"] as! [[String: Any]] }
        XCTAssertEqual(words.count, SampleData.transcript.segments.flatMap(\.words).count)
    }

    func testDOCXIsNotSilentlyFaked() {
        XCTAssertThrowsError(try render(.docx))
    }
}
