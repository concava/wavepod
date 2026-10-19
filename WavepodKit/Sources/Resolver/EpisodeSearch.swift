import Foundation
import CryptoKit

public struct EpisodeCandidate: Sendable, Hashable, Codable {
    public var title: String
    public var showTitle: String?
    public var feedURL: URL
    public var guid: String?
    public var enclosureURL: URL?
    public var pubDate: Date?
    public var duration: TimeInterval?

    public init(title: String, showTitle: String? = nil, feedURL: URL, guid: String? = nil,
                enclosureURL: URL? = nil, pubDate: Date? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.showTitle = showTitle
        self.feedURL = feedURL
        self.guid = guid
        self.enclosureURL = enclosureURL
        self.pubDate = pubDate
        self.duration = duration
    }
}

public protocol EpisodeSearch: Sendable {
    func search(title: String) async throws -> [EpisodeCandidate]
    func search(title: String, showTitle: String?) async throws -> [EpisodeCandidate]
}

extension EpisodeSearch {
    public func search(title: String, showTitle: String?) async throws -> [EpisodeCandidate] {
        try await search(title: title)
    }
}

struct AppleResults: Decodable {
    var results: [AppleTrack]
}

struct AppleTrack: Decodable {
    var wrapperType: String?
    var kind: String?
    var trackId: Int64?
    var episodeGuid: String?
    var trackName: String?
    var collectionName: String?
    var feedUrl: URL?
    var artworkUrl600: URL?
    var releaseDate: String?
    var trackTimeMillis: Double?
    var episodeUrl: URL?

    var candidate: EpisodeCandidate? {
        guard let trackName, let feedUrl else { return nil }
        return EpisodeCandidate(title: trackName, showTitle: collectionName, feedURL: feedUrl,
                                guid: episodeGuid, enclosureURL: episodeUrl,
                                pubDate: releaseDate.flatMap(FeedValueParser.date), duration: trackTimeMillis.map { $0 / 1000 })
    }
}

public struct AppleEpisodeSearch: EpisodeSearch {
    let fetcher: any HTTPFetching
    public init(fetcher: any HTTPFetching) { self.fetcher = fetcher }

    public func search(title: String, showTitle: String?) async throws -> [EpisodeCandidate] {
        if let showTitle, !showTitle.isEmpty {
            let candidates = try await search(title: "\(showTitle) \(title)")
            if candidates.contains(where: { TextNormalization.similarity(title, $0.title) > 0.5 }) {
                return candidates
            }
        }
        return try await search(title: title)
    }

    public func search(title: String) async throws -> [EpisodeCandidate] {
        let url = endpoint("https://itunes.apple.com/search", [("term", title), ("media", "podcast"),
                           ("entity", "podcastEpisode"), ("limit", "25")])
        let data = try await fetcher.data(url)
        return try decodeResponse(AppleResults.self, from: data).results.compactMap(\.candidate)
    }
}

/// Created only when the caller supplies credentials. No credentials are stored on disk.
public struct PodcastIndexSearch: EpisodeSearch {
    let fetcher: any HTTPFetching
    let key: String
    let secret: String
    let userAgent: String
    let now: @Sendable () -> Date

    public init(fetcher: any HTTPFetching, key: String, secret: String, userAgent: String = "wavepod/1",
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.key = key
        self.secret = secret
        self.userAgent = userAgent
        self.now = now
    }

    public func search(title: String) async throws -> [EpisodeCandidate] {
        try await search(title: title, showTitle: nil)
    }

    public func search(title: String, showTitle: String?) async throws -> [EpisodeCandidate] {
        // Podcast Index searches feeds, then lists their episodes. Use the show name when available.
        // API: https://podcastindex-org.github.io/docs-api/
        let term = showTitle.flatMap { $0.isEmpty ? nil : $0 } ?? title
        let date = String(Int(now().timeIntervalSince1970))
        let auth = Insecure.SHA1.hash(data: Data((key + secret + date).utf8)).map { String(format: "%02x", $0) }.joined()
        let url = endpoint("https://api.podcastindex.org/api/1.0/search/byterm", [("q", term)])
        let data = try await fetcher.data(url, headers: ["X-Auth-Date": date, "X-Auth-Key": key,
                                                       "Authorization": auth, "User-Agent": userAgent])
        let feeds = try decodeResponse(IndexFeeds.self, from: data).feeds
        var candidates: [EpisodeCandidate] = []
        for feed in feeds.prefix(5) {
            let url = endpoint("https://api.podcastindex.org/api/1.0/episodes/byfeedid", [("id", String(feed.id)), ("max", "100")])
            let data = try await fetcher.data(url, headers: ["X-Auth-Date": date, "X-Auth-Key": key,
                                                           "Authorization": auth, "User-Agent": userAgent])
            let items = try decodeResponse(IndexEpisodes.self, from: data).items
            candidates += items.map { EpisodeCandidate(title: $0.title, showTitle: feed.title, feedURL: feed.url,
                                                       guid: $0.guid, enclosureURL: $0.enclosureUrl,
                                                       pubDate: $0.datePublished.map(Date.init(timeIntervalSince1970:)), duration: $0.duration) }
        }
        return candidates
    }

    private struct IndexFeeds: Decodable {
        struct Feed: Decodable {
            var id: Int
            var title: String
            var url: URL
        }
        var feeds: [Feed]
    }
    private struct IndexEpisodes: Decodable {
        struct Item: Decodable {
            var title: String
            var guid: String?
            var enclosureUrl: URL?
            var datePublished: Double?
            var duration: Double?
        }
        var items: [Item]
    }
}
