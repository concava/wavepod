import Foundation

public struct RSSFeed: Sendable, Hashable, Codable {
    public var url: URL
    public var title: String
    public var link: URL?
    /// Item page links in the same order as `episodes`.
    public var episodeLinks: [URL?]
    public var artwork: URL?
    public var language: String?
    public var guid: String?
    public var persons: [Person]
    public var episodes: [ResolvedEpisode]

    /// Each fallback is attempted only after the stronger identifier fails to match.
    public func episode(guid: String? = nil, enclosureURL: URL? = nil, title: String? = nil, date: Date? = nil) -> ResolvedEpisode? {
        if let guid, let found = episodes.first(where: { $0.guid == guid }) { return found }
        if let enclosureURL, let found = episodes.first(where: { $0.enclosureURL == enclosureURL }) { return found }
        if let title {
            return episodes.first { episode in
                TextNormalization.title(episode.title) == TextNormalization.title(title) &&
                    (date.map { expected in
                        var calendar = Calendar(identifier: .gregorian)
                        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                        return episode.pubDate.map { calendar.isDate($0, inSameDayAs: expected) } ?? false
                    } ?? true)
            }
        }
        return nil
    }
}

public enum RSSParser {
    public static func parse(_ data: Data, feedURL: URL) throws -> RSSFeed {
        let delegate = FeedDelegate(url: feedURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isRSS, delegate.sawChannel else { throw ResolverError.invalidFeed }
        return delegate.feed()
    }
}

private final class FeedDelegate: NSObject, XMLParserDelegate {
    static let itunes = "http://www.itunes.com/dtds/podcast-1.0.dtd"
    static let podcast = "https://podcastindex.org/namespace/1.0"
    static let legacyPodcast = "https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/1.0.md"
    static let content = "http://purl.org/rss/1.0/modules/content/"
    struct Element {
        var name: String
        var uri: String
        var text = ""
        var attributes: [String: String]
    }

    let url: URL
    var stack: [Element] = []
    var isRSS = false
    var sawChannel = false
    var channel = ResolvedEpisode(title: "")
    var item: ResolvedEpisode?
    var episodes: [ResolvedEpisode] = []
    var channelLink: URL?
    var itemLink: URL?
    var episodeLinks: [URL?] = []

    init(url: URL) { self.url = url }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if stack.isEmpty { isRSS = name == "rss" && (namespaceURI ?? "").isEmpty }
        if name == "channel", (namespaceURI ?? "").isEmpty, stack.count == 1, stack.last?.name == "rss" { sawChannel = true }
        if name == "item", (namespaceURI ?? "").isEmpty, stack.count == 2, stack.last?.name == "channel" {
            item = ResolvedEpisode(title: "", feedURL: url)
            itemLink = nil
        }
        let uri = namespaceURI == Self.legacyPodcast ? Self.podcast : namespaceURI ?? ""
        stack.append(Element(name: name, uri: uri, attributes: attributes))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let element = stack.popLast() else { return }
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.last?.name
        if name == "item", element.uri.isEmpty, parent == "channel", stack.count == 2 {
            if let item {
                episodes.append(item)
                episodeLinks.append(itemLink)
            }
            item = nil
            return
        }
        let direct = (parent == "item" && stack.count == 3 && stack.last?.uri == "") ||
            (parent == "channel" && stack.count == 2 && stack.last?.uri == "")
        if direct {
            var value = item ?? channel
            switch (element.uri, name) {
            case ("", "title"):
                if value.title.isEmpty { value.title = text }
            case (Self.itunes, "title"): value.title = text
            case ("", "link"):
                if item != nil { itemLink = link(text) } else { channelLink = link(text) }
            case ("", "enclosure"): value.enclosureURL = link(element.attributes["url"])
            case ("", "guid"): value.guid = text
            case (Self.podcast, "guid"):
                if value.guid == nil { value.guid = text }
            case ("", "pubDate"): value.pubDate = FeedValueParser.date(text)
            case ("", "description"):
                if value.descriptionHTML == nil { value.descriptionHTML = text }
            case (Self.content, "encoded"): value.descriptionHTML = text
            case (Self.itunes, "duration"): value.duration = FeedValueParser.duration(text)
            case (Self.itunes, "image"): value.artwork = link(element.attributes["href"])
            case ("", "language"):
                value.language = text.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init)
            case (Self.podcast, "transcript"):
                if let url = link(element.attributes["url"]) {
                    value.transcripts.append(TranscriptLink(url: url, type: element.attributes["type"] ?? "text/plain",
                                                           language: element.attributes["language"], rel: element.attributes["rel"]))
                }
            case (Self.podcast, "chapters"): value.chaptersURL = link(element.attributes["url"])
            case (Self.podcast, "person"):
                value.persons.append(Person(name: text, role: element.attributes["role"], group: element.attributes["group"],
                                            img: link(element.attributes["img"]), href: link(element.attributes["href"])))
            default: break
            }
            if item != nil { item = value } else { channel = value }
        } else if name == "url", parent == "image", stack.dropLast().last?.name == "channel", channel.artwork == nil {
            channel.artwork = link(text)
        }
        if !stack.isEmpty { stack[stack.count - 1].text += element.text }
    }

    func link(_ text: String?) -> URL? {
        text.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
    }

    func feed() -> RSSFeed {
        let episodes = episodes.map { episode in
            var episode = episode
            episode.showTitle = channel.title
            episode.artwork = episode.artwork ?? channel.artwork
            episode.language = episode.language ?? channel.language
            if episode.persons.isEmpty { episode.persons = channel.persons }
            return episode
        }
        return RSSFeed(url: url, title: channel.title, link: channelLink, episodeLinks: episodeLinks, artwork: channel.artwork, language: channel.language,
                       guid: channel.guid, persons: channel.persons, episodes: episodes)
    }
}
