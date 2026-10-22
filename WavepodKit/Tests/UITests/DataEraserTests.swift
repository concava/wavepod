import XCTest
@testable import UI

final class DataEraserTests: XCTestCase {
    func testRemovesEverythingExceptWhatItKeeps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("erase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["library.sqlite", "artwork/a.png", "audio/x.mp3", "claude/account/settings.json", "models/parakeet/m.bin"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }

        try DataEraser.removeContents(of: root, keeping: ["models"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["models"])
        XCTAssertGreaterThan(DataEraser.size(of: root.appendingPathComponent("models")), 0)

        try DataEraser.removeContents(of: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testMissingFolderIsNotAnError() throws {
        try DataEraser.removeContents(of: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)"))
    }
}
