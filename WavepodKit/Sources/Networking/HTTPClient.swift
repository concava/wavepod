import Foundation
import Darwin

public enum NetworkError: Error, LocalizedError, Sendable {
    case denied(String), invalidResponse, status(Int), tooLarge
    public var errorDescription: String? {
        switch self {
        case .denied(let host): "Network access is not allowed for \(host)."
        case .invalidResponse: "The server returned an invalid response."
        case .status(let code): "The server returned HTTP \(code)."
        case .tooLarge: "The response exceeded the size limit."
        }
    }
}

public struct NetworkEntry: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var method: String
    public var host: String
    public var purpose: String
    public var status: Int?
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The sole app transport. Redirects are checked before any bytes go to their destination.
public actor HTTPClient {
    public static let shared = HTTPClient()
    private var hosts: Set<String> = ["itunes.apple.com", "api.podcastindex.org", "open.spotify.com",
                                     "huggingface.co", "github.com", "api.github.com", "release-assets.githubusercontent.com"]
    private var entries: [NetworkEntry] = []
    private let logURL: URL?
    private let session: URLSession

    public init(logURL: URL? = nil, configuration: URLSessionConfiguration? = nil) {
        self.logURL = logURL
        let configuration = configuration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        if let logURL, let data = try? Data(contentsOf: logURL),
           let saved = try? JSONDecoder().decode([NetworkEntry].self, from: data) { entries = saved }
    }

    public func allow(_ url: URL) throws {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host,
              url.user == nil, url.password == nil else { throw NetworkError.denied(url.host ?? "invalid URL") }
        hosts.insert(host.lowercased())
    }

    public func log() -> [NetworkEntry] { entries }

    private func check(_ url: URL, localOnly: Bool) throws {
        guard let host = url.host?.lowercased(), hosts.contains(host),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              !localOnly || Self.isPrivateHost(host) else { throw NetworkError.denied(url.host ?? "invalid URL") }
    }

    public nonisolated static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" || h.hasSuffix(".local") { return true }
        // Only literal ULA IPv6 addresses; no public hostname heuristics.
        if h.contains(":"), h.hasPrefix("fc") || h.hasPrefix("fd") {
            var address = in6_addr()
            return h.withCString { inet_pton(AF_INET6, $0, &address) } == 1
        }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        let p = parts.compactMap { Int($0) }
        guard parts.count == 4, p.count == 4,
              parts.allSatisfy({ !$0.isEmpty && ($0 == "0" || !$0.hasPrefix("0")) && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
              p.allSatisfy({ (0...255).contains($0) }) else { return false }
        return p[0] == 127 || p[0] == 10 || (p[0] == 192 && p[1] == 168) ||
            (p[0] == 172 && (16...31).contains(p[1]))
    }

    private func record(_ request: URLRequest, purpose: String, status: Int?) throws {
        try append(NetworkEntry(method: request.httpMethod ?? "GET", host: request.url?.host ?? "", purpose: purpose, status: status))
    }
    /// External providers own their transport; this entry records invocation, not observed HTTP traffic.
    public func recordExternal(provider: String, purpose: String) throws {
        try append(NetworkEntry(method: "EXTERNAL", host: provider, purpose: purpose, status: nil))
    }
    private func append(_ entry: NetworkEntry) throws {
        entries.append(entry)
        entries = Array(entries.suffix(2000))
        if let logURL {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: logURL, options: .atomic)
        }
    }

    public func data(_ request: URLRequest, purpose: String, localOnly: Bool = false,
                     maximumBytes: Int = 32 * 1024 * 1024, followRedirects: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var request = request
        for _ in 0..<8 {
            guard let url = request.url else { throw NetworkError.invalidResponse }
            try check(url, localOnly: localOnly)
            try record(request, purpose: purpose, status: nil)
            let (bytes, response) = try await session.bytes(for: request)
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw NetworkError.tooLarge }
                data.append(byte)
            }
            guard let response = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
            try record(request, purpose: purpose, status: response.statusCode)
            guard data.count <= maximumBytes else { throw NetworkError.tooLarge }
            if (300..<400).contains(response.statusCode), response.statusCode != 304,
               let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL {
                // Credentials and POST bodies must never be replayed to a redirect, including a same-host
                // HTTP downgrade or a different port. OAuth endpoints are required to answer directly.
                guard followRedirects, request.httpBody == nil, request.value(forHTTPHeaderField: "Authorization") == nil,
                      request.value(forHTTPHeaderField: "X-API-Key") == nil else { throw NetworkError.denied(next.host ?? "redirect") }
                // Model CDNs are part of Hugging Face's signed download chain. Feed redirects are explicitly
                // authorized by the user opening that feed, and so is the artwork it names. Auth and request bodies
                // never cross origins.
                if !localOnly, request.httpMethod == nil || ["GET", "HEAD"].contains(request.httpMethod ?? "GET") {
                    if purpose == "feed" || purpose == "audio" || purpose == "artwork" ||
                        (purpose == "model" && next.scheme == "https" &&
                         (next.host?.hasSuffix(".huggingface.co") == true || next.host?.hasSuffix(".hf.co") == true)) {
                        try allow(next)
                    }
                }
                if next.host != url.host {
                    request.setValue(nil, forHTTPHeaderField: "Authorization")
                    request.setValue(nil, forHTTPHeaderField: "X-API-Key")
                    guard request.httpBody == nil else { throw NetworkError.denied(next.host ?? "redirect") }
                }
                request.url = next
                continue
            }
            return (data, response)
        }
        throw NetworkError.invalidResponse
    }

    /// SSE uses the same allow-list, redirect policy and credential-free log as every other request.
    public func events(_ request: URLRequest, purpose: String,
                       receive: @Sendable (Data) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard let url = request.url else { throw NetworkError.invalidResponse }
        try check(url, localOnly: false)
        try record(request, purpose: purpose, status: nil)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        try record(request, purpose: purpose, status: response.statusCode)
        guard (200..<300).contains(response.statusCode) else { throw NetworkError.status(response.statusCode) }
        var lines: [String] = [], size = 0, lineBytes = Data()
        // AsyncBytes.lines coalesces empty lines on some Foundation versions; SSE requires them.
        for try await byte in bytes {
            try Task.checkCancellation()
            size += 1
            guard size <= 16 * 1024 * 1024 else { throw NetworkError.tooLarge }
            if byte != 10 { lineBytes.append(byte); continue }
            if lineBytes.last == 13 { lineBytes.removeLast() }
            guard let line = String(data: lineBytes, encoding: .utf8) else { throw NetworkError.invalidResponse }
            lineBytes.removeAll(keepingCapacity: true)
            if line.isEmpty {
                if !lines.isEmpty { try await receive(Data(lines.joined(separator: "\n").utf8)); lines = [] }
            } else if line.hasPrefix("data:") {
                let value = String(line.dropFirst(5))
                lines.append(value.hasPrefix(" ") ? String(value.dropFirst()) : value)
            }
        }
        // An event without its blank-line terminator is incomplete and must not be accepted.
    }

    /// Streaming Range download. The partial file and ETag remain usable after a cancelled job or app exit.
    public func download(_ url: URL, to destination: URL, purpose: String = "audio",
                         progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try check(url, localOnly: false)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        let tagURL = destination.appendingPathExtension("etag")
        var offset = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
        var request = URLRequest(url: url)
        if offset > 0, let tag = try? String(contentsOf: tagURL, encoding: .utf8) {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(tag, forHTTPHeaderField: "If-Range")
        } else { offset = 0 }
        var finalRequest = request
        // Resolve redirects with a small HEAD, then stream only after the destination has passed policy.
        var head = request
        head.httpMethod = "HEAD"
        head.setValue(nil, forHTTPHeaderField: "Range")
        let (_, metadata) = try await data(head, purpose: purpose)
        finalRequest.url = metadata.url ?? url
        try check(finalRequest.url!, localOnly: false)
        try record(finalRequest, purpose: purpose, status: nil)
        let response = try await StreamingDownload(partial: partial, tagURL: tagURL, offset: offset, progress: progress)
            .run(finalRequest, configuration: session.configuration)
        try record(finalRequest, purpose: purpose, status: response.statusCode)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
        progress(1)
    }
}
