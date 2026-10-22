import XCTest
import CryptoKit
@testable import Resolver

@MainActor
final class ResolutionTests: XCTestCase {
    let feedURL = url("https://example.org/feed.xml")
    let lookupURL = endpoint("https://itunes.apple.com/lookup", [("id", "123"), ("entity", "podcastEpisode"), ("limit", "200")])
    let spotifyID = "0123456789abcdefghijkl"

    func testAppleHappyPathAndShow() async throws {
        let fetcher = FixtureFetcher(files: [lookupURL: "lookup.json", feedURL: "podcasting.xml"])
        let resolver = Resolver(fetcher: fetcher)
        guard case .episode(let episode) = try await resolver.resolve("https://podcasts.apple.com/us/podcast/fiction/id123?i=101") else {
            return XCTFail("Expected episode")
        }
        XCTAssertEqual(episode.guid, "boat-1")
        XCTAssertEqual(episode.feedURL, feedURL)
        XCTAssertEqual(episode.enclosureURL, url("https://example.org/boat.mp3"))
        XCTAssertEqual(episode.source, .applePodcasts)
        guard case .show(let show) = try await resolver.resolve("https://itunes.apple.com/podcast/id123") else {
            return XCTFail("Expected show")
        }
        XCTAssertEqual(show.title, "Invented Workshop")
        XCTAssertEqual(show.episodes.count, 2)
        XCTAssertEqual(show.episodes.first?.guid, "boat-1")
        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(Resolution.self, from: encoder.encode(Resolution.show(show)))
        XCTAssertEqual(decoded, .show(show))
    }

    func testAppleEpisodeOutsideWindowDoesNotLookUpEpisodeID() async throws {
        let resolver = Resolver(fetcher: FixtureFetcher(files: [lookupURL: "lookup.json"]))
        do {
            _ = try await resolver.resolve("https://podcasts.apple.com/podcast/id123?i=999")
            XCTFail("Expected missing-window error")
        } catch let error as ResolverError {
            XCTAssertEqual(error, .appleEpisodeOutsideWindow)
            XCTAssertTrue(error.localizedDescription.contains("episode list"))
        }
    }

    func spotifyFetcher(page: String = "spotify.html") -> FixtureFetcher {
        let pageURL = url("https://open.spotify.com/episode/" + spotifyID)
        let embedURL = endpoint("https://open.spotify.com/oembed", [("url", pageURL.absoluteString)])
        let searchURL = endpoint("https://itunes.apple.com/search", [("term", "Paper Boats & Rain"), ("media", "podcast"), ("entity", "podcastEpisode"), ("limit", "25")])
        let showSearchURL = endpoint("https://itunes.apple.com/search", [("term", "Invented Workshop Paper Boats & Rain"), ("media", "podcast"), ("entity", "podcastEpisode"), ("limit", "25")])
        return FixtureFetcher(files: [pageURL: page, embedURL: "oembed.json", searchURL: "search.json",
                                     showSearchURL: "search.json", feedURL: "podcasting.xml"],
                              headers: [pageURL: ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"]])
    }

    func testSpotifyMetadataAndMatchedFeed() async throws {
        let fetcher = spotifyFetcher()
        let metadata = try await SpotifyResolver(fetcher: fetcher, search: AppleEpisodeSearch(fetcher: fetcher)).metadata(id: spotifyID)
        XCTAssertEqual(metadata.title, "Paper Boats & Rain")
        XCTAssertEqual(metadata.showTitle, "Invented Workshop")
        XCTAssertEqual(metadata.duration, 13410)
        XCTAssertEqual(metadata.pubDate, FeedValueParser.date("2026-09-17T00:42:00Z"))
        guard case .episode(let episode) = try await Resolver(fetcher: fetcher).resolve("spotify:episode:" + spotifyID) else {
            return XCTFail("Expected matched episode")
        }
        XCTAssertEqual(episode.source, .spotify(match: 1))
        XCTAssertEqual(episode.guid, "boat-1")
        XCTAssertEqual(episode.transcripts.count, 2)
    }

    func testSpotifyMissingPageMetadata() async throws {
        let fetcher = spotifyFetcher(page: "spotify-empty.html")
        let metadata = try await SpotifyResolver(fetcher: fetcher, search: AppleEpisodeSearch(fetcher: fetcher)).metadata(id: spotifyID)
        XCTAssertEqual(metadata.title, "Paper Boats & Rain")
        XCTAssertNil(metadata.showTitle)
        XCTAssertNil(metadata.duration)
        XCTAssertNil(metadata.pubDate)
        XCTAssertNotNil(metadata.artwork)
    }

    func testSpotifyConfirmationAndSelection() async throws {
        let metadata = SpotifyMetadata(title: "Paper Boats & Rain", showTitle: "Invented Workshop", duration: 13410)
        let candidate = EpisodeCandidate(title: metadata.title, showTitle: "Another Show", feedURL: feedURL,
                                         guid: "boat-1", duration: 13410)
        guard case .needsConfirmation(let choices) = SpotifyResolver.match(metadata, candidates: [candidate]) else {
            return XCTFail("Expected confirmation")
        }
        XCTAssertEqual(choices.count, 1)
        XCTAssertGreaterThanOrEqual(choices[0].confidence, 0.6)
        XCTAssertLessThan(choices[0].confidence, 0.85)
        let selected = try await Resolver(fetcher: FixtureFetcher(files: [feedURL: "podcasting.xml"])).resolve(choices[0])
        XCTAssertEqual(selected.guid, "boat-1")
        XCTAssertEqual(selected.source, .spotify(match: choices[0].confidence))
        let topFive = SpotifyResolver.match(metadata, candidates: Array(repeating: candidate, count: 7))
        guard case .needsConfirmation(let five) = topFive else { return XCTFail("Expected confirmation") }
        XCTAssertEqual(five.count, 5)
    }

    func testSpotifyExclusiveAndLowScore() {
        let metadata = SpotifyMetadata(title: "Paper Boats Rain", showTitle: "Invented Workshop", pubDate: Date(), duration: 13410)
        let exclusive = SpotifyResolver.match(metadata, candidates: [EpisodeCandidate(title: "Other Words", feedURL: feedURL)])
        XCTAssertEqual(exclusive, .notFound(reason: "This episode seems to be Spotify-exclusive, so wavepod can't get its audio."))
        let candidate = EpisodeCandidate(title: "Paper Boats Rain", showTitle: "Other Show", feedURL: feedURL,
                                         pubDate: .distantPast, duration: 1)
        guard case .notFound = SpotifyResolver.match(metadata, candidates: [candidate]) else { return XCTFail("Expected low-score result") }
    }

    func testMatchingSignalBoundariesAndNormalization() {
        let date = FeedValueParser.date("2026-09-17T00:42:00Z")!
        let metadata = SpotifyMetadata(title: "#502 – PÁPER Boats! 🛶", showTitle: "Workshop", pubDate: date, duration: 1000)
        var candidate = EpisodeCandidate(title: "Paper boats", showTitle: "Workshop", feedURL: feedURL, pubDate: date, duration: 1060)
        XCTAssertEqual(SpotifyResolver.score(metadata, candidate: candidate), 1, accuracy: 0.0001)
        candidate.pubDate = date.addingTimeInterval(86400)
        XCTAssertEqual(SpotifyResolver.score(metadata, candidate: candidate), 0.97, accuracy: 0.0001)
        candidate.pubDate = date.addingTimeInterval(7 * 86400)
        candidate.duration = 1600
        XCTAssertEqual(SpotifyResolver.score(metadata, candidate: candidate), 0.75, accuracy: 0.0001)
        XCTAssertEqual(TextNormalization.similarity("Episode 502: Folded Maps", "folded maps"), 1)
        XCTAssertEqual(TextNormalization.similarity("", ""), 0)
    }

    func testUnknownSniffDirectFilesAndPublishedContent() async throws {
        let mystery = url("https://example.org/mystery")
        let resolver = Resolver(fetcher: FixtureFetcher(files: [mystery: "podcasting.xml",
             url("https://example.org/transcript.json"): "transcript.json"]))
        guard case .show(let show) = try await resolver.resolve(mystery.absoluteString) else { return XCTFail("Expected sniffed feed") }
        XCTAssertEqual(show.feedURL, mystery)
        let transcript = try await resolver.transcript(show.episodes[0].transcripts[0])
        XCTAssertTrue(transcript.hasTimings)
        guard case .episode(let file) = try await resolver.resolve("https://example.org/local.mp3") else { return XCTFail("Expected file") }
        XCTAssertEqual(file.source, .file)
        XCTAssertNil(file.feedURL)
    }

    func testFixtureFetcherRejectsUnmappedURLsAndHTTPFailures() async throws {
        let fetcher = FixtureFetcher(files: [:], reportsUnexpectedTraffic: false)
        do {
            _ = try await fetcher.get(url("https://unmapped.example/"), headers: [:])
            XCTFail("Unexpected traffic must fail")
        } catch is FixtureFetcher.UnexpectedURL { }
        var failed = FixtureFetcher(files: [feedURL: "podcasting.xml"])
        failed.status = 503
        do {
            _ = try await Resolver(fetcher: failed).resolve(feedURL.absoluteString)
            XCTFail("Expected HTTP error")
        } catch let error as ResolverError { XCTAssertEqual(error, .httpStatus(503)) }
    }

    func testWebsiteDiscoversRelativeRSSAndSkipsAtom() async throws {
        let pageURL = url("https://example.org/shows/workshop")
        let discoveredURL = url("https://example.org/feed.xml?source=website&format=rss")
        let resolver = Resolver(fetcher: FixtureFetcher(files: [pageURL: "website.html", discoveredURL: "podcasting.xml"]))
        guard case .show(let show) = try await resolver.resolve(pageURL.absoluteString) else {
            return XCTFail("Expected discovered RSS feed")
        }
        XCTAssertEqual(show.feedURL, discoveredURL)
        XCTAssertEqual(show.title, "Invented Workshop")
        XCTAssertEqual(show.episodes.count, 2)
    }

    func testWebsiteWithoutRSSIsUnsupported() async throws {
        let pageURL = url("https://example.org/workshop")
        for file in ["website-atom.html", "spotify-empty.html"] {
            let resolver = Resolver(fetcher: FixtureFetcher(files: [pageURL: file]))
            do {
                _ = try await resolver.resolve(pageURL.absoluteString)
                XCTFail("Expected unsupported website")
            } catch let error as ResolverError {
                XCTAssertEqual(error, .unsupportedLink)
                XCTAssertEqual(error.localizedDescription, "This page doesn't link to a podcast feed.")
            }
        }
    }

    func testAppleSearchUsesShowTitleWithoutFallbackForCloseCandidate() async throws {
        let searchURL = endpoint("https://itunes.apple.com/search", [("term", "Invented Workshop Paper Boats & Rain"),
                                 ("media", "podcast"), ("entity", "podcastEpisode"), ("limit", "25")])
        // Only the combined query is mapped: an unnecessary title-only fallback fails the test.
        let search = AppleEpisodeSearch(fetcher: FixtureFetcher(files: [searchURL: "search.json"]))
        let candidates = try await search.search(title: "Paper Boats & Rain", showTitle: "Invented Workshop")
        XCTAssertEqual(candidates.first?.guid, "boat-1")
        XCTAssertEqual(candidates.first?.showTitle, "Invented Workshop")
    }

    func testAppleSearchFallsBackWhenCombinedQueryHasNoCloseTitle() async throws {
        let combinedURL = endpoint("https://itunes.apple.com/search", [("term", "Invented Workshop Paper Boats & Rain"),
                                   ("media", "podcast"), ("entity", "podcastEpisode"), ("limit", "25")])
        let titleURL = endpoint("https://itunes.apple.com/search", [("term", "Paper Boats & Rain"),
                                ("media", "podcast"), ("entity", "podcastEpisode"), ("limit", "25")])
        for file in ["search-near-miss.json", "search-empty.json"] {
            let search = AppleEpisodeSearch(fetcher: FixtureFetcher(files: [combinedURL: file, titleURL: "search.json"]))
            let candidates = try await search.search(title: "Paper Boats & Rain", showTitle: "Invented Workshop")
            XCTAssertEqual(candidates.first?.title, "Paper Boats & Rain")
            XCTAssertEqual(candidates.count, 3)
        }
    }

    func testPodcastIndexAuthenticationAndCandidates() async throws {
        let date = "1792281600"
        let auth = Insecure.SHA1.hash(data: Data(("key" + "secret" + date).utf8)).map { String(format: "%02x", $0) }.joined()
        let searchURL = endpoint("https://api.podcastindex.org/api/1.0/search/byterm", [("q", "Paper Boats")])
        let episodesURL = endpoint("https://api.podcastindex.org/api/1.0/episodes/byfeedid", [("id", "42"), ("max", "100")])
        let headers = ["X-Auth-Date": date, "X-Auth-Key": "key", "Authorization": auth, "User-Agent": "wavepod-test"]
        let fetcher = FixtureFetcher(files: [searchURL: "index-feeds.json", episodesURL: "index-episodes.json"],
                                     headers: [searchURL: headers, episodesURL: headers])
        let search = PodcastIndexSearch(fetcher: fetcher, key: "key", secret: "secret", userAgent: "wavepod-test",
                                        now: { Date(timeIntervalSince1970: 1792281600) })
        let candidates = try await search.search(title: "An episode title", showTitle: "Paper Boats")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].guid, "boat-1")
        XCTAssertEqual(candidates[0].feedURL, feedURL)
    }
}
