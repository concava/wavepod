import Foundation
import CryptoKit
import Darwin

public protocol MediaExtractor: Sendable {
    func extract(_ url: URL) async throws -> ResolvedEpisode
}

public struct ProcessOutput: Sendable {
    public var data: Data
    public var status: Int32
    public init(data: Data, status: Int32) {
        self.data = data
        self.status = status
    }
}

public protocol ProcessExecuting: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> ProcessOutput
}

public struct SystemProcessExecutor: ProcessExecuting {
    public init() {}

    public func run(executable: URL, arguments: [String]) async throws -> ProcessOutput {
        try await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Drain before waiting: a JSON response can exceed the pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessOutput(data: data, status: process.terminationStatus)
        }.value
    }
}

public struct YtDlpExtractor: MediaExtractor {
    // DateFormatter supports concurrent parsing on macOS 14+. This instance is never mutated after setup.
    private static let uploadDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    let executable: URL
    let process: any ProcessExecuting
    public init(executable: URL, process: any ProcessExecuting = SystemProcessExecutor()) {
        self.executable = executable
        self.process = process
    }

    public func extract(_ url: URL) async throws -> ResolvedEpisode {
        let output: ProcessOutput
        do { output = try await process.run(executable: executable, arguments: ["--ignore-config", "--no-plugin-dirs", "-J", "--no-playlist", "-f", "bestaudio[ext=m4a]", url.absoluteString]) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ResolverError.processFailed }
        guard output.status == 0 else { throw ResolverError.processFailed }
        let video = try decodeResponse(Video.self, from: output.data)
        return ResolvedEpisode(title: video.title, enclosureURL: video.url, showTitle: video.uploader ?? video.channel,
                               pubDate: video.upload_date.flatMap(Self.uploadDateFormatter.date(from:)), duration: video.duration,
                               guid: video.id, artwork: video.thumbnail, descriptionHTML: video.description, source: .youtube)
    }

    private struct Video: Decodable {
        var id: String
        var url: URL?
        var title: String
        var uploader: String?
        var channel: String?
        var upload_date: String?
        var duration: Double?
        var thumbnail: URL?
        var description: String?
    }
}

public struct YtDlpInstaller: Sendable {
    public static let release = "2026.08.19"
    public static let assetURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos")!
    public static let sha256 = "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"
    let fetcher: any HTTPFetching
    let expectedSHA256: String

    public init(fetcher: any HTTPFetching) {
        self.fetcher = fetcher
        self.expectedSHA256 = Self.sha256
    }

    // Internal override allows synthetic fixture bytes without weakening the public pin.
    init(fetcher: any HTTPFetching, expectedSHA256: String) {
        self.fetcher = fetcher
        self.expectedSHA256 = expectedSHA256
    }

    public func install(in directory: URL) async throws -> URL {
        let data = try await fetcher.data(Self.assetURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // Unverified bytes exist only in memory; no download remains after a mismatch.
        guard digest == expectedSHA256 else { throw ResolverError.checksumMismatch }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".yt-dlp-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        let result = temporary.path.withCString { removexattr($0, "com.apple.quarantine", 0) }
        guard result == 0 || errno == ENOATTR else { throw CocoaError(.fileWriteNoPermission) }
        let destination = directory.appendingPathComponent("yt-dlp")
        // rename atomically replaces an older installed version, without following a destination symlink.
        let renamed = temporary.path.withCString { from in destination.path.withCString { to in rename(from, to) } }
        guard renamed == 0 else { throw CocoaError(.fileWriteUnknown) }
        return destination
    }
}
