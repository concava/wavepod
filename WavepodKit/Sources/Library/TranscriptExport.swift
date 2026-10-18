import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case srt, vtt, markdown, json, docx

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .srt: "SubRip (.srt)"
        case .vtt: "WebVTT (.vtt)"
        case .markdown: "Markdown (.md)"
        case .json: "JSON (.json)"
        case .docx: "Word (.docx)"
        }
    }
    public var fileExtension: String { self == .markdown ? "md" : rawValue }
    /// DOCX needs a zip writer; it lands with the Library module's persistence work.
    public var isAvailable: Bool { self != .docx }
}

/// Pure transcript exporters. Speaker names are resolved at export time, so a rename shows up in every format.
public enum TranscriptExport {
    public static func render(_ format: ExportFormat, episode: Episode, transcript: Transcript,
                              speakers: [SpeakerID: Speaker], mergeLines: Bool = true) throws -> Data {
        let paragraphs = transcript.paragraphs(merge: mergeLines)
        func name(_ id: SpeakerID) -> String { speakers[id]?.name ?? id.rawValue }
        switch format {
        case .srt:
            return Data(cues(transcript).enumerated().map { i, cue in
                "\(i + 1)\n\(stamp(cue.start, ",")) --> \(stamp(cue.end, ","))\n\(name(cue.speaker)): \(cue.text)\n"
            }.joined(separator: "\n").utf8)
        case .vtt:
            let body = cues(transcript).map { cue in
                "\(stamp(cue.start, ".")) --> \(stamp(cue.end, "."))\n<v \(escapeVTT(name(cue.speaker)))>\(escapeVTT(cue.text))"
            }.joined(separator: "\n\n")
            return Data("WEBVTT\n\n\(body)\n".utf8)
        case .markdown:
            var md = "# \(episode.title)\n\n_\(episode.showName)_\n\n"
            for p in paragraphs {
                md += "**\(name(p.speaker))** [\(Timecode.format(p.start))]\n\n\(p.text)\n\n"
            }
            return Data(md.utf8)
        case .json:
            let doc = JSONDocument(
                episode: .init(id: episode.id, show: episode.showName, title: episode.title, duration: episode.duration),
                language: transcript.language,
                speakers: speakers.values.sorted { $0.id.rawValue < $1.id.rawValue }
                    .map { .init(id: $0.id.rawValue, name: $0.name, confirmed: $0.isConfirmed) },
                segments: transcript.segments.map { s in
                    .init(speaker: s.speaker.rawValue, start: s.start, end: s.end,
                          text: s.words.map(\.text).joined(separator: " "),
                          words: s.words.map { .init(text: $0.text, start: $0.start, end: $0.end,
                                                     confidence: $0.confidence, overlap: $0.overlap) })
                })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(doc)
        case .docx:
            throw ExportError.unsupported(format)
        }
    }

    public enum ExportError: Error, Equatable {
        case unsupported(ExportFormat)
    }

    struct Cue {
        let speaker: SpeakerID
        let start: Seconds
        let end: Seconds
        let text: String
    }

    /// Subtitle cues: one per segment, split so a cue never exceeds `maxWords` words.
    static func cues(_ transcript: Transcript, maxWords: Int = 14) -> [Cue] {
        transcript.segments.flatMap { segment in
            stride(from: 0, to: segment.words.count, by: maxWords).map { i in
                let words = segment.words[i..<min(i + maxWords, segment.words.count)]
                return Cue(speaker: segment.speaker, start: words.first!.start, end: words.last!.end,
                           text: words.map(\.text).joined(separator: " "))
            }
        }
    }

    /// `00:01:02,345` (SRT) or `00:01:02.345` (VTT).
    static func stamp(_ t: Seconds, _ separator: String) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }

    static func escapeVTT(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    struct JSONDocument: Encodable {
        struct EpisodeInfo: Encodable { let id: String, show: String, title: String, duration: Seconds }
        struct SpeakerInfo: Encodable { let id: String, name: String, confirmed: Bool }
        struct WordInfo: Encodable { let text: String, start: Seconds, end: Seconds, confidence: Float, overlap: Bool }
        struct SegmentInfo: Encodable {
            let speaker: String, start: Seconds, end: Seconds, text: String, words: [WordInfo]
        }
        let episode: EpisodeInfo
        let language: String
        let speakers: [SpeakerInfo]
        let segments: [SegmentInfo]
    }
}
