import Foundation
import Library

public struct SubscriptionAutomation: Codable, Sendable {
    public var download: Bool
    public var transcribe: Bool
    public var summarize: Bool
    public init(download: Bool, transcribe: Bool, summarize: Bool) {
        self.download = download; self.transcribe = transcribe || summarize; self.summarize = summarize
    }
}

public enum AudioRetention {
    public static func prune(_ show: Subscription, store: LibraryStore, directory: URL) throws {
        guard let limit = show.keepLatest else { return }
        let jobs = try store.values(TranscriptionJob.self, kind: "job")
        let active = Set(jobs.filter { [.queued, .running, .paused].contains($0.state) }.map { JobQueue.episodeID($0.episode) })
        let records = try store.episodes().filter { $0.feedURL == show.feedURL && $0.audioURL != nil }
            .sorted { $0.episode.pubDate == $1.episode.pubDate ? $0.id < $1.id : $0.episode.pubDate > $1.episode.pubDate }
        for var record in records.dropFirst(max(0, limit)) {
            guard !active.contains(record.id) else { continue }
            guard let url = record.audioURL, url.isFileURL,
                  url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else { continue }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            record.audioURL = nil
            try store.save(record)
            for job in jobs where JobQueue.episodeID(job.episode) == record.id {
                let folder = directory.appendingPathComponent("jobs/\(job.id.uuidString)")
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                    where name == "decoded.wav" || name.hasPrefix("source.") {
                    try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                }
            }
        }
    }
}
