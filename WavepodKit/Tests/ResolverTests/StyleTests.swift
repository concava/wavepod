import XCTest

final class StyleTests: XCTestCase {
    func testResolverHasNoSemicolonChainedStatements() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Resolver")
        let pattern = #";\s*(?:self\.|(?:var|let|return)\b|[A-Za-z_]\w*\s*(?:[.+]?=|\())"#
        let regex = try NSRegularExpression(pattern: pattern)
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), file.lastPathComponent)
        }
    }
}
