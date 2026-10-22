import AppKit
import Networking
import XCTest
@testable import UI

private final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ArtworkCacheTests: XCTestCase {
    private func client() -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkProtocol.self]
        return HTTPClient(configuration: configuration)
    }
    private func png() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testDownloadsOnceThroughTheLoggedClientAndReusesTheDiskCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        ArtworkProtocol.body = try png(); ArtworkProtocol.requests = 0
        let url = URL(string: "https://cdn.example.invalid/show.png")!
        let client = client()
        let first = await ArtworkCache(directory: folder, client: client).image(for: url)
        XCTAssertEqual(first, ArtworkProtocol.body)
        let entries = await client.log()
        XCTAssertTrue(entries.contains { $0.purpose == "artwork" && $0.host == "cdn.example.invalid" && $0.status == 200 })
        // A new cache (a relaunch) reads the saved file instead of the network.
        let second = await ArtworkCache(directory: folder, client: client).image(for: url)
        XCTAssertEqual(second, ArtworkProtocol.body)
        XCTAssertEqual(ArtworkProtocol.requests, 1)
    }

    func testNonImageResponsesAreNotKeptOrRetried() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        ArtworkProtocol.body = Data("<html>not an image</html>".utf8); ArtworkProtocol.requests = 0
        let cache = ArtworkCache(directory: folder, client: client())
        let url = URL(string: "https://cdn.example.invalid/broken.png")!
        let first = await cache.image(for: url)
        let second = await cache.image(for: url)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(ArtworkProtocol.requests, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
