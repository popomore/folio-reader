import Foundation
import XCTest
@testable import Folio

@MainActor
final class CloudTests: XCTestCase {
    private var base: URL!
    private var source: URL!
    private var connection: CloudConnection!
    private var remote: LocalCloudMetadata!
    private var mac: CloudLibrary!
    private var phone: CloudLibrary!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("FolioCloud-\(UUID().uuidString)").resolvingSymlinksInPath()
        source = base.appendingPathComponent("Original Project")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try Data("# Original\n\nRead on both devices.\n".utf8).write(to: source.appendingPathComponent("Notes.md"))
        try Data([1, 2, 3, 4]).write(to: source.appendingPathComponent("Images/image.png"))
        let root = base.appendingPathComponent("Cloud")
        remote = try LocalCloudMetadata(file: root.appendingPathComponent("metadata.json"))
        connection = CloudConnection(account: "first-account", root: root, metadata: remote, isCurrent: { true }, testOnly: true)
        let connection = connection!
        mac = CloudLibrary(storage: base.appendingPathComponent("Mac"), deviceName: "Fixture Mac") { connection }
        phone = CloudLibrary(storage: base.appendingPathComponent("Phone"), deviceName: "Fixture iPhone") { connection }
        await mac.refresh()
        await phone.refresh()
    }

    override func tearDown() async throws {
        await mac?.flushPositions()
        await phone?.flushPositions()
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    func testSendContinueAndDeleteAcrossDevicesPreservesOriginalAndAssets() async throws {
        let original = try Data(contentsOf: source.appendingPathComponent("Notes.md"))
        let item = try await mac.send(root: source, path: "Notes.md", folder: true)
        mac.recordPosition(item.identity, position: CloudPosition(path: "Notes.md", heading: "original", progress: 0.45))
        await mac.flushPositions()
        await phone.refresh()
        XCTAssertEqual(phone.continuing.map(\.id), [item.id])
        XCTAssertEqual(phone.latestReading(item)?.position.heading, "original")
        XCTAssertEqual(phone.latestReading(item)?.deviceName, "Fixture Mac")
        let opened = try await phone.open(item)
        XCTAssertEqual(try Data(contentsOf: opened.access.root.appendingPathComponent(opened.path)), original)
        XCTAssertEqual(try Data(contentsOf: opened.access.root.appendingPathComponent("Images/image.png")), Data([1, 2, 3, 4]))
        XCTAssertEqual(item.fileCount, 2)
        await phone.delete([item])
        XCTAssertTrue(phone.continuing.isEmpty)
        XCTAssertTrue(phone.copies.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Notes.md")), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Images/image.png").path))
        await mac.refresh()
        XCTAssertTrue(mac.continuing.isEmpty)
        XCTAssertTrue(mac.retired.contains(item.id))
        await fails { try await self.remote.create(item) }
        await fails {
            try await self.remote.record(CloudReading(item: item.identity, deviceID: UUID(), deviceName: "Old Device",
                modified: Date(), position: CloudPosition(progress: 0.9)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudDirectory(item).path))
    }

    func testRemoveDownloadKeepsCloudAndCanDownloadAgain() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        await phone.refresh()
        let first = try await phone.open(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.access.root.path))
        await phone.removeDownload(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.access.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDirectory(item).path))
        XCTAssertEqual(phone.continuing.map(\.id), [item.id])
        let second = try await phone.open(item)
        XCTAssertEqual(try Data(contentsOf: second.access.root.appendingPathComponent("Notes.md")),
                       try Data(contentsOf: source.appendingPathComponent("Notes.md")))
    }

    func testOfflineRequestCanBeCancelledAndDoesNotDeleteOnReconnect() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        await remote.setOffline(true)
        await mac.delete([item])
        XCTAssertEqual(mac.pending(item)?.phase, .queued)
        XCTAssertEqual(mac.pendingCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDirectory(item).path))
        await mac.cancelDeletion(item)
        XCTAssertEqual(mac.pendingCount, 0)
        await remote.setOffline(false)
        await mac.refresh()
        XCTAssertEqual(mac.continuing.map(\.id), [item.id])
        let snapshot = try await remote.snapshot()
        XCTAssertEqual(snapshot.items.first?.state, .active)
    }

    func testOfflineDeletionSurvivesRelaunchAndCompletesAfterReconnect() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        await remote.setOffline(true)
        await mac.delete([item])
        let connection = connection!
        let restarted = CloudLibrary(storage: base.appendingPathComponent("Mac"), deviceName: "Fixture Mac") { connection }
        await restarted.refresh()
        XCTAssertEqual(restarted.pendingCount, 1)
        XCTAssertTrue(restarted.continuing.isEmpty)
        await remote.setOffline(false)
        await restarted.refresh()
        XCTAssertEqual(restarted.pendingCount, 0)
        XCTAssertTrue(restarted.copies.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudDirectory(item).path))
    }

    func testCachedReadingWorksAfterOfflineRelaunch() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        await phone.refresh()
        _ = try await phone.open(item)
        await remote.setOffline(true)
        let connection = connection!
        let restarted = CloudLibrary(storage: base.appendingPathComponent("Phone"), deviceName: "Fixture iPhone") { connection }
        await restarted.refresh()
        let opened = try await restarted.open(item)
        XCTAssertEqual(try Data(contentsOf: opened.access.root.appendingPathComponent(opened.path)),
                       try Data(contentsOf: source.appendingPathComponent("Notes.md")))
    }

    func testBatchFailureKeepsFailedCopyAndRetryIsIdempotent() async throws {
        let first = try await mac.send(root: source, path: "Notes.md", folder: false)
        let second = try await mac.send(root: source, path: "Images/image.png", folder: false)
        await remote.failDeletion(first.id)
        await mac.delete([first, second])
        XCTAssertEqual(mac.copies.map(\.id), [first.id])
        XCTAssertNotNil(mac.itemErrors[first.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudDirectory(second).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDirectory(first).path))
        await remote.clearFailures()
        await mac.refresh()
        await mac.refresh()
        XCTAssertTrue(mac.copies.isEmpty)
        XCTAssertEqual(mac.pendingCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Notes.md").path))
    }

    func testDraftProtectionBlocksCloudDeletionAndLocalEviction() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        _ = try await mac.open(item)
        mac.setProtected(item.identity, true)
        await mac.delete([item])
        XCTAssertEqual(mac.pendingCount, 0)
        XCTAssertTrue(mac.protected(item))
        await mac.removeDownload(item)
        XCTAssertNotNil(mac.itemErrors[item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDirectory(item).path))
        let connection = connection!
        let restarted = CloudLibrary(storage: base.appendingPathComponent("Mac"), deviceName: "Fixture Mac") { connection }
        await restarted.refresh()
        XCTAssertTrue(restarted.protected(item))
        restarted.setProtected(item.identity, false)
        await restarted.delete([item])
        XCTAssertTrue(restarted.copies.isEmpty)
    }

    func testStaleGenerationAndUnownedManifestNeverDeleteData() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        let stale = CloudItem(id: item.id, generation: UUID(), name: item.name, sourceDevice: item.sourceDevice,
            created: item.created, storage: .copy, path: item.path, folderName: item.folderName,
            folderCopy: false, byteCount: item.byteCount, fileCount: 1, revision: item.revision)
        await mac.delete([stale])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDirectory(item).path))
        let wrong = CloudManifest(owner: "another.application", identity: item.identity, path: item.path, revision: item.revision)
        try JSONEncoder().encode(wrong).write(to: cloudDirectory(item).appendingPathComponent(".folio-copy.json"))
        await mac.delete([item])
        XCTAssertNotNil(mac.itemErrors[item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDirectory(item).appendingPathComponent("payload/Notes.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Notes.md").path))
    }

    func testSymbolicLinksCannotEscapeUploadOrDeletionBoundaries() async throws {
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: base)
        await fails { _ = try await self.mac.send(root: self.source, path: "Notes.md", folder: true) }
        try FileManager.default.removeItem(at: source.appendingPathComponent("escape"))
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        let directory = cloudDirectory(item)
        try FileManager.default.moveItem(at: directory, to: directory.appendingPathExtension("saved"))
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: source)
        await mac.delete([item])
        XCTAssertNotNil(mac.itemErrors[item.id])
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("Notes.md"), encoding: .utf8),
                       "# Original\n\nRead on both devices.\n")
    }

    func testSymlinkedCloudParentCannotReceiveOrDeleteCopies() async throws {
        let root = base.appendingPathComponent("Other Cloud")
        let outside = base.appendingPathComponent("User Documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Documents"), withDestinationURL: outside)
        let connection = CloudConnection(account: "first-account", root: root, metadata: remote, isCurrent: { true }, testOnly: true)
        let files = CloudFiles(connection: connection, local: base.appendingPathComponent("Unsafe Sender"))
        await fails { _ = try await files.create(root: self.source, path: "Notes.md", folder: false, device: "Mac") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testOversizedFileIsRejectedBeforePublication() async throws {
        let file = source.appendingPathComponent("Large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(CloudFiles.maximumFileBytes + 1))
        try handle.close()
        await fails { _ = try await self.mac.send(root: self.source, path: "Large.bin", folder: false) }
        let snapshot = try await remote.snapshot()
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testLinkedUserDocumentIsNeverACleanupCandidate() async throws {
        let item = CloudItem(id: UUID(), generation: UUID(), name: "Notes.md", sourceDevice: "Mac", created: Date(),
            storage: .linked, path: "Notes.md", folderName: source.lastPathComponent, folderCopy: false,
            byteCount: nil, fileCount: 1, revision: CloudPaths.digest(try Data(contentsOf: source.appendingPathComponent("Notes.md"))))
        try await remote.create(item)
        await phone.refresh()
        XCTAssertTrue(phone.needsFolder(item))
        try await phone.bind(item, to: source)
        let opened = try await phone.open(item)
        XCTAssertEqual(opened.access.root.resolvingSymlinksInPath().pathComponents, source.pathComponents)
        XCTAssertEqual(try Data(contentsOf: opened.access.root.appendingPathComponent(opened.path)),
                       try Data(contentsOf: source.appendingPathComponent("Notes.md")))
        XCTAssertTrue(phone.copies.isEmpty)
        await phone.delete([item])
        await phone.removeDownload(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Notes.md").path))
        let snapshot = try await remote.snapshot()
        XCTAssertEqual(snapshot.items.first?.state, .active)
    }

    func testAccountChangeNeverReplaysAnotherAccountsPendingDelete() async throws {
        let first = try await mac.send(root: source, path: "Notes.md", folder: false)
        await remote.setOffline(true)
        await mac.delete([first])
        let otherRoot = base.appendingPathComponent("Second Cloud")
        let otherRemote = try LocalCloudMetadata(file: otherRoot.appendingPathComponent("metadata.json"))
        let other = CloudConnection(account: "second-account", root: otherRoot, metadata: otherRemote, isCurrent: { true }, testOnly: true)
        let switched = CloudLibrary(storage: base.appendingPathComponent("Mac"), deviceName: "Mac") { other }
        await switched.refresh()
        XCTAssertEqual(switched.pendingCount, 0)
        XCTAssertTrue(switched.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDirectory(first).path))
        let snapshot = try await otherRemote.snapshot()
        XCTAssertTrue(snapshot.items.isEmpty)
        mac.accountChanged()
        XCTAssertNil(mac.account)
        XCTAssertTrue(mac.items.isEmpty)
    }

    func testReadingPositionsRejectMalformedPathsAndClampUntrustedValues() throws {
        let position = CloudPosition(path: "../../Original", heading: String(repeating: "x", count: 2_000),
                                     block: -1, blockOffset: .infinity, progress: 9, page: -1).sanitized
        XCTAssertNil(position.path)
        XCTAssertNil(position.block)
        XCTAssertNil(position.page)
        XCTAssertEqual(position.progress, 1)
        XCTAssertEqual(position.blockOffset, 0)
        XCTAssertEqual(position.heading?.count, 1_024)
        XCTAssertThrowsError(try CloudPaths.relative("../outside"))
        XCTAssertThrowsError(try CloudPaths.relative("/absolute"))
        XCTAssertThrowsError(try CloudPaths.relative("folder//file"))
    }

    func testLateFileUploadForADeletedGenerationIsPurgedWithoutResurrection() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: true)
        let backup = base.appendingPathComponent("Late Upload")
        try FileManager.default.copyItem(at: cloudDirectory(item), to: backup)
        await phone.refresh()
        await phone.delete([item])
        try FileManager.default.copyItem(at: backup, to: cloudDirectory(item))
        await mac.refresh()
        XCTAssertTrue(mac.continuing.isEmpty)
        XCTAssertTrue(mac.copies.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudDirectory(item).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Notes.md").path))
    }

    func testExternalEditsAndNewFilesInACopyAreKeptDuringCleanup() async throws {
        let first = try await mac.send(root: source, path: "Notes.md", folder: true)
        let edited = cloudDirectory(first).appendingPathComponent("payload/Images/image.png")
        let newBytes = Data("User changed an asset in Files".utf8)
        try newBytes.write(to: edited)
        await mac.delete([first])
        XCTAssertNotNil(mac.itemErrors[first.id])
        XCTAssertEqual(try Data(contentsOf: edited), newBytes)
        let second = try await mac.send(root: source, path: "Notes.md", folder: false)
        let added = cloudDirectory(second).appendingPathComponent("payload/New Work.md")
        try Data("Keep new work".utf8).write(to: added)
        await mac.delete([second])
        XCTAssertNotNil(mac.itemErrors[second.id])
        XCTAssertEqual(try String(contentsOf: added, encoding: .utf8), "Keep new work")
    }

    func testLargeManifestRetainsEveryFolderAsset() async throws {
        for index in 0..<240 {
            try Data("Asset \(index)".utf8).write(to: source.appendingPathComponent(String(format: "asset-%03d.txt", index)))
        }
        let item = try await mac.send(root: source, path: "Notes.md", folder: true)
        XCTAssertEqual(item.fileCount, 242)
        await phone.refresh()
        let opened = try await phone.open(item)
        XCTAssertEqual(try String(contentsOf: opened.access.root.appendingPathComponent("asset-239.txt"), encoding: .utf8), "Asset 239")
        await phone.delete([item])
        XCTAssertTrue(phone.copies.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("asset-239.txt").path))
    }

    func testHandoffPayloadRoundTripsAndRejectsInvalidLocations() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        let activity = NSUserActivity(activityType: CloudEnvironment.activityType)
        CloudContinuation.configure(activity, item: item,
            position: CloudPosition(path: "Notes.md", heading: "original", progress: 0.3, page: 7), folder: nil)
        let continuation = try XCTUnwrap(CloudContinuation.read(activity))
        XCTAssertEqual(continuation.identity, item.identity)
        XCTAssertEqual(continuation.position.heading, "original")
        XCTAssertEqual(continuation.position.page, 7)
        XCTAssertNil(activity.userInfo?["bookmark"])
        activity.addUserInfoEntries(from: ["folderURL": URL(string: "https://example.com/")!])
        XCTAssertNil(CloudContinuation.read(activity))
        activity.userInfo?["folderURL"] = nil
        activity.userInfo?["generation"] = "not-a-uuid"
        XCTAssertNil(CloudContinuation.read(activity))
    }

    func testAccountSwitchCannotBeUndoneByAnOlderRefreshCompletion() async throws {
        _ = try await mac.send(root: source, path: "Notes.md", folder: false)
        let delayed = PausedCloudMetadata(base: remote)
        let old = CloudConnection(account: "first-account", root: connection.root, metadata: delayed, isCurrent: { true }, testOnly: true)
        let otherRoot = base.appendingPathComponent("Different Account")
        let otherRemote = try LocalCloudMetadata(file: otherRoot.appendingPathComponent("metadata.json"))
        let new = CloudConnection(account: "different-account", root: otherRoot, metadata: otherRemote, isCurrent: { true }, testOnly: true)
        let resolver = CloudConnectionSource(old)
        let library = CloudLibrary(storage: base.appendingPathComponent("Mac"), deviceName: "Mac") { await resolver.current() }
        let oldRefresh = Task { await library.refresh() }
        try await delayed.waitUntilPaused()
        XCTAssertFalse(library.items.isEmpty)
        library.accountChanged()
        await resolver.replace(new)
        await library.refresh()
        XCTAssertEqual(library.account, "different-account")
        XCTAssertTrue(library.items.isEmpty)
        await delayed.release()
        await oldRefresh.value
        XCTAssertEqual(library.account, "different-account")
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertNil(library.error)
    }

    func testEditedPrivateDownloadIsKeptBeforeDeletionOrEviction() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        await phone.refresh()
        let opened = try await phone.open(item)
        let file = opened.access.root.appendingPathComponent("Notes.md")
        let edits = Data("# New local work from another app\n".utf8)
        try edits.write(to: file)
        await phone.removeDownload(item)
        XCTAssertEqual(try Data(contentsOf: file), edits)
        await phone.delete([item])
        XCTAssertEqual(phone.pendingCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), edits)
        let snapshot = try await remote.snapshot()
        XCTAssertEqual(snapshot.items.first?.state, .active)
    }

    func testReadingCopyCannotEnterEditingOrReplaceTheSnapshot() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        let opened = try await mac.open(item)
        let folder = try await WorkspaceIO.remember(opened.access.root)
        let model = DocumentSession(folder: folder, path: "Notes.md", storage: base.appendingPathComponent("ReadOnly"), readOnly: true)
        await model.load()
        XCTAssertNotNil(model.opened)
        XCTAssertFalse(model.canEdit)
        model.beginEditing()
        XCTAssertFalse(model.editing)
        model.draft = "# Attempted edit"
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(try Data(contentsOf: opened.access.root.appendingPathComponent("Notes.md")),
                       try Data(contentsOf: source.appendingPathComponent("Notes.md")))
    }

    func testDevelopmentAndProductionUseDifferentCacheAndContentNamespaces() {
        let development = CloudEnvironment.accountKey(token: "same-account", container: "same-container", environment: .development)
        let production = CloudEnvironment.accountKey(token: "same-account", container: "same-container", environment: .production)
        XCTAssertNotEqual(development, production)
        var prod = connection!
        prod.environment = .production
        XCTAssertNotEqual(connection.copies, prod.copies)
        XCTAssertEqual(connection.copies.deletingLastPathComponent(), prod.copies.deletingLastPathComponent())
    }

    func testUnpublishedCopyCanBeDeletedWithoutBeingPublishedOnReconnect() async throws {
        await remote.setOffline(true)
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        XCTAssertTrue(mac.uploading(item))
        XCTAssertTrue(mac.canDelete(item))
        await mac.delete([item])
        XCTAssertEqual(mac.pendingCount, 1)
        await remote.setOffline(false)
        await mac.refresh()
        XCTAssertTrue(mac.copies.isEmpty)
        XCTAssertFalse(mac.uploading(item))
        let snapshot = try await remote.snapshot()
        XCTAssertEqual(snapshot.items.first?.state, .deleted)
        await fails { try await self.remote.create(item) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Notes.md").path))
    }

    func testCancellingDeletionOfAnUnpublishedCopyRetainsTheUploadRequest() async throws {
        await remote.setOffline(true)
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        await mac.delete([item])
        await mac.cancelDeletion(item)
        XCTAssertEqual(mac.pendingCount, 0)
        XCTAssertTrue(mac.uploading(item))
        await remote.setOffline(false)
        await mac.refresh()
        XCTAssertFalse(mac.uploading(item))
        XCTAssertEqual(mac.continuing.map(\.id), [item.id])
        let snapshot = try await remote.snapshot()
        XCTAssertEqual(snapshot.items.first?.state, .active)
    }

    func testFailedActiveCopyDeletionCanBeRetriedExplicitly() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        await remote.failDeletion(item.id)
        await mac.delete([item])
        XCTAssertEqual(mac.item(item.id)?.state, .active)
        XCTAssertEqual(mac.pendingCount, 1)
        await remote.clearFailures()
        await mac.retryDeletion(item)
        XCTAssertTrue(mac.copies.isEmpty)
        XCTAssertEqual(mac.pendingCount, 0)
        let snapshot = try await remote.snapshot()
        XCTAssertEqual(snapshot.items.first?.state, .deleted)
    }

    func testSentDeletionCannotBeReportedAsCancelled() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        await remote.failDeletion(item.id)
        await mac.delete([item])
        XCTAssertEqual(mac.pending(item)?.phase, .requesting)
        await mac.cancelDeletion(item)
        XCTAssertEqual(mac.pendingCount, 1)
        XCTAssertEqual(mac.pending(item)?.phase, .requesting)
        XCTAssertNotNil(mac.itemErrors[item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDirectory(item).path))
    }

    func testCancelledQueuedCopyIsSkippedWhileAnotherBatchDeletionIsInFlight() async throws {
        let first = try await mac.send(root: source, path: "Notes.md", folder: false)
        let second = try await mac.send(root: source, path: "Notes.md", folder: false)
        let gate = PausedDeletionMetadata(base: remote, item: first.id)
        let connection = CloudConnection(account: self.connection.account, root: self.connection.root,
            metadata: gate, isCurrent: { true }, testOnly: true)
        let batch = CloudLibrary(storage: base.appendingPathComponent("Batch"), deviceName: "Fixture Batch") { connection }
        await batch.refresh()
        let work = Task { await batch.delete([first, second]) }
        try await gate.waitUntilPaused()
        XCTAssertEqual(batch.pending(second)?.phase, .queued)
        await batch.cancelDeletion(second)
        XCTAssertNil(batch.pending(second))
        await gate.release()
        await work.value
        XCTAssertEqual(batch.copies.map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDirectory(second).path))
        let snapshot = try await remote.snapshot()
        XCTAssertEqual(snapshot.items.first { $0.id == second.id }?.state, .active)
    }

    func testRemoteDeletionCleansAnotherDevicesPrivateDownload() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        await phone.refresh()
        let opened = try await phone.open(item)
        await mac.delete([item])
        await phone.refresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.access.root.path))
        XCTAssertTrue(phone.copies.isEmpty)
    }

    func testRemoteDeletionKeepsChangedDownloadsVisibleForReview() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        await phone.refresh()
        XCTAssertFalse(phone.canReviewLocalFiles(item))
        let opened = try await phone.open(item)
        let file = opened.access.root.appendingPathComponent("Notes.md")
        let changed = Data("Keep changes from another app.".utf8)
        try changed.write(to: file)
        await mac.delete([item])
        await phone.refresh()
        XCTAssertEqual(try Data(contentsOf: file), changed)
        XCTAssertNotNil(phone.itemErrors[item.id])
        XCTAssertEqual(phone.copies.map(\.id), [item.id])
        XCTAssertTrue(phone.canReviewLocalFiles(try XCTUnwrap(phone.item(item.id))))
        let review = try await phone.openLocalReview(item)
        XCTAssertEqual(try Data(contentsOf: review.access.root.appendingPathComponent("Notes.md")), changed)
    }

    func testIncompletePrivateDownloadIsRebuiltWithEveryAsset() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: true)
        await phone.refresh()
        let opened = try await phone.open(item)
        try FileManager.default.removeItem(at: opened.access.root.appendingPathComponent("Notes.md"))
        let repaired = try await phone.open(item)
        XCTAssertEqual(try Data(contentsOf: repaired.access.root.appendingPathComponent("Notes.md")),
                       try Data(contentsOf: source.appendingPathComponent("Notes.md")))
        XCTAssertEqual(try Data(contentsOf: repaired.access.root.appendingPathComponent("Images/image.png")), Data([1, 2, 3, 4]))
    }

    func testIncompleteDownloadWithOtherEditsIsKeptDuringRepair() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: true)
        await phone.refresh()
        let opened = try await phone.open(item)
        let image = opened.access.root.appendingPathComponent("Images/image.png")
        let changed = Data([8, 9, 10])
        try changed.write(to: image)
        try FileManager.default.removeItem(at: opened.access.root.appendingPathComponent("Notes.md"))
        await fails { _ = try await self.phone.open(item) }
        XCTAssertEqual(try Data(contentsOf: image), changed)
    }

    func testAnOlderRefreshCannotHideACompletedPublication() async throws {
        let gate = StaleSnapshotMetadata(base: remote)
        let connection = CloudConnection(account: self.connection.account, root: self.connection.root,
            metadata: gate, isCurrent: { true }, testOnly: true)
        let library = CloudLibrary(storage: base.appendingPathComponent("Concurrent"), deviceName: "Fixture") { connection }
        await library.refresh()
        await gate.pauseNext()
        let refresh = Task { await library.refresh() }
        try await gate.waitUntilPaused()
        let item = try await library.send(root: source, path: "Notes.md", folder: false)
        XCTAssertFalse(library.uploading(item))
        await gate.release()
        await refresh.value
        XCTAssertEqual(library.continuing.map(\.id), [item.id])
        let opened = try await library.open(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: opened.access.root.appendingPathComponent("Notes.md").path))
        await library.flushPositions()
    }

    func testProtectionIsHeldUntilEveryReaderOwnerReleasesIt() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: true)
        let first = UUID(), second = UUID(), clean = UUID()
        mac.setProtected(item.identity, true, owner: first, document: "Notes.md")
        mac.setProtected(item.identity, false, owner: clean, document: "Notes.md")
        XCTAssertTrue(mac.protected(item))
        mac.setProtected(item.identity, true, owner: second, document: "Notes.md")
        mac.setProtected(item.identity, false, owner: first, document: "Notes.md")
        XCTAssertTrue(mac.protected(item))
        await mac.delete([item])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDirectory(item).path))
        mac.setProtected(item.identity, false, owner: second, document: "Notes.md")
        XCTAssertFalse(mac.protected(item))
    }

    func testAnotherDocumentCannotClearPersistedDraftProtection() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: true)
        mac.setProtected(item.identity, true, owner: UUID(), document: "Images/image.png")
        let connection = connection!
        let restarted = CloudLibrary(storage: base.appendingPathComponent("Mac"), deviceName: "Fixture") { connection }
        await restarted.refresh()
        restarted.setProtected(item.identity, false, owner: UUID(), document: "Notes.md")
        XCTAssertTrue(restarted.protected(item))
        await restarted.removeDownload(item)
        XCTAssertNotNil(restarted.itemErrors[item.id])
    }

    func testFirstLinkedBindingRejectsADifferentSameNamedDocument() async throws {
        let files = CloudFiles(connection: connection, local: base.appendingPathComponent("Link"))
        let item = try await files.link(root: source, path: "Notes.md", device: "Fixture")
        try await remote.create(item)
        await phone.refresh()
        let other = base.appendingPathComponent("Other Project")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("# A different document".utf8).write(to: other.appendingPathComponent("Notes.md"))
        await fails { try await self.phone.bind(item, to: other) }
        XCTAssertTrue(phone.needsFolder(item))
        try await phone.bind(item, to: other, allowChanged: true)
        let opened = try await phone.open(item)
        XCTAssertEqual(try Data(contentsOf: opened.access.root.appendingPathComponent("Notes.md")), Data("# A different document".utf8))
    }

    func testRetirementKeepsRecoveryDraftsAndEditableSourceReaders() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: true)
        let folder = try await WorkspaceIO.remember(source)
        let copy = FileSelection(folder: folder, path: "Notes.md", cloudItem: item)
        let recovered = copy.session(storage: base.appendingPathComponent("Recovery"))
        await recovered.load()
        recovered.draft = "Keep the recovered draft."
        recovered.recovered = true
        var navigation = LibraryNavigation()
        navigation.open(copy, compact: true)
        navigation.retireCloudItems([item.id])
        XCTAssertEqual(navigation.selected?.id, copy.id)
        XCTAssertEqual(recovered.draft, "Keep the recovered draft.")
        XCTAssertNotNil(recovered.error)
        let original = FileSelection(folder: folder, path: "Notes.md", cloudItem: item, readOnly: false)
        let editor = original.session(storage: base.appendingPathComponent("Editable"))
        await editor.load()
        navigation.open(original, compact: true)
        navigation.retireCloudItems([item.id])
        XCTAssertEqual(navigation.selected?.id, original.id)
        XCTAssertNil(editor.sharedItem)
        XCTAssertTrue(editor.canEdit)
    }

    func testFolderAuthorizationUsesHandoffInsteadOfAnOlderCloudPosition() async throws {
        let files = CloudFiles(connection: connection, local: base.appendingPathComponent("Handoff"))
        let item = try await files.link(root: source, path: "Notes.md", device: "Mac")
        try await remote.create(item)
        try await remote.record(CloudReading(item: item.identity, deviceID: UUID(), deviceName: "Mac", modified: Date(),
            position: CloudPosition(path: "Notes.md", heading: "old", progress: 0.1, page: 1)))
        await phone.refresh()
        XCTAssertTrue(phone.needsFolder(item))
        let location = CloudPosition(path: "Notes.md", heading: "handoff", progress: 0.7, page: 7)
        let request = CloudFolderRequest(item: item, position: location)
        let opened = try await request.complete(using: phone, folder: source)
        XCTAssertEqual(opened.position, location)
        XCTAssertFalse(phone.needsFolder(item))
        XCTAssertEqual(try Data(contentsOf: opened.access.root.appendingPathComponent(opened.path)),
                       try Data(contentsOf: source.appendingPathComponent("Notes.md")))
    }

    func testEmptyDirectoriesAddedOutsideFolioArePreservedInCloudAndPrivateDownloads() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: true)
        let added = cloudDirectory(item).appendingPathComponent("payload/Keep this empty folder")
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        await mac.delete([item])
        XCTAssertTrue(FileManager.default.fileExists(atPath: added.path))
        XCTAssertNotNil(mac.itemErrors[item.id])
        try FileManager.default.removeItem(at: added)
        await mac.retryDeletion(try XCTUnwrap(mac.item(item.id)))
        let next = try await mac.send(root: source, path: "Notes.md", folder: true)
        await phone.refresh()
        let opened = try await phone.open(next)
        let local = opened.access.root.appendingPathComponent("Keep this empty folder")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        await phone.removeDownload(next)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        XCTAssertNotNil(phone.itemErrors[next.id])
    }

    func testLargeUnicodeHandoffHeadingKeepsTheDocumentAndReadingPositionUsable() async throws {
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        let activity = NSUserActivity(activityType: CloudEnvironment.activityType)
        CloudContinuation.configure(activity, item: item,
            position: CloudPosition(path: "Notes.md", heading: String(repeating: "👨‍👩‍👧‍👦", count: 1_024), progress: 0.6, page: 7), folder: nil)
        let value = try XCTUnwrap(CloudContinuation.read(activity))
        XCTAssertEqual(value.identity, item.identity)
        XCTAssertEqual(value.position.path, "Notes.md")
        XCTAssertEqual(value.position.progress, 0.6)
        XCTAssertEqual(value.position.page, 7)
        let tracked = try XCTUnwrap(CloudReadingScript.position(["heading": String(repeating: "👨‍👩‍👧‍👦", count: 1_024), "progress": 0.6, "blockOffset": 0], revision: "source"))
        XCTAssertEqual(tracked.progress, 0.6)
    }

    func testFailedMetadataWriteCanBeRetriedAndSurvivesRestart() async throws {
        let parent = base.appendingPathComponent("Blocked metadata")
        let file = parent.appendingPathComponent("metadata.json")
        let metadata = try LocalCloudMetadata(file: file)
        let item = try await mac.send(root: source, path: "Notes.md", folder: false)
        try Data("Block directory creation".utf8).write(to: parent)
        await fails { try await metadata.create(item) }
        let failed = try await metadata.snapshot()
        XCTAssertTrue(failed.items.isEmpty)
        try FileManager.default.removeItem(at: parent)
        try await metadata.create(item)
        let restarted = try LocalCloudMetadata(file: file)
        let saved = try await restarted.snapshot()
        XCTAssertEqual(saved.items, [item])
    }

    func testAccountChangeDuringPublicationRejectsTheReturnedAssociation() async throws {
        let gate = PausedPublicationMetadata(base: remote)
        let old = CloudConnection(account: "first-account", root: connection.root, metadata: gate, isCurrent: { true }, testOnly: true)
        let resolver = CloudConnectionSource(old)
        let library = CloudLibrary(storage: base.appendingPathComponent("Publishing"), deviceName: "Fixture") { await resolver.current() }
        await library.refresh()
        let sending = Task { try await library.send(root: self.source, path: "Notes.md", folder: false) }
        try await gate.waitUntilPaused()
        library.accountChanged()
        let otherRoot = base.appendingPathComponent("Publishing second account")
        let next = CloudConnection(account: "second-account", root: otherRoot,
            metadata: try LocalCloudMetadata(file: otherRoot.appendingPathComponent("metadata.json")), isCurrent: { true }, testOnly: true)
        await resolver.replace(next)
        await library.refresh()
        await gate.release()
        await fails { _ = try await sending.value }
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertNil(library.notice)
    }

    func testLinkedDocumentDoesNotInheritAnotherDocumentsReadingPosition() async throws {
        let files = CloudFiles(connection: connection, local: base.appendingPathComponent("Link tracking"))
        let item = try await files.link(root: source, path: "Notes.md", device: "Mac")
        try await remote.create(item)
        await phone.refresh()
        phone.recordPosition(item.identity, position: CloudPosition(path: "Images/image.png", page: 4))
        XCTAssertNil(phone.latestReading(item))
        try await remote.record(CloudReading(item: item.identity, deviceID: UUID(), deviceName: "Old Mac", modified: Date(),
            position: CloudPosition(path: "Images/image.png", page: 9)))
        await phone.refresh()
        XCTAssertNil(phone.latestReading(item))
        XCTAssertTrue(item.tracks("Notes.md"))
        XCTAssertFalse(item.tracks("Images/image.png"))
    }

    func testFixtureResumesAPartialSeedWithoutReplacingExistingCopies() async throws {
        let storage = base.appendingPathComponent("Partial fixture")
        let first = try CloudFixture.library(storage: storage, device: "Fixture")
        await first.refresh()
        let ids = Set(first.items.map(\.id))
        XCTAssertEqual(ids.count, 2)
        let metadata = storage.appendingPathComponent("FixtureCloud/metadata.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        json["items"] = [items[0]]
        json["readings"] = []
        try JSONSerialization.data(withJSONObject: json).write(to: metadata)
        let restarted = try CloudFixture.library(storage: storage, device: "Fixture")
        await restarted.refresh()
        XCTAssertEqual(Set(restarted.items.map(\.id)), ids)
        XCTAssertNotNil(restarted.items.first.flatMap { restarted.latestReading($0) })
    }

    private func cloudDirectory(_ item: CloudItem) -> URL {
        connection.copies.appendingPathComponent(item.directoryName)
    }
    private func fails(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected the unsafe or stale operation to fail.", file: file, line: line) }
        catch { }
    }
}

private actor CloudConnectionSource {
    private var value: CloudConnection
    init(_ value: CloudConnection) { self.value = value }
    func current() -> CloudConnection { value }
    func replace(_ value: CloudConnection) { self.value = value }
}

private actor PausedPublicationMetadata: CloudMetadata {
    let base: LocalCloudMetadata
    private var continuation: CheckedContinuation<Void, Never>?
    init(base: LocalCloudMetadata) { self.base = base }
    func snapshot() async throws -> CloudSnapshot { try await base.snapshot() }
    func create(_ item: CloudItem) async throws {
        try await base.create(item)
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilPaused() async throws {
        let deadline = Date().addingTimeInterval(5)
        while continuation == nil {
            if Date() > deadline { throw CloudFailure.message("The controlled publication did not start.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func release() { continuation?.resume(); continuation = nil }
    func record(_ reading: CloudReading) async throws { try await base.record(reading) }
    func beginDeletion(_ request: CloudDeletion) async throws -> CloudItem { try await base.beginDeletion(request) }
    func finishDeletion(_ request: CloudDeletion) async throws { try await base.finishDeletion(request) }
}

private actor PausedCloudMetadata: CloudMetadata {
    let base: LocalCloudMetadata
    private var continuation: CheckedContinuation<Void, Never>?
    init(base: LocalCloudMetadata) { self.base = base }
    func snapshot() async throws -> CloudSnapshot {
        await withCheckedContinuation { continuation = $0 }
        return try await base.snapshot()
    }
    func waitUntilPaused() async throws {
        let deadline = Date().addingTimeInterval(5)
        while continuation == nil {
            if Date() > deadline { throw CloudFailure.message("The controlled read did not start.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func release() { continuation?.resume(); continuation = nil }
    func create(_ item: CloudItem) async throws { try await base.create(item) }
    func record(_ reading: CloudReading) async throws { try await base.record(reading) }
    func beginDeletion(_ request: CloudDeletion) async throws -> CloudItem { try await base.beginDeletion(request) }
    func finishDeletion(_ request: CloudDeletion) async throws { try await base.finishDeletion(request) }
}

private actor PausedDeletionMetadata: CloudMetadata {
    let base: LocalCloudMetadata
    let item: UUID
    private var continuation: CheckedContinuation<Void, Never>?
    init(base: LocalCloudMetadata, item: UUID) { self.base = base; self.item = item }
    func snapshot() async throws -> CloudSnapshot { try await base.snapshot() }
    func create(_ item: CloudItem) async throws { try await base.create(item) }
    func record(_ reading: CloudReading) async throws { try await base.record(reading) }
    func beginDeletion(_ request: CloudDeletion) async throws -> CloudItem {
        if request.id == item { await withCheckedContinuation { continuation = $0 } }
        return try await base.beginDeletion(request)
    }
    func finishDeletion(_ request: CloudDeletion) async throws { try await base.finishDeletion(request) }
    func waitUntilPaused() async throws {
        let deadline = Date().addingTimeInterval(5)
        while continuation == nil {
            if Date() > deadline { throw CloudFailure.message("The controlled deletion did not start.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor StaleSnapshotMetadata: CloudMetadata {
    let base: LocalCloudMetadata
    private var pause = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(base: LocalCloudMetadata) { self.base = base }
    func pauseNext() { pause = true }
    func snapshot() async throws -> CloudSnapshot {
        let captured = try await base.snapshot()
        if pause { pause = false; await withCheckedContinuation { continuation = $0 } }
        return captured
    }
    func waitUntilPaused() async throws {
        let deadline = Date().addingTimeInterval(5)
        while continuation == nil {
            if Date() > deadline { throw CloudFailure.message("The controlled snapshot did not start.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func release() { continuation?.resume(); continuation = nil }
    func create(_ item: CloudItem) async throws { try await base.create(item) }
    func record(_ reading: CloudReading) async throws { try await base.record(reading) }
    func beginDeletion(_ request: CloudDeletion) async throws -> CloudItem { try await base.beginDeletion(request) }
    func finishDeletion(_ request: CloudDeletion) async throws { try await base.finishDeletion(request) }
}
