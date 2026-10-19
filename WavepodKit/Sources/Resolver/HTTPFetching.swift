import Foundation

public protocol HTTPFetching: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse)
}

/// CLI transport. Apps inject their allow-listed, logged client instead.
public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ResolverError.invalidResponse }
        return (data, response)
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
