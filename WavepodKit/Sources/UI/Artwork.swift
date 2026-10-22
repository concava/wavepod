import AppKit
import CryptoKit
import Library
import Networking
import Resolver
import SwiftUI

/// Podcast images named by feeds, downloaded once through `HTTPClient` and kept on disk.
actor ArtworkCache {
    private let directory: URL
    private let client: HTTPClient
    private var memory: [URL: Data] = [:]
    private var failed: Set<URL> = []
    private var pending: [URL: Task<Data?, Never>] = [:]
    private var feeds: [URL: Task<URL?, Never>] = [:]

    init(directory: URL, client: HTTPClient) { self.directory = directory; self.client = client }

    /// The image bytes, or nil when the image can't be fetched or isn't an image. A failure shows the generated
    /// placeholder and is retried on the next launch, not on every redraw.
    func image(for url: URL) async -> Data? {
        if let data = memory[url] { return data }
        if failed.contains(url) { return nil }
        if let task = pending[url] { return await task.value }
        let file = directory.appendingPathComponent(SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined())
        let task = Task<Data?, Never> { [client] in
            if let data = try? Data(contentsOf: file) { return data }
            do {
                try await client.allow(url)
                let (data, response) = try await client.data(URLRequest(url: url), purpose: "artwork", maximumBytes: 8 * 1024 * 1024)
                guard response.statusCode == 200, NSImage(data: data) != nil else { return nil }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                return data
            } catch { return nil }
        }
        pending[url] = task
        let data = await task.value
        pending[url] = nil
        if let data {
            if memory.count >= 64 { memory.removeAll() }
            memory[url] = data
        } else { failed.insert(url) }
        return data
    }

    /// The show image a feed names, for episodes saved before wavepod kept artwork.
    func feedArtwork(_ feed: URL) async -> URL? {
        if let task = feeds[feed] { return await task.value }
        let task = Task<URL?, Never> { [client] in
            do {
                try await client.allow(feed)
                var request = URLRequest(url: feed)
                request.setValue("wavepod/0.1 (podcast subscription reader)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await client.data(request, purpose: "feed")
                guard response.statusCode == 200 else { return nil }
                return try RSSParser.parse(data, feedURL: feed).artwork
            } catch { return nil }
        }
        feeds[feed] = task
        return await task.value
    }
}

private struct ArtworkCacheKey: EnvironmentKey {
    static let defaultValue: ArtworkCache? = nil
}
extension EnvironmentValues {
    var artworkCache: ArtworkCache? {
        get { self[ArtworkCacheKey.self] }
        set { self[ArtworkCacheKey.self] = newValue }
    }
}

extension AppModel {
    /// Fills in artwork for an episode saved before wavepod kept it, from the feed the user already opened.
    func backfillArtwork() {
        guard let services, episode.artworkURL == nil, let feed = feedURL else { return }
        let id = episode.id
        Task {
            guard let url = await services.artwork.feedArtwork(feed) else { return }
            do {
                guard var record = try services.store.episode(id), record.episode.artworkURL == nil else { return }
                record.episode.artworkURL = url
                try services.store.save(record)
                if episode.id == id { episode.artworkURL = url }
            } catch {}
        }
    }
}
