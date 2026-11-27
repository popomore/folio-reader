import Foundation
import XCTest
@testable import Folio

private actor ControlledRead<Value: Sendable> {
    private var requests: [CheckedContinuation<Value, Error>?] = []

    func read() async throws -> Value {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }

    func waitForRequests(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while requests.count < count {
            guard ContinuousClock.now < deadline else { throw CoreError(message: "The expected read did not start.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func finish(_ index: Int, with result: Result<Value, Error>) {
        requests[index]?.resume(with: result)
        requests[index] = nil
    }
}

@MainActor
final class AsyncStateTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioAsync-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }

    func testReloadBlocksEditorEntryAndStillAppliesAnUneditedResult() async throws {
        let file = base.appendingPathComponent("note.md")
        try Data("# Original".utf8).write(to: file)
        let folder = try await WorkspaceIO.remember(base)
        let first = try await WorkspaceIO.open(folder, path: "note.md")
        let reads = ControlledRead<OpenedFile>()
        let session = DocumentSession(folder: folder, path: "note.md", storage: base.appendingPathComponent("State"),
                                      readFile: { _, _ in try await reads.read() })
        let initial = Task { await session.load() }
        try await reads.waitForRequests(1)
        await reads.finish(0, with: .success(first))
        await initial.value
        XCTAssertTrue(session.canEdit)
        try Data("# Reloaded".utf8).write(to: file)
        let next = try await WorkspaceIO.open(folder, path: "note.md")
        let reload = Task { await session.load() }
        try await reads.waitForRequests(2)
        XCTAssertFalse(session.canEdit)
        session.beginEditing()
        XCTAssertFalse(session.editing)
        await reads.finish(1, with: .success(next))
        await reload.value
        XCTAssertEqual(session.draft, "# Reloaded")
        XCTAssertTrue(session.canEdit)
    }

    func testLayoutReplacementKeepsTheUnpersistedEditorSession() async throws {
        try Data("# Original".utf8).write(to: base.appendingPathComponent("note.md"))
        let folder = try await WorkspaceIO.remember(base)
        let selection = FileSelection(folder: folder, path: "note.md")
        var navigation = LibraryNavigation()
        navigation.open(selection, compact: true)
        let storage = base.appendingPathComponent("State")
        let original = selection.session(storage: storage)
        await original.loadIfNeeded()
        original.beginEditing()
        original.draft = "# Latest unsaved keystroke"
        navigation.adapt(toCompact: false)
        let replacement = try XCTUnwrap(navigation.selected).session(storage: storage)
        XCTAssertTrue(original === replacement)
        await replacement.loadIfNeeded()
        XCTAssertEqual(replacement.draft, "# Latest unsaved keystroke")
        XCTAssertTrue(replacement.editing)
        navigation.adapt(toCompact: true)
        guard case .file(let compact)? = navigation.routes.last else { return XCTFail("The reader route must survive.") }
        XCTAssertTrue(compact.session(storage: storage) === original)
    }

    func testOlderRefreshCannotHideNewFilesOrPublishAnOldError() async throws {
        let reads = ControlledRead<[Entry]>()
        let listing = FolderListing(read: { _, _ in try await reads.read() })
        let folder = SavedFolder(id: UUID(), name: "Project", bookmark: Data())
        let old = Entry(name: "old.md", path: "old.md", directory: false, kind: .other)
        let added = Entry(name: "added.md", path: "added.md", directory: false, kind: .other)
        let initial = Task { await listing.reload(folder, path: "") }
        try await reads.waitForRequests(1)
        await reads.finish(0, with: .success([old]))
        await initial.value
        let older = Task { await listing.reload(folder, path: "") }
        try await reads.waitForRequests(2)
        let newer = Task { await listing.reload(folder, path: "") }
        try await reads.waitForRequests(3)
        await reads.finish(2, with: .success([old, added]))
        await newer.value
        await reads.finish(1, with: .success([old]))
        await older.value
        XCTAssertEqual(listing.entries.map(\.path), ["old.md", "added.md"])
        let failing = Task { await listing.reload(folder, path: "") }
        try await reads.waitForRequests(4)
        let latest = Task { await listing.reload(folder, path: "") }
        try await reads.waitForRequests(5)
        await reads.finish(4, with: .success([added]))
        await latest.value
        await reads.finish(3, with: .failure(CoreError(message: "An obsolete error")))
        await failing.value
        XCTAssertNil(listing.failure)
        XCTAssertEqual(listing.entries.map(\.path), ["added.md"])
        XCTAssertFalse(listing.loading)
    }
}
