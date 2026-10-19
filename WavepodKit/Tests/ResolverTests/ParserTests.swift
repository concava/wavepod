import XCTest
@testable import Resolver

final class ParserTests: XCTestCase {
    let feedURL = url("https://example.org/feed.xml")

    func testPodcastingNamespaceAndFallbacks() throws {
        let feed = try RSSParser.parse(fixture("podcasting.xml"), feedURL: feedURL)
        XCTAssertEqual(feed.title, "Invented Workshop")
        XCTAssertEqual(feed.guid, "invented-show")
        XCTAssertEqual(feed.language, "ca")
        XCTAssertEqual(feed.episodes.count, 2)
        XCTAssertEqual(feed.episodeLinks, [url("https://example.org/boat"), nil])
        let first = feed.episodes[0]
        XCTAssertEqual(first.title, "Paper Boats & Rain")
        XCTAssertEqual(first.persons.first?.name, "Bo")
        XCTAssertEqual(first.persons.first?.role, "guest")
        XCTAssertEqual(first.persons.first?.group, "cast")
        XCTAssertEqual(first.persons.first?.img, url("https://example.org/guest.jpg"))
        XCTAssertEqual(first.persons.first?.href, url("https://example.org/guest"))
        XCTAssertEqual(feed.episodes[1].persons.first?.name, "Ari")
        XCTAssertEqual(first.artwork, feed.artwork)
        XCTAssertEqual(first.duration, 13410)
        XCTAssertEqual(first.descriptionHTML, "<p>An invented conversation.</p>")
        XCTAssertEqual(first.transcripts.count, 2)
        XCTAssertEqual(first.transcripts[0].language, "ca")
        XCTAssertEqual(first.chaptersURL, url("https://example.org/chapters.json"))
        XCTAssertEqual(feed.episode(guid: "boat-1"), first)
        XCTAssertEqual(feed.episode(guid: "missing", enclosureURL: first.enclosureURL), first)
        XCTAssertEqual(feed.episode(title: "#502 – PÁPER boats & rain", date: first.pubDate), first)
        XCTAssertNil(feed.episode(title: first.title, date: .distantPast))
        XCTAssertEqual(TranscriptLink.preferred(first.transcripts).count, 1)
    }

    func testLegacyPodcastNamespace() throws {
        let feed = try RSSParser.parse(fixture("podcasting-legacy.xml"), feedURL: feedURL)
        XCTAssertEqual(feed.guid, "legacy-show")
        XCTAssertEqual(feed.persons.first?.name, "Ari")
        let episode = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(episode.guid, "kite-1")
        XCTAssertEqual(episode.persons, [Person(name: "Bo", role: "guest", group: "cast", href: url("https://example.org/bo"))])
        XCTAssertEqual(episode.transcripts, [TranscriptLink(url: url("https://example.org/kite.json"), type: "application/json", language: "en")])
        XCTAssertEqual(episode.chaptersURL, url("https://example.org/kite-chapters.json"))
    }

    func testItunesAndNamespaceSpoofing() throws {
        let feed = try RSSParser.parse(fixture("itunes.xml"), feedURL: feedURL)
        XCTAssertEqual(feed.language, "en")
        XCTAssertEqual(feed.episodes[0].duration, 750)
        XCTAssertEqual(feed.artwork, url("https://example.org/tools.jpg"))
        XCTAssertEqual(feed.episodes[0].artwork, url("https://example.org/ruler.jpg"))
        let xml = #"<rss xmlns:itunes="https://wrong.example"><channel><title>A</title><item><title>B</title><itunes:duration>5</itunes:duration></item></channel></rss>"#
        XCTAssertNil(try RSSParser.parse(Data(xml.utf8), feedURL: feedURL).episodes[0].duration)
        for xml in ["<html><body>not a feed</body></html>", "<rss>", "<rss/>"] {
            XCTAssertThrowsError(try RSSParser.parse(Data(xml.utf8), feedURL: feedURL))
        }
    }

    func testDatesAndDurations() throws {
        let feed = try RSSParser.parse(fixture("odd.xml"), feedURL: feedURL)
        XCTAssertEqual(feed.episodes.map(\.duration), [3723, 123, 123, 123.5, 62.5])
        XCTAssertNotNil(feed.episodes[0].pubDate)
        XCTAssertNotNil(feed.episodes[1].pubDate)
        XCTAssertNotNil(feed.episodes[2].pubDate)
        XCTAssertNil(feed.episodes[3].pubDate)
        XCTAssertNotNil(feed.episodes[4].pubDate)
        for zone in ["GMT", "UT", "EST", "EDT", "CST", "CDT", "MST", "MDT", "PST", "PDT", "+0230", "-0700"] {
            for prefix in ["Thu, ", ""] {
                for time in ["12:34:56", "12:34"] {
                    XCTAssertNotNil(FeedValueParser.date("\(prefix)17 Sep 2026 \(time) \(zone)"))
                }
            }
        }
        for value in ["-1", "NaN", "inf", "1:bad", "1::2", "1:2:3:4"] { XCTAssertNil(FeedValueParser.duration(value)) }
        XCTAssertEqual(FeedValueParser.duration("1:02:03.5"), 3723.5)
    }

    func testPublishedTranscriptsAndChapters() throws {
        for (file, type) in [("transcript.json", "application/json"), ("transcript.srt", "application/x-subrip"), ("transcript.vtt", "text/vtt")] {
            let transcript = try PublishedContentParser.transcript(fixture(file), type: type)
            XCTAssertTrue(transcript.hasTimings)
            XCTAssertEqual(transcript.cues.count, 2)
            XCTAssertEqual(transcript.cues[0].start, 0)
            XCTAssertEqual(transcript.cues[0].end, 2.5)
            XCTAssertEqual(transcript.cues[0].text, "Fold this corner.")
            if file != "transcript.srt" { XCTAssertEqual(transcript.cues[0].speaker, "Ari") }
        }
        for (file, type) in [("plain.txt", "text/plain"), ("transcript.html", "text/html")] {
            let transcript = try PublishedContentParser.transcript(fixture(file), type: type)
            XCTAssertFalse(transcript.hasTimings)
            XCTAssertEqual(transcript.cues.count, 1)
            XCTAssertNil(transcript.cues[0].start)
            XCTAssertFalse(transcript.cues[0].text.contains("<p>"))
        }
        let chapters = try PublishedContentParser.chapters(fixture("chapters.json"))
        XCTAssertEqual(chapters.map(\.title), ["First Fold", "Launch"])
        XCTAssertEqual(chapters[0].url, url("https://example.org/fold"))
        XCTAssertEqual(chapters[0].img, url("https://example.org/fold.jpg"))
        XCTAssertEqual(chapters[1].start, 5)
    }

    func testTranscriptPreference() {
        let types = ["text/html", "application/srt", "text/vtt", "application/json"]
        let links = types.map { TranscriptLink(url: feedURL, type: $0) }
        XCTAssertEqual(TranscriptLink.preferred(links).map(\.type), types.reversed())
        let captions = TranscriptLink(url: feedURL, type: "text/vtt", rel: "captions")
        XCTAssertEqual(TranscriptLink.preferred([captions]), [captions])
        XCTAssertEqual(TranscriptLink.preferred([links[0], captions]), [captions, links[0]])
    }
}
