import Foundation

public struct Person: Sendable, Hashable, Codable {
    public var name: String
    public var role: String?
    public var group: String?
    public var img: URL?
    public var href: URL?

    public init(name: String, role: String? = nil, group: String? = nil, img: URL? = nil, href: URL? = nil) {
        self.name = name
        self.role = role
        self.group = group
        self.img = img
        self.href = href
    }
}

public struct TranscriptLink: Sendable, Hashable, Codable {
    public var url: URL
    public var type: String
    public var language: String?
    public var rel: String?

    public init(url: URL, type: String, language: String? = nil, rel: String? = nil) {
        self.url = url
        self.type = type
        self.language = language
        self.rel = rel
    }

    var rank: Int {
        let type = type.lowercased()
        if type.contains("json") { return 0 }
        if type.contains("vtt") { return 1 }
        if type.contains("srt") || type.contains("subrip") { return 2 }
        return 3
    }

    /// Prefer timed formats; captions remain available when no better transcript exists.
    public static func preferred(_ links: [Self]) -> [Self] {
        links.enumerated().filter { _, link in
            link.rel?.lowercased() != "captions" || !links.contains { $0.rank < link.rank }
        }.sorted { a, b in a.element.rank == b.element.rank ? a.offset < b.offset : a.element.rank < b.element.rank }
            .map(\.element)
    }
}

public enum Source: Sendable, Hashable, Codable {
    case rss, applePodcasts, spotify(match: Double), youtube, file
}

public struct ResolvedEpisode: Sendable, Hashable, Codable {
    public var feedURL: URL?
    public var enclosureURL: URL?
    public var title: String
    public var showTitle: String?
    public var pubDate: Date?
    public var duration: TimeInterval?
    public var guid: String?
    public var artwork: URL?
    public var descriptionHTML: String?
    public var language: String?
    public var persons: [Person]
    public var transcripts: [TranscriptLink]
    public var source: Source

    public init(title: String, feedURL: URL? = nil, enclosureURL: URL? = nil, showTitle: String? = nil,
                pubDate: Date? = nil, duration: TimeInterval? = nil, guid: String? = nil, artwork: URL? = nil,
                descriptionHTML: String? = nil, language: String? = nil, persons: [Person] = [],
                transcripts: [TranscriptLink] = [], source: Source = .rss) {
        self.title = title
        self.feedURL = feedURL
        self.enclosureURL = enclosureURL
        self.showTitle = showTitle
        self.pubDate = pubDate
        self.duration = duration
        self.guid = guid
        self.artwork = artwork
        self.descriptionHTML = descriptionHTML
        self.language = language
        self.persons = persons
        self.transcripts = transcripts
        self.source = source
    }
}

public struct ResolvedShow: Sendable, Hashable, Codable {
    public var feedURL: URL
    public var title: String
    public var artwork: URL?
    public var episodes: [ResolvedEpisode]
}

public struct ScoredCandidate: Sendable, Hashable, Codable {
    public var candidate: EpisodeCandidate
    public var confidence: Double
}

public enum Resolution: Sendable, Hashable, Codable {
    case episode(ResolvedEpisode)
    case show(ResolvedShow)
    case needsConfirmation([ScoredCandidate])
    case notFound(reason: String)
}

public enum ResolverError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedLink, invalidFeed, episodeNotFound, appleEpisodeOutsideWindow, invalidResponse
    case networkUnavailable
    case httpStatus(Int), extractorUnavailable, processFailed, checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedLink: "This page doesn't link to a podcast feed."
        case .invalidFeed: "This feed couldn’t be read. Try another link from the show."
        case .episodeNotFound: "This episode wasn’t found in the show’s feed."
        case .appleEpisodeOutsideWindow: "This episode is outside Apple’s latest 200 results. Pick it from the show’s episode list."
        case .networkUnavailable: "The request couldn’t connect. Check your connection and try again."
        case .invalidResponse: "The service returned a response wavepod couldn’t read."
        case .httpStatus(let code): "The request couldn’t finish (HTTP \(code)). Try again later."
        case .extractorUnavailable: "Install yt-dlp to read this YouTube link."
        case .processFailed: "yt-dlp couldn’t read this video. Try again later."
        case .checksumMismatch: "The yt-dlp download didn’t pass verification. Please try again."
        }
    }
}
