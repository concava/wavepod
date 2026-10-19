import Foundation
import Resolver

@main
struct ResolveCommand {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: wavepod-resolve <link>\n".utf8))
            exit(2)
        }
        do {
            let bin = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("wavepod/bin/yt-dlp")
            let extractor = FileManager.default.isExecutableFile(atPath: bin.path) ? YtDlpExtractor(executable: bin) : nil
            let resolution = try await Resolver(fetcher: URLSessionFetcher(), extractor: extractor).resolve(CommandLine.arguments[1])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write(try encoder.encode(resolution))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
