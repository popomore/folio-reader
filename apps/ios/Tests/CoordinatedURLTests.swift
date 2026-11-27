import Foundation
import XCTest
@testable import Folio

private struct RelocatingCoordination: FileCoordinating {
    let destination: URL
    func coordinate<T>(at url: URL, writing: Bool, _ operation: (URL) throws -> T) throws -> T {
        try FileManager.default.moveItem(at: url, to: destination)
        return try operation(destination)
    }
}

private struct RedirectedCoordination: FileCoordinating {
    let destination: URL
    func coordinate<T>(at url: URL, writing: Bool, _ operation: (URL) throws -> T) throws -> T {
        try operation(destination)
    }
}

@MainActor
final class CoordinatedURLTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var folder: SavedFolder!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioCoordination-\(UUID())")
        root = base.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folder = try await WorkspaceIO.remember(root)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }

    func testReadUsesTheFileMovedWhileCoordinationWaits() async throws {
        try Data("# Moved content".utf8).write(to: root.appendingPathComponent("old.md"))
        let moved = root.appendingPathComponent("new.md")
        let result = try await WorkspaceIO.open(folder, path: "old.md",
                                                coordination: RelocatingCoordination(destination: moved))
        XCTAssertEqual(result.document.source, "# Moved content")
    }

    func testSaveUsesTheMovedFileAndRetainsRevisionChecking() async throws {
        try Data("# Original".utf8).write(to: root.appendingPathComponent("old.md"))
        let document = try await WorkspaceIO.open(folder, path: "old.md").document
        let revision = try XCTUnwrap(document.revision)
        let moved = root.appendingPathComponent("new.md")
        _ = try await WorkspaceIO.save(folder, path: "old.md", revision: revision, source: "# Saved",
                                       coordination: RelocatingCoordination(destination: moved))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "# Saved")
        do {
            _ = try await WorkspaceIO.save(folder, path: "new.md", revision: revision, source: "# Stale")
            XCTFail("The original revision must not overwrite the saved file.")
        } catch {}
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "# Saved")
    }

    func testListUsesTheDirectoryMovedWhileCoordinationWaits() async throws {
        let notes = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("# Note".utf8).write(to: notes.appendingPathComponent("note.md"))
        let entries = try await WorkspaceIO.list(folder, path: "Notes",
                                                  coordination: RelocatingCoordination(destination: root.appendingPathComponent("Archive")))
        XCTAssertEqual(entries.map(\.name), ["note.md"])
    }

    func testNativeSnapshotUsesTheCoordinatedFile() async throws {
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("old.png"))
        let result = try await WorkspaceIO.open(folder, path: "old.png",
                                                coordination: RelocatingCoordination(destination: root.appendingPathComponent("new.png")))
        let copy = try XCTUnwrap(result.preview?.url)
        XCTAssertEqual(copy.lastPathComponent, "new.png")
        XCTAssertEqual(try Data(contentsOf: copy), Data([1, 2, 3]))
    }

    func testEveryWorkspaceOperationRejectsACoordinatedURLOutsideTheFolder() async throws {
        let original = root.appendingPathComponent("note.md")
        try Data("# Original".utf8).write(to: original)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("image.png"))
        let outside = base.appendingPathComponent("outside.png")
        try Data([9, 9, 9]).write(to: outside)
        let redirect = RedirectedCoordination(destination: outside)
        let document = try await WorkspaceIO.open(folder, path: "note.md").document
        do {
            _ = try await WorkspaceIO.open(folder, path: "note.md", coordination: redirect)
            XCTFail("A coordinated read must remain in the selected folder.")
        } catch {}
        do {
            _ = try await WorkspaceIO.list(folder, coordination: RedirectedCoordination(destination: base))
            XCTFail("A coordinated listing must remain in the selected folder.")
        } catch {}
        do {
            _ = try await WorkspaceIO.save(folder, path: "note.md", revision: try XCTUnwrap(document.revision),
                                           source: "# Forbidden", coordination: redirect)
            XCTFail("A coordinated save must remain in the selected folder.")
        } catch {}
        let access = try FolderAccess(folder: folder)
        XCTAssertThrowsError(try WorkspaceIO.image("image.png", access: access, coordination: redirect))
        do {
            _ = try await WorkspaceIO.export(folder, path: "note.md", coordination: redirect)
            XCTFail("A coordinated export must remain in the selected folder.")
        } catch {}
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "# Original")
        XCTAssertEqual(try Data(contentsOf: outside), Data([9, 9, 9]))
    }
}
