import Foundation

/// Seconds from the start of the episode.
public typealias Seconds = Double

public struct SpeakerID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct Speaker: Identifiable, Hashable, Sendable, Codable {
    public let id: SpeakerID
    public var name: String
    /// `true` once a person confirmed the name; `false` for a suggestion (podcast:person, self-introduction, voice match).
    public var isConfirmed: Bool
    /// Confidence of a suggested name, 0…1. `nil` for a generic label such as "Speaker 3".
    public var suggestionConfidence: Double?
    /// Index into the speaker colour palette.
    public var colorIndex: Int

    public init(id: SpeakerID, name: String, isConfirmed: Bool, suggestionConfidence: Double? = nil, colorIndex: Int) {
        self.id = id
        self.name = name
        self.isConfirmed = isConfirmed
        self.suggestionConfidence = suggestionConfidence
        self.colorIndex = colorIndex
    }
}

public struct Word: Hashable, Sendable, Codable {
    public var text: String
    public var start: Seconds
    public var end: Seconds
    public var confidence: Float
    /// Another speaker talks at the same time.
    public var overlap: Bool

    public init(text: String, start: Seconds, end: Seconds, confidence: Float = 1, overlap: Bool = false) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.overlap = overlap
    }
}

/// One line as the recognizer produced it: a sentence or clause from a single speaker.
public struct Segment: Identifiable, Hashable, Sendable, Codable {
    public let id: Int
    public var speaker: SpeakerID
    public var words: [Word]

    public init(id: Int, speaker: SpeakerID, words: [Word]) {
        self.id = id
        self.speaker = speaker
        self.words = words
    }

    public var start: Seconds { words.first?.start ?? 0 }
    public var end: Seconds { words.last?.end ?? 0 }
}

/// What the transcript view shows: one or more consecutive segments of one speaker.
public struct Paragraph: Identifiable, Hashable, Sendable {
    public let id: Int
    public let speaker: SpeakerID
    public let segments: [Segment]

    public var start: Seconds { segments.first?.start ?? 0 }
    public var end: Seconds { segments.last?.end ?? 0 }
    public var words: [Word] { segments.flatMap(\.words) }
    public var text: String { words.map(\.text).joined(separator: " ") }
}

public struct Transcript: Hashable, Sendable, Codable {
    public var language: String
    public var segments: [Segment]

    public init(language: String, segments: [Segment]) {
        self.language = language
        self.segments = segments
    }

    /// Paragraphs for display.
    /// - Parameter merge: join consecutive segments of the same speaker unless a pause of `pauseBreak` or more
    ///   separates them. When `false`, every segment is its own paragraph.
    public func paragraphs(merge: Bool, pauseBreak: Seconds = 1.5) -> [Paragraph] {
        var result: [Paragraph] = []
        var current: [Segment] = []
        func flush() {
            guard let first = current.first else { return }
            result.append(Paragraph(id: first.id, speaker: first.speaker, segments: current))
            current = []
        }
        for segment in segments {
            if let last = current.last,
               !merge || last.speaker != segment.speaker || segment.start - last.end >= pauseBreak {
                flush()
            }
            current.append(segment)
        }
        flush()
        return result
    }

    public var duration: Seconds { segments.last?.end ?? 0 }
}

extension Array where Element == Paragraph {
    /// Index of the paragraph being spoken at `time`, or the last one that started before it.
    public func index(at time: Seconds) -> Int? {
        var low = 0, high = count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if self[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

public struct Chapter: Identifiable, Hashable, Sendable, Codable {
    public var id: Seconds { start }
    public var title: String
    public var start: Seconds
    public var summary: String

    public init(title: String, start: Seconds, summary: String) {
        self.title = title
        self.start = start
        self.summary = summary
    }
}

/// A claim that points into the transcript. `quote` must match the words at `start` (validated in the LLM module).
public struct Citation: Hashable, Sendable, Codable {
    public var start: Seconds
    public var quote: String

    public init(start: Seconds, quote: String) {
        self.start = start
        self.quote = quote
    }
}

public struct SummaryPoint: Hashable, Sendable, Codable, Identifiable {
    public var id: String { text }
    public var text: String
    public var citation: Citation

    public init(text: String, citation: Citation) {
        self.text = text
        self.citation = citation
    }
}

public struct SummarySection: Hashable, Sendable, Codable, Identifiable {
    public var id: String { title }
    public var title: String
    public var points: [SummaryPoint]

    public init(title: String, points: [SummaryPoint]) {
        self.title = title
        self.points = points
    }
}

public struct EpisodeSummary: Hashable, Sendable, Codable {
    public var overview: String
    public var points: [SummaryPoint]
    public var quotes: [Citation]
    /// Optional so summaries saved before sectioned notes still decode.
    public var sections: [SummarySection]?

    public init(overview: String, points: [SummaryPoint], quotes: [Citation], sections: [SummarySection]? = nil) {
        self.overview = overview
        self.points = points
        self.quotes = quotes
        self.sections = sections
    }
}

public struct ChatMessage: Identifiable, Hashable, Sendable, Codable {
    public enum Role: String, Sendable, Codable { case user, assistant }

    public let id: UUID
    public var role: Role
    public var text: String
    public var citations: [Citation]
    public var date: Date

    public init(id: UUID = UUID(), role: Role, text: String, citations: [Citation] = [], date: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.citations = citations
        self.date = date
    }
}

public struct Episode: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var showName: String
    public var title: String
    public var pubDate: Date
    public var duration: Seconds
    /// The feed's description, unsanitized. Render it only through `SafeHTML`.
    public var descriptionHTML: String
    public var sourceName: String
    public var sourceURL: URL?
    public var enclosureURL: URL?
    /// Seed for the generated placeholder artwork until real artwork is downloaded.
    public var artworkHue: Double
    /// The episode's or show's image from the feed. nil for imported files and episodes saved before artwork.
    public var artworkURL: URL?

    public init(id: String, showName: String, title: String, pubDate: Date, duration: Seconds,
                descriptionHTML: String, sourceName: String, sourceURL: URL?, enclosureURL: URL?, artworkHue: Double,
                artworkURL: URL? = nil) {
        self.id = id
        self.showName = showName
        self.title = title
        self.pubDate = pubDate
        self.duration = duration
        self.descriptionHTML = descriptionHTML
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.enclosureURL = enclosureURL
        self.artworkHue = artworkHue
        self.artworkURL = artworkURL
    }
}
