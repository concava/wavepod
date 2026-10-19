import Foundation
import Networking

public protocol HTTPFetching: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse)
}

/// CLI and app use the same logged transport. Feed metadata may introduce enclosure/CDN hosts.
public struct URLSessionFetcher: HTTPFetching {
    private let client: HTTPClient
    public init(client: HTTPClient = .shared) { self.client = client }
    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        try await client.allow(url)
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        return try await client.data(request, purpose: "feed", maximumBytes: 128 * 1024 * 1024)
    }
}

extension HTTPFetching {
    func data(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        let (data, response) = try await get(url, headers: headers)
        guard (200..<300).contains(response.statusCode) else { throw ResolverError.httpStatus(response.statusCode) }
        return data
    }
}

func endpoint(_ base: String, _ query: [(String, String)]) -> URL {
    var parts = URLComponents(string: base)!
    parts.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
    return parts.url!
}

func decodeResponse<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw ResolverError.invalidResponse }
}
