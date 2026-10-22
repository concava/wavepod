import Foundation

public struct SpotifyMetadata: Sendable, Hashable, Codable {
    public var title: String
    public var showTitle: String?
    public var pubDate: Date?
    public var duration: TimeInterval?
    public var artwork: URL?

    public init(title: String, showTitle: String? = nil, pubDate: Date? = nil, duration: TimeInterval? = nil, artwork: URL? = nil) {
        self.title = title
        self.showTitle = showTitle
        self.pubDate = pubDate
        self.duration = duration
        self.artwork = artwork
    }
}

public enum SpotifyMatch: Sendable, Hashable, Codable {
    case matched(EpisodeCandidate, confidence: Double)
    case needsConfirmation([ScoredCandidate])
    case notFound(reason: String)
}

public struct SpotifyResolver: Sendable {
    let fetcher: any HTTPFetching
    let search: any EpisodeSearch
    public init(fetcher: any HTTPFetching, search: any EpisodeSearch) {
        self.fetcher = fetcher
        self.search = search
    }

    public func metadata(id: String) async throws -> SpotifyMetadata {
        let pageURL = URL(string: "https://open.spotify.com/episode/\(id)")!
        let oembedURL = endpoint("https://open.spotify.com/oembed", [("url", pageURL.absoluteString)])
        var metadata: SpotifyMetadata?
        do {
            let data = try await fetcher.data(oembedURL)
            let embed = try decodeResponse(OEmbed.self, from: data)
            if let title = embed.title { metadata = SpotifyMetadata(title: MetadataHTML.entities(title), artwork: embed.thumbnail_url) }
        } catch is CancellationError { throw CancellationError() }
        catch { /* The public page may still provide a title. */ }
        do {
            let data = try await fetcher.data(pageURL, headers: ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"])
            let tags = Self.metaTags(String(decoding: data, as: UTF8.self))
            if metadata == nil, let title = tags["og:title"] { metadata = SpotifyMetadata(title: title) }
            if var value = metadata {
                value.duration = tags["music:duration"].flatMap(FeedValueParser.duration)
                value.pubDate = tags["music:release_date"].flatMap(FeedValueParser.date)
                if let description = tags["description"], let start = description.range(of: "Listen to this episode from "),
                   let end = description.range(of: " on Spotify.", range: start.upperBound..<description.endIndex) {
                    value.showTitle = String(description[start.upperBound..<end.lowerBound])
                }
                metadata = value
            }
        } catch is CancellationError { throw CancellationError() }
        catch { /* Supplementary page metadata is best-effort. */ }
        guard let metadata, !metadata.title.isEmpty else { throw ResolverError.invalidResponse }
        return metadata
    }

    public func match(id: String) async throws -> SpotifyMatch {
        let metadata = try await metadata(id: id)
        return Self.match(metadata, candidates: try await search.search(title: metadata.title, showTitle: metadata.showTitle))
    }

    public static func match(_ metadata: SpotifyMetadata, candidates: [EpisodeCandidate]) -> SpotifyMatch {
        let ranked = candidates.map { ScoredCandidate(candidate: $0, confidence: score(metadata, candidate: $0)) }
            .sorted { $0.confidence > $1.confidence }
        guard candidates.contains(where: { TextNormalization.similarity(metadata.title, $0.title) > 0.5 }) else {
            return .notFound(reason: "This episode seems to be Spotify-exclusive, so wavepod can't get its audio.")
        }
        guard let best = ranked.first, best.confidence >= 0.6 else {
            return .notFound(reason: "wavepod found no close match in a public podcast feed.")
        }
        if best.confidence >= 0.85 { return .matched(best.candidate, confidence: best.confidence) }
        return .needsConfirmation(Array(ranked.prefix(5)))
    }

    /// Missing signals contribute neither weight nor penalty.
    public static func score(_ metadata: SpotifyMetadata, candidate: EpisodeCandidate) -> Double {
        var weighted = TextNormalization.similarity(metadata.title, candidate.title) * 0.55
        var weight = 0.55
        if let lhs = metadata.showTitle, let rhs = candidate.showTitle, !lhs.isEmpty, !rhs.isEmpty {
            weighted += TextNormalization.similarity(lhs, rhs) * 0.2
            weight += 0.2
        }
        if let lhs = metadata.pubDate, let rhs = candidate.pubDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let days = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: lhs), to: calendar.startOfDay(for: rhs)).day ?? 7)
            let signal = days == 0 ? 1 : max(0, 0.8 * (7 - Double(days)) / 6)
            weighted += signal * 0.15
            weight += 0.15
        }
        if let lhs = metadata.duration, let rhs = candidate.duration {
            weighted += max(0, min(1, (600 - abs(lhs - rhs)) / 540)) * 0.1
            weight += 0.1
        }
        return min(1, max(0, weighted / weight))
    }

    private struct OEmbed: Decodable {
        var title: String?
        var thumbnail_url: URL?
    }

    static func metaTags(_ html: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive) else { return [:] }
        var tags: [String: String] = [:]
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            if let name = MetadataHTML.attribute("name", in: tag) ?? MetadataHTML.attribute("property", in: tag),
               let content = MetadataHTML.attribute("content", in: tag) { tags[name.lowercased()] = content }
        }
        return tags
    }
}
