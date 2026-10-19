import XCTest
import CryptoKit
@testable import Resolver

private struct FixtureProcess: ProcessExecuting {
    var status: Int32 = 0
    func run(executable: URL, arguments: [String]) async throws -> ProcessOutput {
        XCTAssertEqual(executable.path, "/fixture/yt-dlp")
        XCTAssertEqual(arguments, ["-J", "--no-playlist", "https://www.youtube.com/watch?v=abcdefghijk"])
        return ProcessOutput(data: try fixture("video.json"), status: status)
    }
}

@MainActor
final class ExtractorTests: XCTestCase {
    func testYtDlpMetadataThroughFacade() async throws {
        let extractor = YtDlpExtractor(executable: url("file:///fixture/yt-dlp"), process: FixtureProcess())
        let resolver = Resolver(fetcher: FixtureFetcher(files: [:]), extractor: extractor)
        guard case .episode(let episode) = try await resolver.resolve("https://youtu.be/abcdefghijk?t=5") else { return XCTFail("Expected video") }
        XCTAssertEqual(episode.title, "An Invented Video")
        XCTAssertEqual(episode.showTitle, "Workshop Films")
        XCTAssertEqual(episode.guid, "abcdefghijk")
        XCTAssertEqual(episode.duration, 123.5)
        XCTAssertEqual(episode.pubDate, FeedValueParser.date("2026-09-17T00:00:00Z"))
        XCTAssertEqual(episode.source, .youtube)
        XCTAssertNil(episode.enclosureURL)
        XCTAssertNil(episode.feedURL)
        let failing = YtDlpExtractor(executable: url("file:///fixture/yt-dlp"), process: FixtureProcess(status: 1))
        do {
            _ = try await failing.extract(url("https://www.youtube.com/watch?v=abcdefghijk"))
            XCTFail("Expected process failure")
        } catch let error as ResolverError { XCTAssertEqual(error, .processFailed) }
    }

    func testCachedFormattersParseConcurrently() async {
        let extractor = YtDlpExtractor(executable: url("file:///fixture/yt-dlp"), process: FixtureProcess())
        let videoURL = url("https://www.youtube.com/watch?v=abcdefghijk")
        let expected = Date(timeIntervalSince1970: 1_789_603_200)
        let inputs = ["2026-09-17T00:00:00Z", "2026-09-17T00:00:00.000Z",
                      "Thu, 17 Sep 2026 00:00:00 GMT", "17 Sep 2026 00:00 +0000"]
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<100 {
                group.addTask {
                    guard FeedValueParser.date(inputs[index % inputs.count]) == expected,
                          FeedValueParser.date("bad date") == nil else { return false }
                    return (try? await extractor.extract(videoURL).pubDate) == expected
                }
            }
            for await result in group { XCTAssertTrue(result) }
        }
    }

    func testInstallerVerifiedFixtureAndReplacement() async throws {
        let bytes = try fixture("installer.bin")
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fetcher = FixtureFetcher(files: [YtDlpInstaller.assetURL: "installer.bin"])
        let installer = YtDlpInstaller(fetcher: fetcher, expectedSHA256: digest)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try await installer.install(in: directory)
        XCTAssertEqual(try Data(contentsOf: executable), bytes)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let replacement = try await installer.install(in: directory)
        XCTAssertEqual(replacement, executable)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["yt-dlp"])
    }

    func testInstallerMismatchLeavesNoDownloadAndPreservesExistingBinary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = YtDlpInstaller(fetcher: FixtureFetcher(files: [YtDlpInstaller.assetURL: "installer.bin"]))
        do {
            _ = try await installer.install(in: directory)
            XCTFail("Expected checksum mismatch")
        } catch let error as ResolverError { XCTAssertEqual(error, .checksumMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appendingPathComponent("yt-dlp")
        try Data("older verified version".utf8).write(to: existing)
        do {
            _ = try await installer.install(in: directory)
            XCTFail("Expected mismatch")
        } catch let error as ResolverError { XCTAssertEqual(error, .checksumMismatch) }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "older verified version")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["yt-dlp"])
        XCTAssertEqual(YtDlpInstaller.release, "2026.08.19")
    }
}
