import Foundation
import Library

public struct VoiceProfile: Codable, Sendable, Identifiable {
    public var id: String
    public var showID: String
    public var name: String
    public var embedding: [Float]
    public init(id: String = UUID().uuidString, showID: String, name: String, embedding: [Float]) {
        self.id = id; self.showID = showID; self.name = name; self.embedding = embedding
    }
}

public struct NameSuggestion: Sendable, Codable {
    public enum Source: String, Sendable, Codable { case voice, feed, introduction, description }
    public var name: String
    public var confidence: Double
    public var source: Source
    public var evidence: Citation?
}

public enum SpeakerIdentity {
    /// Voice matches are suggestions until confirmed. Restrict comparison to this show and this embedding family.
    public static func match(_ embedding: [Float], showID: String, profiles: [VoiceProfile], threshold: Float = 0.75) -> NameSuggestion? {
        let scored = profiles.filter { $0.showID == showID }.compactMap { profile -> (VoiceProfile, Float)? in
            VectorMath.cosine(embedding, profile.embedding).map { (profile, $0) }
        }.sorted { $0.1 > $1.1 }
        guard let first = scored.first, first.1 >= threshold,
              scored.count == 1 || first.1 - scored[1].1 >= 0.08 else { return nil }
        return NameSuggestion(name: first.0.name, confidence: Double(first.1), source: .voice)
    }

    /// Only introductions by the current speaker are attributed. Mentioning another person never renames them.
    public static func introduction(in segments: [Segment]) -> NameSuggestion? {
        let pattern = #"(?i:\b(?:my name is|i am|i'm|me llamo|soy|em dic|sóc))\s+([\p{Lu}][\p{L}'’-]*(?:\s+[\p{Lu}][\p{L}'’-]*){0,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for segment in segments {
            let text = segment.words.map(\.text).joined(separator: " ")
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[range]).trimmingCharacters(in: .punctuationCharacters)
            // A feed candidate corroborates short introductions; unknown single words remain unassigned.
            guard name.count >= 2 else { continue }
            return NameSuggestion(name: name, confidence: 0.8, source: .introduction,
                                  evidence: Citation(start: segment.start, quote: text))
        }
        return nil
    }

    public static func candidates(names: [String], description: String, transcript: Transcript,
                                  speaker: SpeakerID) -> [NameSuggestion] {
        let segments = transcript.segments.filter { $0.speaker == speaker }
        var results: [NameSuggestion] = []
        if let intro = introduction(in: segments) {
            // Feed/description corroboration avoids treating “I'm happy” as a person's name.
            if names.contains(where: { $0.localizedCaseInsensitiveContains(intro.name) }) ||
                description.localizedCaseInsensitiveContains(intro.name) {
                results.append(intro)
            }
        }
        for name in names where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let segment = segments.first(where: {
                $0.words.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains(name)
            }) {
                results.append(NameSuggestion(name: name, confidence: 0.55, source: .feed,
                                              evidence: Citation(start: segment.start, quote: segment.words.map(\.text).joined(separator: " "))))
            }
        }
        return results
    }
}
