import Foundation

public struct Resolver: Sendable {
    let fetcher: any HTTPFetching
    let search: any EpisodeSearch
    let extractor: (any MediaExtractor)?

    public init(fetcher: any HTTPFetching, search: (any EpisodeSearch)? = nil, extractor: (any MediaExtractor)? = nil) {
        self.fetcher = fetcher
        self.search = search ?? AppleEpisodeSearch(fetcher: fetcher)
        self.extractor = extractor
    }

    public func resolve(_ input: String) async throws -> Resolution {
        do { return try await route(input) }
        catch let error as ResolverError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw ResolverError.networkUnavailable
        }
        catch { throw ResolverError.invalidResponse }
    }

    private func route(_ input: String) async throws -> Resolution {
        switch LinkClassifier.classify(input) {
        case .rss(let url): return .show(show(try await websiteOrFeed(url), source: .rss))
        case .audioFile(let url): return .episode(ResolvedEpisode(title: url.deletingPathExtension().lastPathComponent,
                                                                enclosureURL: url, source: .file))
        case .applePodcasts(let showID, let episodeID): return try await apple(showID: showID, episodeID: episodeID)
        case .spotify(let kind, let id):
            guard kind == .episode else {
                return .notFound(reason: "Paste a Spotify episode link to find its public podcast feed.")
            }
            switch try await SpotifyResolver(fetcher: fetcher, search: search).match(id: id) {
            case .matched(let candidate, let confidence):
                return .episode(try await resolve(candidate, source: .spotify(match: confidence)))
            case .needsConfirmation(let candidates): return .needsConfirmation(candidates)
            case .notFound(let reason): return .notFound(reason: reason)
            }
        case .youtube(let id):
            guard let extractor else { throw ResolverError.extractorUnavailable }
            return .episode(try await extractor.extract(URL(string: "https://www.youtube.com/watch?v=\(id)")!))
        case .unknown: throw ResolverError.unsupportedLink
        }
    }

    /// Called after the user chooses a Spotify match.
    public func resolve(_ selection: ScoredCandidate) async throws -> ResolvedEpisode {
        try await resolve(selection.candidate, source: .spotify(match: selection.confidence))
    }

    public func transcript(_ link: TranscriptLink) async throws -> ImportedTranscript {
        try PublishedContentParser.transcript(await fetcher.data(link.url), type: link.type)
    }

    public func chapters(_ url: URL) async throws -> [ImportedChapter] {
        try PublishedContentParser.chapters(await fetcher.data(url))
    }

    private func websiteOrFeed(_ url: URL) async throws -> RSSFeed {
        let (data, response) = try await fetcher.get(url, headers: [:])
        guard (200..<300).contains(response.statusCode) else { throw ResolverError.httpStatus(response.statusCode) }
        let text = String(decoding: data, as: UTF8.self)
        let isHTML = response.mimeType?.lowercased() == "text/html" ||
            text.range(of: #"^\s*(?:<!doctype\s+html\b|<html\b)"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard isHTML else { return try RSSParser.parse(data, feedURL: url) }
        let pageURL = response.url ?? url
        guard let feedURL = MetadataHTML.rssAlternate(in: text, pageURL: pageURL) else { throw ResolverError.unsupportedLink }
        return try await feed(feedURL)
    }

    func feed(_ url: URL) async throws -> RSSFeed { try RSSParser.parse(await fetcher.data(url), feedURL: url) }

    func resolve(_ candidate: EpisodeCandidate, source: Source) async throws -> ResolvedEpisode {
        let feed = try await feed(candidate.feedURL)
        guard var episode = feed.episode(guid: candidate.guid, enclosureURL: candidate.enclosureURL,
                                         title: candidate.title, date: candidate.pubDate) else { throw ResolverError.episodeNotFound }
        episode.source = source
        return episode
    }

    func apple(showID: String, episodeID: String?) async throws -> Resolution {
        let url = endpoint("https://itunes.apple.com/lookup", [("id", showID), ("entity", "podcastEpisode"), ("limit", "200")])
        let data = try await fetcher.data(url)
        let tracks = try decodeResponse(AppleResults.self, from: data).results
        guard let track = tracks.first(where: { $0.kind == "podcast" }), let feedURL = track.feedUrl else {
            throw ResolverError.invalidResponse
        }
        guard let episodeID else {
            var result = show(try await feed(feedURL), source: .applePodcasts)
            result.artwork = result.artwork ?? track.artworkUrl600
            return .show(result)
        }
        guard let episodeTrack = tracks.first(where: { $0.wrapperType == "podcastEpisode" && $0.trackId.map(String.init) == episodeID }) else {
            throw ResolverError.appleEpisodeOutsideWindow
        }
        var candidate = episodeTrack.candidate ?? EpisodeCandidate(title: episodeTrack.trackName ?? "", feedURL: feedURL,
                                                                   guid: episodeTrack.episodeGuid, enclosureURL: episodeTrack.episodeUrl)
        candidate.feedURL = feedURL
        var episode = try await resolve(candidate, source: .applePodcasts)
        episode.artwork = episode.artwork ?? track.artworkUrl600
        return .episode(episode)
    }

    func show(_ feed: RSSFeed, source: Source) -> ResolvedShow {
        let episodes = feed.episodes.map { item in
            var item = item
            item.source = source
            return item
        }.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        return ResolvedShow(feedURL: feed.url, title: feed.title, artwork: feed.artwork, episodes: episodes)
    }
}
