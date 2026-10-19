import Foundation

/// Shared feed and matching normalization, independent of the user's locale.
enum TextNormalization {
    static func title(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let stripped = folded.replacingOccurrences(
            of: #"^\s*(?:(?:episode|ep)\.?\s*#?\s*\d+|#\s*\d+|\d+\s*[–—:.-])\s*[–—:.-]?\s*"#,
            with: "", options: .regularExpression)
        return stripped.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(title(lhs).split(separator: " ")), b = Set(title(rhs).split(separator: " "))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}

public enum FeedValueParser {
    // Foundation formatters support concurrent parsing on macOS 14+. Configure once and never mutate after publication.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter
    }()
    private static let dateFormatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z", "d MMM yy HH:mm:ss Z",
        "EEE, d MMM yy HH:mm Z", "d MMM yy HH:mm Z",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = format
        return formatter
    }

    public static func duration(_ value: String) -> TimeInterval? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let number = Double(part), number.isFinite, number >= 0 else { return nil }
            total = total * 60 + number
        }
        return total.isFinite ? total : nil
    }

    public static func date(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = isoFormatter.date(from: text) { return date }
        if let date = fractionalISOFormatter.date(from: text) { return date }
        let zones = ["UT": "+0000", "GMT": "+0000", "EST": "-0500", "EDT": "-0400",
                     "CST": "-0600", "CDT": "-0500", "MST": "-0700", "MDT": "-0600",
                     "PST": "-0800", "PDT": "-0700"]
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if let last = tokens.last, let zone = zones[last.uppercased()] { tokens[tokens.count - 1] = zone }
        let normalized = tokens.joined(separator: " ")
        for formatter in dateFormatters {
            if let date = formatter.date(from: normalized) { return date }
        }
        return nil
    }
}

/// Small HTML helpers for metadata and imported text, never a renderer.
enum MetadataHTML {
    static func rssAlternate(in html: String, pageURL: URL) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive) else { return nil }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            guard let rel = attribute("rel", in: tag),
                  rel.lowercased().split(whereSeparator: \.isWhitespace).contains("alternate"),
                  attribute("type", in: tag)?.lowercased() == "application/rss+xml",
                  let href = attribute("href", in: tag), !href.isEmpty,
                  let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            return url
        }
        return nil
    }

    static func entities(_ text: String) -> String {
        let pattern = #"&(#x[0-9a-fA-F]+|#\d+|[A-Za-z]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ",
                     "ndash": "–", "mdash": "—", "rsquo": "’", "lsquo": "‘", "hellip": "…"]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: result) else { continue }
            let key = String(text[range])
            let replacement: String?
            if key.hasPrefix("#x") { replacement = UInt32(key.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init) }
            else if key.hasPrefix("#") { replacement = UInt32(key.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init) }
            else { replacement = named[key] }
            if let replacement { result.replaceSubrange(whole, with: replacement) }
        }
        return result
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) { return entities(String(tag[range])) }
        }
        return nil
    }

    static func plain(_ text: String) -> String {
        entities(text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression))
    }
}
