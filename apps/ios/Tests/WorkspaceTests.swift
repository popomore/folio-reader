import Foundation
import XCTest
@testable import Folio

@MainActor
final class WorkspaceTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioTests-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }

    func testCoordinatedReadSaveAndConflictPreserveOriginalBytes() async throws {
        let root = base.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("note.md")
        try Data([0xef, 0xbb, 0xbf] + Array("# Original\r\n".utf8)).write(to: file)
        let folder = try await WorkspaceIO.remember(root)
        let document = try await WorkspaceIO.open(folder, path: "note.md").document
        let revision = try XCTUnwrap(document.revision)
        XCTAssertTrue(try XCTUnwrap(document.preview).html.contains("Original"))
        let saved = try await WorkspaceIO.save(folder, path: "note.md", revision: revision, source: "# Saved\n")
        XCTAssertNotEqual(saved, revision)
        XCTAssertEqual(try Data(contentsOf: file), Data([0xef, 0xbb, 0xbf] + Array("# Saved\r\n".utf8)))
        do {
            _ = try await WorkspaceIO.save(folder, path: "note.md", revision: revision, source: "Do not overwrite")
            XCTFail("A stale save must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed on disk")) }
        XCTAssertEqual(try Data(contentsOf: file), Data([0xef, 0xbb, 0xbf] + Array("# Saved\r\n".utf8)))
    }

    func testFolderListingAndImageAccessEnforceTheSelectedBoundary() async throws {
        let root = base.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: root.appendingPathComponent(".hidden"))
        try Data("# Note".utf8).write(to: root.appendingPathComponent("note.md"))
        let outside = base.appendingPathComponent("outside.png")
        try Data([1, 2, 3]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.png"), withDestinationURL: outside)
        let folder = try await WorkspaceIO.remember(root)
        let entries = try await WorkspaceIO.list(folder)
        XCTAssertEqual(entries.map(\.name), ["Notes", "note.md"])
        let access = try FolderAccess(folder: folder)
        for path in ["../outside.png", "escape.png", ".git/config", "/outside.png", "note.md"] {
            XCTAssertThrowsError(try WorkspaceIO.image(path, access: access), path)
        }
        do {
            _ = try await WorkspaceIO.open(folder, path: "../outside.png")
            XCTFail("Reading outside the folder must fail")
        } catch {}
    }

    func testImportedFilesAreCopiesAndLibraryBookmarksSurviveRelaunch() async throws {
        let source = base.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("# Imported".utf8).write(to: source.appendingPathComponent("note.md"))
        try Data("Unselected".utf8).write(to: source.appendingPathComponent("sibling.txt"))
        let store = LibraryStore(base: base.appendingPathComponent("App"))
        let folder = try await store.importFiles([source.appendingPathComponent("note.md")])
        _ = try await store.importFiles([source.appendingPathComponent("note.md")])
        let entries = try await WorkspaceIO.list(folder)
        XCTAssertEqual(Set(entries.map(\.name)), ["note.md", "note 2.md"])
        store.record(folder, path: "note.md")
        let restored = LibraryStore(base: base.appendingPathComponent("App"))
        XCTAssertEqual(restored.folders.map(\.id), [folder.id])
        XCTAssertEqual(restored.recent.first?.path, "note.md")
        let imported = try await WorkspaceIO.open(restored.folders[0], path: "note.md")
        let revision = try XCTUnwrap(imported.document.revision)
        _ = try await WorkspaceIO.save(folder, path: "note.md", revision: revision, source: "Edited copy")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("note.md"), encoding: .utf8), "# Imported")
        restored.remove(folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try FolderAccess(folder: folder).root.path))
        XCTAssertTrue(LibraryStore(base: base.appendingPathComponent("App")).folders.isEmpty)
    }

    func testNativePreviewsUsePrivateSnapshotsAndRejectOversizedFiles() async throws {
        let file = base.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: file)
        let folder = try await WorkspaceIO.remember(base)
        var opened: OpenedFile? = try await WorkspaceIO.open(folder, path: "image.png")
        let copy = try XCTUnwrap(opened?.preview?.url)
        XCTAssertNotEqual(copy, file)
        XCTAssertEqual(try Data(contentsOf: copy), Data([1, 2, 3]))
        opened = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        let large = base.appendingPathComponent("large.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(WorkspaceIO.maximumPreviewBytes + 1))
        try handle.close()
        do {
            _ = try await WorkspaceIO.open(folder, path: "large.pdf")
            XCTFail("Oversized native files must not be loaded")
        } catch { XCTAssertTrue(error.localizedDescription.contains("128 MiB")) }
    }

    func testInvalidBatchImportDoesNotLeavePartialFilesOrFollowLinks() async throws {
        let source = base.appendingPathComponent("note.md")
        try Data("# Original".utf8).write(to: source)
        let destination = base.appendingPathComponent("Imports")
        do {
            _ = try await WorkspaceIO.importFiles([source, base], into: destination)
            XCTFail("A batch containing a directory must fail")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        let link = base.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do {
            _ = try await WorkspaceIO.importFiles([link], into: destination)
            XCTFail("Importing a symbolic link must fail")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "# Original")
    }

    func testRefreshingAMovedBookmarkPreservesFolderIdentityAndRecovery() async throws {
        let root = base.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Original".utf8).write(to: root.appendingPathComponent("note.md"))
        let store = LibraryStore(base: base.appendingPathComponent("App"))
        let folder = try await store.add(root)
        store.record(folder, path: "note.md")
        let session = DocumentSession(folder: folder, path: "note.md", storage: store.storage)
        await session.load()
        session.draft = "# Recover this draft"
        await session.persistDraft()
        let moved = base.appendingPathComponent("Renamed")
        try FileManager.default.moveItem(at: root, to: moved)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: folder.bookmark, options: .withoutUI,
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.standardizedFileURL, moved.standardizedFileURL)
        XCTAssertTrue(stale, "The fixture must exercise a stale bookmark.")
        let refreshed = try await store.add(moved)
        XCTAssertEqual(refreshed.id, folder.id)
        XCTAssertEqual(store.folders.count, 1)
        XCTAssertEqual(store.recent.first?.folderID, refreshed.id)
        XCTAssertNoThrow(try FolderAccess(folder: refreshed))
        let recovered = DocumentSession(folder: refreshed, path: "note.md", storage: store.storage)
        await recovered.load()
        XCTAssertEqual(recovered.draft, "# Recover this draft")
        XCTAssertTrue(recovered.recovered)
        let distinct = base.appendingPathComponent("Another Project")
        try FileManager.default.createDirectory(at: distinct, withIntermediateDirectories: true)
        let another = try await store.add(distinct)
        XCTAssertNotEqual(another.id, folder.id)
        XCTAssertEqual(store.folders.count, 2)
    }

    func testSuccessfulSaveClearsTheRecoveryDraft() async throws {
        try Data("# Original".utf8).write(to: base.appendingPathComponent("note.md"))
        let folder = try await WorkspaceIO.remember(base)
        let storage = base.appendingPathComponent("State")
        let session = DocumentSession(folder: folder, path: "note.md", storage: storage)
        await session.load()
        session.draft = "# Saved draft"
        await session.persistDraft()
        let saved = await session.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(session.hasChanges)
        let restored = DocumentSession(folder: folder, path: "note.md", storage: storage)
        await restored.load()
        XCTAssertFalse(restored.recovered)
        XCTAssertFalse(restored.hasChanges)
        XCTAssertEqual(restored.draft, "# Saved draft")
    }

    func testUndoingAllEditsRemovesTheRecoveryDraft() async throws {
        try Data("# Original".utf8).write(to: base.appendingPathComponent("note.md"))
        let folder = try await WorkspaceIO.remember(base)
        let storage = base.appendingPathComponent("State")
        let session = DocumentSession(folder: folder, path: "note.md", storage: storage)
        await session.load()
        session.draft = "# Undone edit"
        await session.persistDraft()
        session.draft = "# Original"
        await session.persistDraft()
        let restored = DocumentSession(folder: folder, path: "note.md", storage: storage)
        await restored.load()
        XCTAssertFalse(restored.recovered)
        XCTAssertEqual(restored.draft, "# Original")
    }

    func testFailedSaveKeepsARecoverableDraftUntilExplicitDiscard() async throws {
        let file = base.appendingPathComponent("note.md")
        try Data("# Original".utf8).write(to: file)
        let folder = try await WorkspaceIO.remember(base)
        let storage = base.appendingPathComponent("State")
        let session = DocumentSession(folder: folder, path: "note.md", storage: storage)
        await session.load()
        session.draft = "# My unsaved draft"
        await session.persistDraft()
        try Data("# Changed elsewhere".utf8).write(to: file)
        let saved = await session.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(session.draft, "# My unsaved draft")
        XCTAssertTrue(session.hasChanges)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Changed elsewhere")
        let recovered = DocumentSession(folder: folder, path: "note.md", storage: storage)
        await recovered.load()
        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.draft, session.draft)
        let overwritten = await recovered.save()
        XCTAssertFalse(overwritten)
        await recovered.discard()
        XCTAssertFalse(recovered.hasChanges)
        XCTAssertFalse(recovered.recovered)
        XCTAssertEqual(recovered.draft, "# Changed elsewhere")
        let reopened = DocumentSession(folder: folder, path: "note.md", storage: storage)
        await reopened.load()
        XCTAssertFalse(reopened.recovered)
    }
}
