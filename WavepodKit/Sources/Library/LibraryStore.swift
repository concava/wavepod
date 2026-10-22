import Foundation
import GRDB

public struct SpeakerEvidence: Codable, Sendable {
    public var name: String
    public var source: String
    public var confidence: Double
    public var citation: Citation?
    public init(name: String, source: String, confidence: Double, citation: Citation?) {
        self.name = name; self.source = source; self.confidence = confidence; self.citation = citation
    }
}

public struct EpisodeRecord: Codable, Sendable, Identifiable {
    public var id: String { episode.id }
    public var episode: Episode
    public var transcript: Transcript
    public var speakers: [SpeakerID: Speaker]
    public var summary: EpisodeSummary?
    public var chat: [ChatMessage]
    public var notesPending: Bool?
    public var audioURL: URL?
    public var feedURL: URL?
    public var speakerEvidence: [SpeakerID: [SpeakerEvidence]]
    public var embeddings: [String: [Float]]

    public init(episode: Episode, transcript: Transcript, speakers: [SpeakerID: Speaker] = [:],
                summary: EpisodeSummary? = nil, chat: [ChatMessage] = [],
                audioURL: URL? = nil, feedURL: URL? = nil, embeddings: [String: [Float]] = [:], speakerEvidence: [SpeakerID: [SpeakerEvidence]] = [:]) {
        self.episode = episode; self.transcript = transcript; self.speakers = speakers
        self.summary = summary; self.chat = chat
        self.audioURL = audioURL; self.feedURL = feedURL; self.embeddings = embeddings; self.speakerEvidence = speakerEvidence
    }
}

public struct EpisodeListing: Sendable, Identifiable {
    public var id: String { episode.id }
    public var episode: Episode
    public var downloaded: Bool
    public var summarized: Bool
    public var notesPending: Bool
    public init(episode: Episode, downloaded: Bool = false, summarized: Bool = false, notesPending: Bool = false) {
        self.episode = episode; self.downloaded = downloaded; self.summarized = summarized; self.notesPending = notesPending
    }
}

public struct SearchHit: Identifiable, Sendable {
    public var id: String { "\(episodeID):\(segmentID)" }
    public var episodeID: String
    public var segmentID: Int
    public var title: String
    public var text: String
    public var start: Double
    public var score: Double
}

public struct Subscription: Codable, Sendable, Identifiable {
    public var id: String { feedURL.absoluteString }
    public var feedURL: URL
    public var title: String
    public var autoDownload: Bool
    public var autoSummarize: Bool
    public var keepLatest: Int?
    public var autoTranscribe: Bool
    public var checked: Date?
    public var nextCheck: Date?
    public var etag: String?
    public var modified: String?
    /// Seeded at subscription time so enabling automation never imports an entire back catalogue.
    public var seen: Set<String>
    public init(feedURL: URL, title: String, autoTranscribe: Bool = true, seen: Set<String> = [],
                autoDownload: Bool = true, autoSummarize: Bool = true, keepLatest: Int? = nil) {
        self.feedURL = feedURL; self.title = title; self.autoTranscribe = autoTranscribe; self.seen = seen
        self.autoDownload = autoDownload; self.autoSummarize = autoSummarize; self.keepLatest = keepLatest
    }
    enum CodingKeys: String, CodingKey {
        case feedURL, title, autoTranscribe, autoDownload, autoSummarize, keepLatest, checked, nextCheck, etag, modified, seen
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        feedURL = try values.decode(URL.self, forKey: .feedURL)
        title = try values.decode(String.self, forKey: .title)
        autoTranscribe = try values.decodeIfPresent(Bool.self, forKey: .autoTranscribe) ?? false
        autoDownload = try values.decodeIfPresent(Bool.self, forKey: .autoDownload) ?? false
        autoSummarize = try values.decodeIfPresent(Bool.self, forKey: .autoSummarize) ?? false
        keepLatest = try values.decodeIfPresent(Int.self, forKey: .keepLatest)
        checked = try values.decodeIfPresent(Date.self, forKey: .checked)
        nextCheck = try values.decodeIfPresent(Date.self, forKey: .nextCheck)
        etag = try values.decodeIfPresent(String.self, forKey: .etag)
        modified = try values.decodeIfPresent(String.self, forKey: .modified)
        seen = try values.decode(Set<String>.self, forKey: .seen)
    }
}

/// GRDB serializes access. Records, FTS rows and vectors commit in the same transaction.
public final class LibraryStore: Sendable {
    private let db: DatabaseQueue
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode=WAL") }
        db = try DatabaseQueue(path: url.path, configuration: configuration)
        var migrations = DatabaseMigrator()
        migrations.registerMigration("library-v1") { db in
            try db.execute(sql: "CREATE TABLE episodes (id TEXT PRIMARY KEY, title TEXT NOT NULL, date REAL NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE VIRTUAL TABLE passages USING fts5(episodeID UNINDEXED, segmentID UNINDEXED, title, text, start UNINDEXED, tokenize='unicode61 remove_diacritics 2')")
            try db.execute(sql: "CREATE TABLE vectors (episodeID TEXT NOT NULL, segmentID INTEGER NOT NULL, model TEXT NOT NULL, vector BLOB NOT NULL, PRIMARY KEY (episodeID, segmentID, model))")
            try db.execute(sql: "CREATE TABLE state (kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind,id))")
        }
        try migrations.migrate(db)
    }

    public func save(_ record: EpisodeRecord) throws {
        let data = try JSONEncoder().encode(record)
        try db.write { db in
            let previous = try Data.fetchOne(db, sql: "SELECT payload FROM episodes WHERE id=?", arguments: [record.id])
                .flatMap { try? JSONDecoder().decode(EpisodeRecord.self, from: $0) }
            try db.execute(sql: "INSERT INTO episodes VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,date=excluded.date,payload=excluded.payload",
                           arguments: [record.id, record.episode.title, record.episode.pubDate.timeIntervalSince1970, data])
            guard previous?.transcript != record.transcript || previous?.episode.title != record.episode.title else { return }
            try db.execute(sql: "DELETE FROM passages WHERE episodeID=?", arguments: [record.id])
            try db.execute(sql: "DELETE FROM vectors WHERE episodeID=?", arguments: [record.id])
            for segment in record.transcript.segments {
                try db.execute(sql: "INSERT INTO passages(episodeID,segmentID,title,text,start) VALUES(?,?,?,?,?)",
                               arguments: [record.id, segment.id, record.episode.title, segment.words.map(\.text).joined(separator: " "), segment.start])
            }
        }
    }

    public func episode(_ id: String) throws -> EpisodeRecord? {
        try db.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM episodes WHERE id=?", arguments: [id]) else { return nil }
            return try JSONDecoder().decode(EpisodeRecord.self, from: data)
        }
    }

    /// Load only episode metadata for navigation; long transcripts stay on disk until opened.
    public func items() throws -> [EpisodeListing] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT json_extract(payload, '$.episode') AS episode, json_extract(payload, '$.audioURL') AS audio, json_type(payload, '$.summary') AS summary, json_extract(payload, '$.notesPending') AS pending FROM episodes ORDER BY date DESC,id").map { row in
                let json: String = row["episode"]
                let audio: String? = row["audio"]
                let summary: String? = row["summary"]
                return EpisodeListing(episode: try JSONDecoder().decode(Episode.self, from: Data(json.utf8)),
                                      downloaded: audio.flatMap(URL.init(string:))?.isFileURL ?? false,
                                      summarized: summary != nil && summary != "null", notesPending: (row["pending"] as Bool?) ?? false)
            }
        }
    }

    public func episodes() throws -> [EpisodeRecord] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM episodes ORDER BY date DESC,id").map {
                try JSONDecoder().decode(EpisodeRecord.self, from: $0)
            }
        }
    }

    public func delete(_ id: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM passages WHERE episodeID=?", arguments: [id])
            try db.execute(sql: "DELETE FROM vectors WHERE episodeID=?", arguments: [id])
            try db.execute(sql: "DELETE FROM episodes WHERE id=?", arguments: [id])
        }
    }

    public func search(_ query: String, limit: Int = 40) throws -> [SearchHit] {
        let tokens = query.split { !$0.isLetter && !$0.isNumber }.prefix(24)
        guard !tokens.isEmpty else { return [] }
        let expression = tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
        return try db.read { db in
            try Row.fetchAll(db, sql: "SELECT episodeID,segmentID,title,text,start,bm25(passages) AS rank FROM passages WHERE passages MATCH ? ORDER BY rank LIMIT ?",
                             arguments: [expression, max(1, min(limit, 200))]).map { row in
                SearchHit(episodeID: row["episodeID"], segmentID: row["segmentID"], title: row["title"],
                          text: row["text"], start: row["start"], score: -row["rank"])
            }
        }
    }

    public func indexedSegments(episodeID: String, model: String) throws -> Set<Int> {
        try db.read { db in
            Set(try Int.fetchAll(db, sql: "SELECT segmentID FROM vectors WHERE episodeID=? AND model=?", arguments: [episodeID, model]))
        }
    }

    public func setVector(_ vector: [Float], model: String, episodeID: String, segmentID: Int) throws {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return }
        let data = try JSONEncoder().encode(vector)
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO vectors VALUES(?,?,?,?)", arguments: [episodeID, segmentID, model, data])
        }
    }

    public func semanticSearch(_ query: [Float], model: String, episodeID: String? = nil, limit: Int = 40) throws -> [SearchHit] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT v.vector,p.episodeID,p.segmentID,p.title,p.text,p.start FROM vectors v JOIN passages p ON v.episodeID=p.episodeID AND v.segmentID=p.segmentID WHERE v.model=? AND (? IS NULL OR v.episodeID=?)", arguments: [model, episodeID, episodeID]).compactMap { row -> SearchHit? in
                let vector = try JSONDecoder().decode([Float].self, from: row["vector"])
                guard let score = VectorMath.cosine(query, vector) else { return nil }
                return SearchHit(episodeID: row["episodeID"], segmentID: row["segmentID"], title: row["title"],
                                 text: row["text"], start: row["start"], score: Double(score))
            }.sorted { $0.score > $1.score }.prefix(max(0, limit)).map { $0 }
        }
    }

    public func put<T: Encodable & Sendable>(_ value: T, kind: String, id: String) throws {
        let data = try JSONEncoder().encode(value)
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO state VALUES(?,?,?)", arguments: [kind, id, data])
        }
    }

    public func values<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM state WHERE kind=? ORDER BY id", arguments: [kind]).map {
                try JSONDecoder().decode(type, from: $0)
            }
        }
    }

    public func remove(kind: String, id: String) throws {
        try db.write { db in try db.execute(sql: "DELETE FROM state WHERE kind=? AND id=?", arguments: [kind, id]) }
    }
}

public enum VectorMath {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, a.count == b.count, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return nil }
        let aa = a.reduce(0) { $0 + $1 * $1 }, bb = b.reduce(0) { $0 + $1 * $1 }
        guard aa > 0, bb > 0 else { return nil }
        return zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 } / sqrt(aa * bb)
    }
}
