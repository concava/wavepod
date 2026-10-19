import Foundation
import XCTest
@testable import Resolver

struct FixtureFetcher: HTTPFetching {
    struct UnexpectedURL: Error { let url: URL }
    var files: [URL: String]
    var headers: [URL: [String: String]] = [:]
    var status = 200
    var reportsUnexpectedTraffic = true

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        guard let file = files[url] else {
            if reportsUnexpectedTraffic { XCTFail("Unexpected traffic: \(url.absoluteString)") }
            throw UnexpectedURL(url: url)
        }
        for (key, value) in self.headers[url] ?? [:] { XCTAssertEqual(headers[key], value) }
        return (try fixture(file), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name))
}

func url(_ text: String) -> URL { URL(string: text)! }
