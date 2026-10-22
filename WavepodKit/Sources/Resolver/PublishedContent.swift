import Foundation

public struct ImportedCue: Sendable, Hashable, Codable {
    public var start: TimeInterval?
    public var end: TimeInterval?
    public var speaker: String?
    public var text: String
}

public struct ImportedTranscript: Sendable, Hashable, Codable {
    public var cues: [ImportedCue]
    public var hasTimings: Bool
}

public enum PublishedContentParser {
    public static func transcript(_ data: Data, type: String) throws -> ImportedTranscript {
        let type = type.lowercased()
        if type.contains("json") {
            let document = try decodeResponse(JSONTranscript.self, from: data)
            let cues = document.segments.compactMap { segment -> ImportedCue? in
                guard valid(segment.startTime, segment.endTime) else { return nil }
                return ImportedCue(start: segment.startTime, end: segment.endTime, speaker: segment.speaker, text: segment.body)
            }
            return ImportedTranscript(cues: cues, hasTimings: !cues.isEmpty)
        }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        if type.contains("vtt") || type.contains("srt") || type.contains("subrip") {
            var cues: [ImportedCue] = []
            let blocks = text.components(separatedBy: "\n\n")
            for block in blocks {
                let lines = block.components(separatedBy: "\n")
                guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
                if let first = lines.first, first.hasPrefix("NOTE") || first == "STYLE" || first == "REGION" { continue }
                let times = lines[index].components(separatedBy: "-->")
                guard times.count == 2,
                      let start = timestamp(times[0]), let end = timestamp(times[1]), valid(start, end) else { continue }
                let body = lines.dropFirst(index + 1).joined(separator: "\n")
                var speaker: String?
                if let regex = try? NSRegularExpression(pattern: #"<v(?:\.[^\s>]+)?\s+([^>]+)>"#),
                   let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                   let range = Range(match.range(at: 1), in: body) { speaker = MetadataHTML.entities(String(body[range])) }
                cues.append(ImportedCue(start: start, end: end, speaker: speaker, text: MetadataHTML.plain(body)))
            }
            return ImportedTranscript(cues: cues, hasTimings: !cues.isEmpty)
        }
        return ImportedTranscript(cues: [ImportedCue(start: nil, end: nil, speaker: nil,
                                                     text: type.contains("html") ? MetadataHTML.plain(text) : text)], hasTimings: false)
    }

    static func timestamp(_ text: String) -> Double? {
        guard let token = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        return FeedValueParser.duration(token.replacingOccurrences(of: ",", with: "."))
    }

    static func valid(_ start: Double, _ end: Double) -> Bool { start.isFinite && end.isFinite && start >= 0 && end >= start }

    private struct JSONTranscript: Decodable {
        struct Segment: Decodable {
            var startTime: Double
            var endTime: Double
            var speaker: String?
            var body: String
        }
        var segments: [Segment]
    }
}
