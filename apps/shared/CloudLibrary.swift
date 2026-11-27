@preconcurrency import CloudKit
import Foundation
import Observation
#if os(macOS)
import Security
#endif

enum CloudEnvironment {
    static let containerID = "iCloud.org.popomore.folio"
    static let activityType = "org.popomore.folio.reading"
    static func accountKey(token: String, container: String, environment: CloudMode) -> String {
        CloudPaths.digest(Data("\(token)/\(container)/\(environment.rawValue)".utf8))
    }

    static func accountToken() -> String? {
        guard let token = FileManager.default.ubiquityIdentityToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else { return nil }
        return CloudPaths.digest(data)
    }

    static func connect(storage: URL) async throws -> CloudConnection {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String],
              services.contains("CloudKit"), services.contains("CloudDocuments") else { throw CloudFailure.notEnabled }
        #endif
        let identifier = Bundle.main.object(forInfoDictionaryKey: "FolioCloudContainer") as? String ?? containerID
        guard let environment = CloudMode(rawValue: Bundle.main.object(forInfoDictionaryKey: "FolioCloudEnvironment") as? String ?? "Development") else {
            throw CloudFailure.notEnabled
        }
        #if os(macOS)
        if let signed = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-environment" as CFString, nil) as? String,
           signed != environment.rawValue { throw CloudFailure.notEnabled }
        #endif
        let resolved = await Task.detached(priority: .utility) { () -> (String, URL)? in
            guard let token = accountToken(),
                  let root = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else { return nil }
            return (token, root.resolvingSymlinksInPath())
        }.value
        guard let (token, root) = resolved else { throw CloudFailure.unavailable }
        let scope = accountKey(token: token, container: identifier, environment: environment)
        let container = CKContainer(identifier: identifier)
        let identityFile = storage.appendingPathComponent("account-\(scope).record-id")
        let user: CKRecord.ID
        if let data = try? Data(contentsOf: identityFile),
           let cached = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.ID.self, from: data) { user = cached }
        else {
            user = try await container.userRecordID()
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try NSKeyedArchiver.archivedData(withRootObject: user, requiringSecureCoding: true)
                .write(to: identityFile, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        guard accountToken() == token else { throw CloudFailure.accountChanged }
        return CloudConnection(account: scope, root: root,
            metadata: AppleCloudMetadata(container: container, account: user),
            isCurrent: { accountToken() == token }, environment: environment)
    }
}

@MainActor @Observable
final class CloudLibrary {
    private struct Cache: Codable {
        var items: [CloudItem] = []
        var readings: [CloudReading] = []
        var uploads: [CloudItem] = []
        var positions: [CloudReading] = []
        var deletions: [CloudDeletion] = []
        var bindings: [UUID: Data] = [:]
        var protected: Set<UUID> = []
    }

    private var cache = Cache()
    private let storage: URL
    private let resolve: @Sendable () async throws -> CloudConnection
    private var connection: CloudConnection?
    private var files: CloudFiles?
    private var documents: CloudDocumentsObserver?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var sessionVersion = UUID()
    private var readingTasks: [UUID: Task<Void, Never>] = [:]
    private var busyItems: Set<UUID> = []
    private(set) var account: String?
    private(set) var refreshing = false
    private(set) var sharing = false
    private(set) var itemErrors: [UUID: String] = [:]
    var error: String?
    var notice: String?
    private(set) var eviction: CloudEviction?
    let deviceID: UUID
    let deviceName: String

    init(storage: URL, deviceName: String,
         resolve: (@Sendable () async throws -> CloudConnection)? = nil) {
        self.storage = storage
        self.deviceName = deviceName
        self.resolve = resolve ?? { try await CloudEnvironment.connect(storage: storage) }
        let identity = storage.appendingPathComponent("device-id")
        if let text = try? String(contentsOf: identity, encoding: .utf8), let id = UUID(uuidString: text) { deviceID = id }
        else {
            deviceID = UUID()
            try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try? Data(deviceID.uuidString.utf8).write(to: identity, options: .atomic)
        }
    }

    var available: Bool { connection != nil }
    var testOnly: Bool { connection?.testOnly == true }
    var items: [CloudItem] { cache.items }
    var continuing: [CloudItem] {
        cache.items.filter { item in item.state == .active && !cache.deletions.contains(where: { $0.id == item.id }) }
            .sorted { lastRead($0) > lastRead($1) }
    }
    var copies: [CloudItem] { cache.items.filter { $0.storage == .copy && $0.state != .deleted } }
    var retired: Set<UUID> { Set(cache.items.filter { $0.state != .active }.map(\.id)) }
    var pendingCount: Int { cache.deletions.count }
    var hasPendingWork: Bool { !cache.deletions.isEmpty || !cache.positions.isEmpty || !cache.uploads.isEmpty }

    func item(_ id: UUID) -> CloudItem? { cache.items.first { $0.id == id } }
    func lastRead(_ item: CloudItem) -> Date { latestReading(item)?.modified ?? item.created }
    func latestReading(_ item: CloudItem) -> CloudReading? {
        cache.readings.filter { $0.item == item.identity }.max { $0.modified < $1.modified }
    }
    func pending(_ item: CloudItem) -> CloudDeletion? { cache.deletions.first { $0.id == item.id } }
    func uploading(_ item: CloudItem) -> Bool { cache.uploads.contains { $0.id == item.id } }
    func busy(_ item: CloudItem) -> Bool { busyItems.contains(item.id) }
    func protected(_ item: CloudItem) -> Bool { cache.protected.contains(item.id) }
    func canDelete(_ item: CloudItem) -> Bool {
        available && item.storage == .copy && item.state == .active &&
            !busy(item) && !protected(item) && pending(item) == nil
    }

    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let id = UUID()
        let task = Task { await self.performRefresh() }
        refreshID = id
        refreshTask = task
        await task.value
        if refreshID == id { refreshTask = nil; refreshID = nil }
    }

    func accountChanged() {
        sessionVersion = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        readingTasks.values.forEach { $0.cancel() }
        readingTasks = [:]
        connection = nil
        documents?.stop()
        documents = nil
        files = nil
        account = nil
        cache = Cache()
        itemErrors = [:]
        error = nil
        notice = nil
        refreshing = false
    }

    private func performRefresh() async {
        let version = sessionVersion
        refreshing = true
        defer { if version == sessionVersion { refreshing = false } }
        do {
            let resolved = try await resolve()
            guard version == sessionVersion else { return }
            let next: CloudConnection
            if let current = connection, current.account == resolved.account,
               current.root == resolved.root, current.environment == resolved.environment,
               current.testOnly == resolved.testOnly, current.isCurrent() {
                next = current
            } else { next = resolved }
            try next.validate()
            if account != next.account {
                documents?.stop()
                documents = nil
                readingTasks.values.forEach { $0.cancel() }
                readingTasks = [:]
                cache = (try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL(next.account)))) ?? Cache()
                account = next.account
                itemErrors = [:]
            }
            connection = next
            files = CloudFiles(connection: next, local: localDirectory(next.account))
            if !next.testOnly, documents == nil {
                documents = CloudDocumentsObserver(root: next.root) { [weak self] in
                    Task { await self?.refresh() }
                }
            }
            let snapshot = try await next.metadata.snapshot()
            try validate(next)
            cache.items = snapshot.items
            for upload in cache.uploads where !cache.items.contains(where: { $0.id == upload.id }) { cache.items.append(upload) }
            cache.readings = snapshot.readings
            for position in cache.positions { merge(position) }
            error = nil
            try persist()
            await processUploads(next)
            await processPositions(next)
            await scheduleRetiredCopies(next)
            await processDeletions(next)
        } catch {
            guard version == sessionVersion else { return }
            self.error = error.localizedDescription
            if (error as? CloudFailure) == .unavailable || (error as? CloudFailure) == .notEnabled || (error as? CloudFailure) == .accountChanged {
                account = nil
                cache = Cache()
                connection = nil
                documents?.stop()
                documents = nil
                files = nil
                readingTasks.values.forEach { $0.cancel() }
                readingTasks = [:]
                itemErrors = [:]
            }
        }
    }

    @discardableResult
    func send(root: URL, path: String, folder: Bool, position: CloudPosition = CloudPosition()) async throws -> CloudItem {
        guard !sharing else { throw CloudFailure.message("Another document is being sent. Please wait.") }
        guard let connection, let files else { throw CloudFailure.unavailable }
        try validate(connection)
        sharing = true
        defer { sharing = false }
        let access = CloudAccess(root)
        defer { withExtendedLifetime(access) {} }
        let path = try CloudPaths.relative(path)
        let item: CloudItem
        if !connection.testOnly, FileManager.default.isUbiquitousItem(at: root.appendingPathComponent(path)),
           !root.pathComponents.starts(with: connection.root.appendingPathComponent("Documents/Reading Copies").pathComponents) {
            item = try await files.link(root: root, path: path, device: deviceName)
            try bind(item, to: root, connection: connection)
        } else { item = try await files.create(root: root, path: path, folder: folder, device: deviceName) }
        try validate(connection)
        cache.uploads.append(item)
        cache.items.append(item)
        try persist()
        await processUploads(connection)
        recordPosition(item.identity, position: position)
        notice = uploading(item) ? "Waiting to publish the reading copy to iCloud." :
            "Available in Continue Reading on your other devices after iCloud finishes synchronizing."
        return item
    }

    func open(_ requested: CloudItem) async throws -> CloudOpened {
        guard let connection, let files else { throw CloudFailure.unavailable }
        try validate(connection)
        guard let item = item(requested.id), item.identity == requested.identity, item.state == .active,
              pending(item) == nil, !uploading(item) else { throw CloudFailure.stale }
        let access: CloudAccess
        if item.storage == .copy { access = try await files.open(item) }
        else {
            guard let data = cache.bindings[item.id] else { throw CloudFailure.message("Choose this document's iCloud folder on this device to continue.") }
            var stale = false
            let root = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw CloudFailure.message("Choose the iCloud folder again to renew access.") }
            access = CloudAccess(root)
            _ = try CloudPaths.contained(root.appendingPathComponent(item.path), in: root)
        }
        try validate(connection)
        return CloudOpened(item: item, access: access, position: latestReading(item)?.position)
    }

    func needsFolder(_ item: CloudItem) -> Bool {
        guard item.storage == .linked else { return false }
        guard let data = cache.bindings[item.id] else { return true }
        var stale = false
        guard (try? URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)) != nil else { return true }
        return stale
    }

    func bind(_ item: CloudItem, to root: URL) throws {
        guard let connection else { throw CloudFailure.unavailable }
        try bind(item, to: root, connection: connection)
        try persist()
    }

    private func bind(_ item: CloudItem, to root: URL, connection: CloudConnection) throws {
        try validate(connection)
        guard item.storage == .linked else { throw CloudFailure.unsafe }
        let access = CloudAccess(root)
        defer { withExtendedLifetime(access) {} }
        let file = try CloudPaths.contained(root.appendingPathComponent(try CloudPaths.relative(item.path)), in: root)
        guard FileManager.default.fileExists(atPath: file.path),
              connection.testOnly || FileManager.default.isUbiquitousItem(at: file) else {
            throw CloudFailure.message("Choose the iCloud folder containing this document.")
        }
        cache.bindings[item.id] = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func setProtected(_ item: CloudIdentity, _ value: Bool) {
        guard self.item(item.id)?.identity == item else { return }
        if value { cache.protected.insert(item.id) } else { cache.protected.remove(item.id) }
        do { try persist() } catch { self.error = error.localizedDescription }
    }

    func recordPosition(_ item: CloudIdentity, position: CloudPosition) {
        guard self.item(item.id)?.identity == item, self.item(item.id)?.state == .active,
              !cache.deletions.contains(where: { $0.id == item.id }) else { return }
        let reading = CloudReading(item: item, deviceID: deviceID, deviceName: deviceName,
                                   modified: Date(), position: position.sanitized)
        cache.positions.removeAll { $0.id == reading.id }
        cache.positions.append(reading)
        merge(reading)
        do { try persist() } catch { self.error = error.localizedDescription }
        readingTasks[item.id]?.cancel()
        readingTasks[item.id] = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let connection else { return }
            await processPositions(connection)
        }
    }

    func flushPositions() async {
        readingTasks.values.forEach { $0.cancel() }
        if let connection { await processPositions(connection) }
    }

    func delete(_ selected: [CloudItem]) async {
        guard let connection, let files else { error = CloudFailure.unavailable.localizedDescription; return }
        for requested in selected {
            guard let current = item(requested.id), current == requested, canDelete(current) else {
                itemErrors[requested.id] = protected(requested) ? CloudFailure.protectedDraft.localizedDescription : CloudFailure.stale.localizedDescription
                continue
            }
            busyItems.insert(current.id)
            do {
                try await files.verifyLocalCleanup(current)
                try validate(connection)
                guard item(current.id) == current, !protected(current), pending(current) == nil else { throw CloudFailure.stale }
                cache.deletions.append(CloudDeletion(item: current.identity, revision: current.revision, candidate: current))
            } catch { if account == connection.account { itemErrors[current.id] = error.localizedDescription } }
            busyItems.remove(current.id)
        }
        do { try persist() } catch { self.error = error.localizedDescription; return }
        await processDeletions(connection)
    }

    func cancelDeletion(_ item: CloudItem) async {
        guard let request = pending(item), !busy(item), let connection else { return }
        do {
            try validate(connection)
            if request.phase != .queued {
                let snapshot = try await connection.metadata.snapshot()
                try validate(connection)
                let active = snapshot.items.contains { $0.identity == request.item && $0.state == .active }
                let unpublished = uploading(item) && !snapshot.items.contains { $0.id == request.id }
                guard active || unpublished else { throw CloudFailure.stale }
            }
            cache.deletions.removeAll { $0.item == request.item }
            itemErrors[item.id] = nil
            try persist()
        } catch { itemErrors[item.id] = error.localizedDescription }
    }

    func removeDownload(_ item: CloudItem) async {
        guard let connection, let files else { return }
        guard !protected(item), !busy(item) else { itemErrors[item.id] = CloudFailure.protectedDraft.localizedDescription; return }
        busyItems.insert(item.id)
        defer { busyItems.remove(item.id) }
        do {
            try validate(connection)
            try await files.evict(item)
            try validate(connection)
            itemErrors[item.id] = nil
            notice = "Local download removed. The iCloud reading copy is kept."
            eviction = CloudEviction(item: item.id)
        } catch { itemErrors[item.id] = error.localizedDescription }
    }

    private func processUploads(_ connection: CloudConnection) async {
        for item in cache.uploads where !cache.deletions.contains(where: { $0.id == item.id }) && !busyItems.contains(item.id) {
            busyItems.insert(item.id)
            do {
                try validate(connection)
                try await connection.metadata.create(item)
                try validate(connection)
                cache.uploads.removeAll { $0.identity == item.identity }
                itemErrors[item.id] = nil
                try persist()
            } catch {
                if account == connection.account {
                    itemErrors[item.id] = error.localizedDescription
                    if (error as? CloudFailure) == .stale {
                        cache.uploads.removeAll { $0.identity == item.identity }
                        try? persist()
                    }
                }
            }
            busyItems.remove(item.id)
        }
    }

    func retryDeletion(_ item: CloudItem) async {
        guard let connection, item.storage == .copy, item.state != .active, !protected(item), !busy(item) else { return }
        if pending(item) == nil {
            cache.deletions.append(CloudDeletion(item: item.identity, revision: item.revision, phase: .started))
            do { try persist() } catch { self.error = error.localizedDescription; return }
        }
        await processDeletions(connection)
    }

    private func scheduleRetiredCopies(_ connection: CloudConnection) async {
        guard let files else { return }
        for item in cache.items where item.storage == .copy && item.state == .deleted && !cache.protected.contains(item.id) {
            do {
                try validate(connection)
                guard try await files.hasResidue(item) else { continue }
                try validate(connection)
                var pending = item
                pending.state = .deleting
                replace(pending)
                if !cache.deletions.contains(where: { $0.id == item.id }) {
                    cache.deletions.append(CloudDeletion(item: item.identity, revision: item.revision, phase: .started))
                }
                try persist()
            } catch { if account == connection.account { itemErrors[item.id] = error.localizedDescription } }
        }
    }

    private func processPositions(_ connection: CloudConnection) async {
        for reading in cache.positions {
            do {
                try validate(connection)
                try await connection.metadata.record(reading)
                try validate(connection)
                cache.positions.removeAll { $0 == reading }
                try persist()
            } catch {
                if (error as? CloudFailure) == .stale {
                    cache.positions.removeAll { $0 == reading }
                    try? persist()
                }
            }
        }
    }

    private func processDeletions(_ connection: CloudConnection) async {
        guard let files else { return }
        for request in cache.deletions where !busyItems.contains(request.id) {
            busyItems.insert(request.id)
            var committed = false
            do {
                try validate(connection)
                guard !cache.protected.contains(request.id) else { throw CloudFailure.protectedDraft }
                if let index = cache.deletions.firstIndex(where: { $0.item == request.item && $0.phase == .queued }) {
                    cache.deletions[index].phase = .requesting
                    try persist()
                }
                let current = try await connection.metadata.beginDeletion(request)
                committed = true
                try validate(connection)
                var visible = current
                visible.state = .deleting
                replace(visible)
                if let index = cache.deletions.firstIndex(where: { $0.item == request.item }) { cache.deletions[index].phase = .started }
                try persist()
                guard !cache.protected.contains(request.id) else { throw CloudFailure.protectedDraft }
                try await files.remove(current)
                try validate(connection)
                try await connection.metadata.finishDeletion(request)
                try validate(connection)
                var retired = current
                retired.state = .deleted
                replace(retired)
                cache.deletions.removeAll { $0.item == request.item }
                cache.positions.removeAll { $0.item == request.item }
                cache.uploads.removeAll { $0.identity == request.item }
                itemErrors[request.id] = nil
                try persist()
            } catch {
                if account == connection.account {
                    if !committed, (error as? CloudFailure) == .offline,
                       let index = cache.deletions.firstIndex(where: { $0.item == request.item }) {
                        cache.deletions[index].phase = .queued
                        try? persist()
                    }
                    itemErrors[request.id] = error.localizedDescription
                }
            }
            busyItems.remove(request.id)
        }
    }

    private func validate(_ connection: CloudConnection) throws {
        try connection.validate()
        guard account == connection.account else { throw CloudFailure.accountChanged }
    }

    private func replace(_ item: CloudItem) {
        cache.items.removeAll { $0.id == item.id }
        cache.items.append(item)
    }
    private func merge(_ reading: CloudReading) {
        if let previous = cache.readings.first(where: { $0.id == reading.id }), previous.modified > reading.modified { return }
        cache.readings.removeAll { $0.id == reading.id }
        cache.readings.append(reading)
    }
    private func localDirectory(_ account: String) -> URL {
        storage.appendingPathComponent(CloudPaths.digest(Data(account.utf8)))
    }
    private func cacheURL(_ account: String) -> URL { localDirectory(account).appendingPathComponent("library.json") }
    private func persist() throws {
        guard let account else { return }
        let url = cacheURL(account)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
