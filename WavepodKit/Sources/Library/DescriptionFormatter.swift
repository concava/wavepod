import Foundation

/// Gives structure to an episode description that the feed sends as plain lines: headings, timestamps and links.
///
/// Many feeds write their show notes as one line per paragraph with no markup, so a heading such as "ÍNDICE" or
/// "SOBRE ITNIG:" looks the same as the text under it. This pass runs on the output of `SafeHTML.render`:
/// - A line that reads as a heading becomes bold: all capitals, a short line that ends with ":", or a short line
///   that a list of timestamps follows. A capital prefix that ends with ":" ("SOBRE ITNIG: …") becomes bold too.
/// - A timestamp at the start of a line, or in brackets, links to `SafeHTML.timeURL(_:)` and shows in monospace.
/// - A bare `http(s)` address or `www.` address becomes a link. Existing links stay as they are.
extension SafeHTML {
    /// The URL scheme of a timestamp link. The view that shows the text plays the episode from that second.
    public static let timeScheme = "wavepod-time"

    public static func timeURL(_ seconds: Int) -> URL { URL(string: "\(timeScheme):\(seconds)")! }

    /// The second a timestamp link points to, or nil for any other URL.
    public static func seconds(in url: URL) -> Int? {
        guard url.scheme == timeScheme else { return nil }
        return Int(url.absoluteString.dropFirst(timeScheme.count + 1))
    }

    /// `render` plus headings, timestamp links and bare-URL links.
    public static func renderDescription(_ html: String) -> AttributedString {
        // Plain text keeps its line breaks: a blank line is a paragraph, a single newline a line break.
        let source = html.contains("<") ? html : html
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n\\s*\n", with: "<p>", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: "<br>")
        var text = render(source)
        let lines = lineRanges(in: text)
        for (offset, line) in lines.enumerated() {
            let string = String(text[line].characters)
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let hasLink = text[line].runs.contains { $0.link != nil }
            let next = lines.dropFirst(offset + 1).lazy.map { String(text[$0].characters) }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

            if let stamp = leadingTimestamp(in: string) {
                link(&text, line: line, characters: stamp.range, in: string, to: stamp.seconds, code: true)
            } else if !hasLink, isHeading(trimmed, before: next) {
                text[line].inlinePresentationIntent = .stronglyEmphasized
                continue
            } else if let prefix = capitalPrefix(in: string) {
                bold(&text, line: line, characters: prefix, in: string)
            }
            for stamp in bracketedTimestamps(in: string) {
                link(&text, line: line, characters: stamp.range, in: string, to: stamp.seconds, code: true)
            }
            linkAddresses(&text, line: line, in: string)
        }
        return text
    }

    // MARK: Lines

    static func lineRanges(in text: AttributedString) -> [Range<AttributedString.Index>] {
        var ranges: [Range<AttributedString.Index>] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text.characters[index] == "\n" {
                ranges.append(start..<index)
                start = text.index(afterCharacter: index)
            }
            index = text.index(afterCharacter: index)
        }
        ranges.append(start..<text.endIndex)
        return ranges
    }

    static func isHeading(_ line: String, before next: String?) -> Bool {
        guard line.count <= 60, !line.hasSuffix("."), !line.hasSuffix(","), leadingTimestamp(in: line) == nil else { return false }
        let words = line.split(whereSeparator: \.isWhitespace).count
        let letters = line.filter(\.isLetter)
        if letters.count >= 3, letters == letters.uppercased(), letters != letters.lowercased() { return true }
        if line.hasSuffix(":"), words <= 6 { return true }
        if words <= 4, let next, leadingTimestamp(in: next) != nil { return true }
        return false
    }

    /// "SOBRE ITNIG:" in "SOBRE ITNIG: 🐦 X - https://x.com/itnig". At least three capital letters, then ":".
    static func capitalPrefix(in line: String) -> Range<String.Index>? {
        guard let colon = line.firstIndex(of: ":"), line[line.index(after: colon)...].contains(where: { !$0.isWhitespace }) else { return nil }
        let head = line[..<colon]
        let letters = head.filter(\.isLetter)
        guard letters.count >= 3, letters == letters.uppercased(), letters != letters.lowercased(),
              head.count <= 40, !head.contains("/") else { return nil }
        let start = line.firstIndex { !$0.isWhitespace } ?? line.startIndex
        return start..<line.index(after: colon)
    }

    // MARK: Timestamps

    private static let leading = try! NSRegularExpression(pattern: #"^\s*((?:\d{1,2}:)?\d{1,2}:\d{2})(?!\d)"#)
    private static let bracketed = try! NSRegularExpression(pattern: #"[(\[]((?:\d{1,2}:)?\d{1,2}:\d{2})[)\]]"#)

    static func leadingTimestamp(in line: String) -> (range: Range<String.Index>, seconds: Int)? {
        matches(leading, in: line).first
    }

    static func bracketedTimestamps(in line: String) -> [(range: Range<String.Index>, seconds: Int)] {
        matches(bracketed, in: line)
    }

    private static func matches(_ regex: NSRegularExpression, in line: String) -> [(range: Range<String.Index>, seconds: Int)] {
        regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: line), let seconds = seconds(of: String(line[range])) else { return nil }
            return (range, seconds)
        }
    }

    /// "1:05" → 65, "00:05:43" → 343. Minutes and seconds above 59 are not a time.
    static func seconds(of stamp: String) -> Int? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == stamp.split(separator: ":").count, (2...3).contains(parts.count),
              parts.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: Links

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func linkAddresses(_ text: inout AttributedString, line: Range<AttributedString.Index>, in string: String) {
        for match in detector.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
            guard let range = Range(match.range, in: string), let url = match.url,
                  let safe = safeURL(url.absoluteString) else { continue }
            let target = attributedRange(range, of: line, in: string, text: text)
            guard !text[target].runs.contains(where: { $0.link != nil }) else { continue }
            text[target].link = safe
        }
    }

    private static func link(_ text: inout AttributedString, line: Range<AttributedString.Index>, characters: Range<String.Index>,
                             in string: String, to seconds: Int, code: Bool) {
        let target = attributedRange(characters, of: line, in: string, text: text)
        text[target].link = timeURL(seconds)
        if code { text[target].inlinePresentationIntent = .code }
    }

    private static func bold(_ text: inout AttributedString, line: Range<AttributedString.Index>, characters: Range<String.Index>, in string: String) {
        text[attributedRange(characters, of: line, in: string, text: text)].inlinePresentationIntent = .stronglyEmphasized
    }

    /// Maps a range in the line's `String` to the same characters in the attributed text.
    private static func attributedRange(_ range: Range<String.Index>, of line: Range<AttributedString.Index>, in string: String,
                                        text: AttributedString) -> Range<AttributedString.Index> {
        let start = text.characters.index(line.lowerBound, offsetBy: string.distance(from: string.startIndex, to: range.lowerBound))
        let end = text.characters.index(start, offsetBy: string.distance(from: range.lowerBound, to: range.upperBound))
        return start..<end
    }
}
