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

        XCTAssertEqual(DataEraser.removeContents(of: root, keeping: ["models"]), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["models"])
        XCTAssertGreaterThan(DataEraser.size(of: root.appendingPathComponent("models")), 0)

        DataEraser.removeContents(of: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testAnItemThatCantBeDeletedIsNamedAndTheRestGoes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("erase-\(UUID().uuidString)")
        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("inside"))
        try Data("x".utf8).write(to: root.appendingPathComponent("library.sqlite"))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }

        XCTAssertEqual(DataEraser.removeContents(of: root), ["locked"])
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("library.sqlite").path))
    }

    func testMissingFolderIsNotAnError() throws {
        XCTAssertEqual(DataEraser.removeContents(of: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)")), [])
    }
}
