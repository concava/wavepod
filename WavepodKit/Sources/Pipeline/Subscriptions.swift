import Foundation
import Library
import Networking
import Resolver

public struct SubscriptionRefreshError: LocalizedError, Sendable {
    public var messages: [String]
    public var errorDescription: String? { messages.joined(separator: "\n") }
}

public actor SubscriptionMonitor {
    private let store: LibraryStore
    private let client: HTTPClient
    private let queue: JobQueue
    public init(store: LibraryStore, client: HTTPClient, queue: JobQueue) {
        self.store = store; self.client = client; self.queue = queue
    }
    public func refresh(now: Date = .now, force: Bool = false) async throws {
        var errors: [String] = []
        for var show in try store.values(Subscription.self, kind: "subscription") {
            try Task.checkCancellation()
            if !force, let checked = show.checked, now.timeIntervalSince(checked) < 3600 { continue }
            if let next = show.nextCheck, now < next { continue }
            do {
                try await client.allow(show.feedURL)
                var request = URLRequest(url: show.feedURL)
                request.setValue("wavepod/0.1 (podcast subscription reader)", forHTTPHeaderField: "User-Agent")
                request.setValue(show.etag, forHTTPHeaderField: "If-None-Match")
                request.setValue(show.modified, forHTTPHeaderField: "If-Modified-Since")
                let (data, response) = try await client.data(request, purpose: "feed")
                show.checked = now
                show.nextCheck = nil
                if let retry = response.value(forHTTPHeaderField: "Retry-After") {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    show.nextCheck = Double(retry).map { now.addingTimeInterval(max(3600, $0)) } ?? formatter.date(from: retry)
                }
                if let cache = response.value(forHTTPHeaderField: "Cache-Control"),
                   let range = cache.range(of: #"max-age\s*=\s*\d+"#, options: .regularExpression),
                   let seconds = Double(cache[range].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") {
                    let expiry = now.addingTimeInterval(max(3600, seconds))
                    show.nextCheck = max(show.nextCheck ?? expiry, expiry)
                }
                if response.statusCode == 304 {
                    try store.put(show, kind: "subscription", id: show.id)
                    continue
                }
                guard response.statusCode == 200 else { throw NetworkError.status(response.statusCode) }
                let feed = try RSSParser.parse(data, feedURL: show.feedURL)
                for episode in feed.episodes.sorted(by: { ($0.pubDate ?? .distantPast) < ($1.pubDate ?? .distantPast) }) {
                    let id = JobQueue.episodeID(episode)
                    if !show.seen.contains(id), show.autoTranscribe { try await queue.enqueue(episode) }
                    show.seen.insert(id)
                }
                show.etag = response.value(forHTTPHeaderField: "ETag")
                show.modified = response.value(forHTTPHeaderField: "Last-Modified")
                try store.put(show, kind: "subscription", id: show.id)
            } catch is CancellationError { throw CancellationError() }
            catch {
                show.checked = now
                try store.put(show, kind: "subscription", id: show.id)
                errors.append("\(show.title): \(error.localizedDescription)")
            }
        }
        if !errors.isEmpty { throw SubscriptionRefreshError(messages: errors) }
    }
}
