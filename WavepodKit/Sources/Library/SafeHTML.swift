import Foundation

/// Renders an untrusted feed description into plain styled text.
///
/// Only a fixed set of tags survives: paragraphs and line breaks, bold, italic, list items and `http(s)` links.
/// Everything else is dropped, and the content of `script`, `style`, `iframe` and similar tags is removed entirely.
/// No WebKit, so nothing is fetched and nothing runs.
public enum SafeHTML {
    public static func render(_ html: String) -> AttributedString {
        var output = AttributedString()
        var bold = 0, italic = 0
        var link: URL?
        var dropDepth = 0
        var pendingBreaks = 0

        func emit(_ text: String) {
            guard dropDepth == 0, !text.isEmpty else { return }
            let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            // Whitespace between block tags is layout, not content: it must not flush pending line breaks.
            if collapsed == " " && (pendingBreaks > 0 || output.characters.isEmpty) { return }
            var piece = collapsed
            if pendingBreaks > 0 {
                if !output.characters.isEmpty {
                    trimTrailingSpaces()
                    output.append(AttributedString(String(repeating: "\n", count: pendingBreaks)))
                }
                pendingBreaks = 0
                piece = String(piece.drop(while: { $0 == " " }))
            } else if output.characters.last == " " || output.characters.last == "\n" || output.characters.isEmpty {
                piece = String(piece.drop(while: { $0 == " " }))
            }
            guard !piece.isEmpty else { return }
            var run = AttributedString(decodeEntities(piece))
            var intent: InlinePresentationIntent = []
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if italic > 0 { intent.insert(.emphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if let link { run.link = link }
            output.append(run)
        }

        func trimTrailingSpaces() {
            while output.characters.last == " " { output.characters.removeLast() }
        }

        func requestBreaks(_ n: Int) {
            guard !output.characters.isEmpty else { return }
            pendingBreaks = max(pendingBreaks, n)
        }

        var index = html.startIndex
        while index < html.endIndex {
            guard let open = html[index...].firstIndex(of: "<") else {
                emit(String(html[index...]))
                break
            }
            emit(String(html[index..<open]))
            guard let close = html[open...].firstIndex(of: ">") else {
                emit(String(html[open...]))  // a lone "<" is text
                break
            }
            let tag = Tag(String(html[html.index(after: open)..<close]))
            index = html.index(after: close)

            if Tag.dropped.contains(tag.name) {
                if tag.isClosing { dropDepth = max(0, dropDepth - 1) } else if !tag.isSelfClosing { dropDepth += 1 }
                continue
            }
            switch (tag.name, tag.isClosing) {
            case ("p", _), ("div", _), ("ul", _), ("ol", _): requestBreaks(2)
            case ("br", _): requestBreaks(1)
            case ("li", false):
                requestBreaks(1)
                emit("• ")
            case ("b", false), ("strong", false): bold += 1
            case ("b", true), ("strong", true): bold = max(0, bold - 1)
            case ("i", false), ("em", false): italic += 1
            case ("i", true), ("em", true): italic = max(0, italic - 1)
            case ("a", false): link = tag.href.flatMap(safeURL)
            case ("a", true): link = nil
            default: break
            }
        }
        trimTrailingSpaces()
        return output
    }

    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: decodeEntities(raw.trimmingCharacters(in: .whitespaces))),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil
        else { return nil }
        return url
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
                     "rdquo": "”", "ldquo": "“"]
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = String(s[s.index(after: i)..<semi])
                var replacement: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if body.hasPrefix("#") {
                    replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    replacement = named[body]
                }
                if let replacement {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    struct Tag {
        static let dropped: Set<String> = ["script", "style", "iframe", "object", "embed", "svg", "math",
                                           "template", "noscript", "head", "title"]
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let href: String?

        init(_ raw: String) {
            var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            isClosing = body.hasPrefix("/")
            if isClosing { body.removeFirst() }
            isSelfClosing = body.hasSuffix("/")
            name = String(body.prefix(while: { $0.isLetter || $0.isNumber })).lowercased()
            href = Tag.attribute("href", in: body)
        }

        static func attribute(_ key: String, in body: String) -> String? {
            let pattern = "\(key)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body))
            else { return nil }
            for group in 2...4 {
                if let range = Range(match.range(at: group), in: body) { return String(body[range]) }
            }
            return nil
        }
    }
}
