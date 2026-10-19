import Foundation
import Engine
import Library

public enum WordAlignment {
    public static func render(_ raw: RawTranscript) throws -> Transcript {
        var segments: [Segment] = []
        var previous = "S1"
        for token in raw.words.sorted(by: { $0.word.start < $1.word.start }) {
            var word = token.word
            guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start,
                  word.confidence.isFinite else { throw EngineError.invalidResult }
            let midpoint = (word.start + word.end) / 2
            let covering = raw.turns.filter { $0.start <= midpoint && midpoint < $0.end }
                .sorted { ($0.end - $0.start, $0.speaker) < ($1.end - $1.start, $1.speaker) }
            let nearest = raw.turns.min { distance(midpoint, $0) < distance(midpoint, $1) }
            let speaker: String
            if let first = covering.first { speaker = first.speaker }
            else if let nearest, distance(midpoint, nearest) <= 0.5 { speaker = nearest.speaker }
            else { speaker = token.speaker ?? previous }
            word.overlap = Set(covering.map(\.speaker)).count > 1
            if let last = segments.last, last.speaker.rawValue == speaker, word.start - last.end < 1.5,
               last.words.count < 100, word.start - last.start < 30 {
                segments[segments.count - 1].words.append(word)
            } else {
                segments.append(Segment(id: segments.count, speaker: SpeakerID(speaker), words: [word]))
            }
            previous = speaker
        }
        return Transcript(language: raw.language, segments: segments)
    }
    private static func distance(_ midpoint: Double, _ turn: SpeakerTurn) -> Double {
        max(turn.start - midpoint, midpoint - turn.end, 0)
    }
}

/// Stitch windows at the middle of their overlap. A voice centroid, rather than a window-local label, joins
/// speakers across boundaries. Every word belongs to exactly one ownership interval.
public enum WindowStitcher {
    public static func append(_ window: RawTranscript, start: Double, keepFrom: Double, keepUntil: Double,
                              to result: inout RawTranscript) {
        var mapping: [String: String] = [:]
        var used = Set<String>()
        var assigned = Set(result.turns.map(\.speaker)).union(result.words.compactMap(\.speaker)).union(result.embeddings.keys)
        let labels = Set(window.turns.map(\.speaker)).union(window.words.compactMap(\.speaker)).union(window.embeddings.keys)
        for label in labels.sorted() {
            let match = window.embeddings[label].flatMap { embedding in
                result.embeddings.filter { !used.contains($0.key) }.compactMap { key, vector -> (String, Float)? in
                    VectorMath.cosine(embedding, vector).map { (key, $0) }
                }.filter { $0.1 >= 0.75 }.max { $0.1 < $1.1 }?.0
            }
            var number = 1
            while assigned.contains("S\(number)") { number += 1 }
            let id = match ?? "S\(number)"
            assigned.insert(id)
            mapping[label] = id
            used.insert(id)
            if let vector = window.embeddings[label], result.embeddings[id] == nil { result.embeddings[id] = vector }
        }
        for token in window.words {
            var token = token
            token.word.start += start; token.word.end += start
            let middle = (token.word.start + token.word.end) / 2
            guard middle >= keepFrom, middle < keepUntil else { continue }
            token.speaker = token.speaker.flatMap { mapping[$0] }
            result.words.append(token)
        }
        for turn in window.turns {
            let a = max(keepFrom, turn.start + start), b = min(keepUntil, turn.end + start)
            guard b > a else { continue }
            result.turns.append(SpeakerTurn(speaker: mapping[turn.speaker] ?? turn.speaker, start: a, end: b))
        }
    }
}

public enum DiarizationAttachment {
    /// Preserve the remote engine's labels. Local acoustic clusters supply embeddings, mapped by turn overlap.
    public static func attach(_ local: RawTranscript, to raw: inout RawTranscript) {
        guard !raw.turns.isEmpty else { raw.turns = local.turns; raw.embeddings = local.embeddings; return }
        var embeddings: [String: [Float]] = [:]
        var bestScore: [String: Double] = [:]
        for (localID, vector) in local.embeddings {
            let turns = local.turns.filter { $0.speaker == localID }
            var scores: [String: Double] = [:]
            for turn in turns {
                for remote in raw.turns {
                    scores[remote.speaker, default: 0] += max(0, min(turn.end, remote.end) - max(turn.start, remote.start))
                }
            }
            if let best = scores.max(by: { $0.value < $1.value }), best.value > bestScore[best.key, default: 0] {
                bestScore[best.key] = best.value
                embeddings[best.key] = vector
            }
        }
        raw.embeddings = embeddings
    }
}
