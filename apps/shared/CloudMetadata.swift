@preconcurrency import CloudKit
import Foundation

actor AppleCloudMetadata: CloudMetadata {
    private let database: CKDatabase
    private let container: CKContainer
    private let account: CKRecord.ID
    private let zone = CKRecordZone.ID(zoneName: "FolioReadingLibrary")
    private var initialized = false

    init(container: CKContainer, account: CKRecord.ID) {
        self.container = container
        self.database = container.privateCloudDatabase
        self.account = account
    }

    private func prepare() async throws {
        do {
            guard try await container.userRecordID() == account else { throw CloudFailure.accountChanged }
            if !initialized {
                _ = try await database.save(CKRecordZone(zoneID: zone))
                initialized = true
            }
        } catch let error as CKError where error.code == .networkUnavailable || error.code == .networkFailure {
            throw CloudFailure.offline
        }
    }

    func snapshot() async throws -> CloudSnapshot {
        try await prepare()
        let records: [CKRecord] = try await withCheckedThrowingContinuation { continuation in
            let state = CloudFetchState()
            let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone], configurationsByRecordZoneID: nil)
            operation.fetchAllChanges = true
            operation.recordWasChangedBlock = { _, result in state.append(result) }
            operation.recordWithIDWasDeletedBlock = { id, _ in state.remove(id) }
            operation.recordZoneFetchResultBlock = { _, result in
                if case .failure(let error) = result { state.fail(error) }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                do { try result.get(); continuation.resume(returning: try state.finish()) }
                catch { continuation.resume(throwing: error) }
            }
            database.add(operation)
        }
        guard try await container.userRecordID() == account else { throw CloudFailure.accountChanged }
        var result = CloudSnapshot()
        for record in records {
            guard let data = record["payload"] as? Data else { continue }
            if record.recordType == "FolioReadingCopy" {
                let item = try JSONDecoder().decode(CloudItem.self, from: data)
                guard record.recordID.recordName == item.id.uuidString else { throw CloudFailure.unsafe }
                _ = try CloudPaths.relative(item.path)
                result.items.append(item)
            } else if record.recordType == "FolioReadingPosition" {
                let reading = try JSONDecoder().decode(CloudReading.self, from: data)
                guard record.recordID.recordName == reading.id else { throw CloudFailure.unsafe }
                result.readings.append(reading)
            }
        }
        return result
    }

    func create(_ item: CloudItem) async throws {
        guard item.state == .active else { throw CloudFailure.stale }
        try await prepare()
        let id = CKRecord.ID(recordName: item.id.uuidString, zoneID: zone)
        do {
            let old = try await database.record(for: id)
            let existing: CloudItem = try decode(old)
            guard existing == item, existing.state == .active else { throw CloudFailure.stale }
            return
        } catch let error as CKError where error.code == .unknownItem { }
        let record = CKRecord(recordType: "FolioReadingCopy", recordID: id)
        try await save(item, in: record)
    }

    func record(_ reading: CloudReading) async throws {
        try await prepare()
        let item: CloudItem = try decode(await database.record(for: CKRecord.ID(recordName: reading.item.id.uuidString, zoneID: zone)))
        guard item.identity == reading.item, item.state == .active else { throw CloudFailure.stale }
        let id = CKRecord.ID(recordName: reading.id, zoneID: zone)
        var record: CKRecord
        do {
            record = try await database.record(for: id)
            let previous: CloudReading = try decode(record)
            guard previous.modified <= reading.modified else { return }
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: "FolioReadingPosition", recordID: id)
        }
        try await save(reading, in: record)
    }

    func beginDeletion(_ request: CloudDeletion) async throws -> CloudItem {
        try await prepare()
        var record: CKRecord
        var item: CloudItem
        let id = CKRecord.ID(recordName: request.item.id.uuidString, zoneID: zone)
        do {
            record = try await database.record(for: id)
            item = try decode(record)
        } catch let error as CKError where error.code == .unknownItem {
            guard let candidate = request.unpublishedCopy else { throw CloudFailure.stale }
            record = CKRecord(recordType: "FolioReadingCopy", recordID: id)
            item = candidate
        }
        guard item.storage == .copy, item.identity == request.item, item.revision == request.revision else { throw CloudFailure.stale }
        if item.state == .active {
            item.state = .deleting
            try await save(item, in: record)
        }
        return item
    }

    func finishDeletion(_ request: CloudDeletion) async throws {
        try await prepare()
        let record = try await database.record(for: CKRecord.ID(recordName: request.item.id.uuidString, zoneID: zone))
        var item: CloudItem = try decode(record)
        guard item.identity == request.item, item.revision == request.revision, item.state != .active else { throw CloudFailure.stale }
        item.state = .deleted
        try await save(item, in: record)
    }

    private func decode<T: Decodable>(_ record: CKRecord) throws -> T {
        guard let data = record["payload"] as? Data else { throw CloudFailure.unsafe }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, in record: CKRecord) async throws {
        guard try await container.userRecordID() == account else { throw CloudFailure.accountChanged }
        record["payload"] = try JSONEncoder().encode(value) as NSData
        let results = try await database.modifyRecords(saving: [record], deleting: [],
            savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = results.saveResults[record.recordID] else { throw CloudFailure.stale }
        _ = try saved.get()
        guard try await container.userRecordID() == account else { throw CloudFailure.accountChanged }
    }
}

private final class CloudFetchState: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CKRecord.ID: CKRecord] = [:]
    private var error: (any Error)?
    func append(_ result: Result<CKRecord, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success(let record): records[record.recordID] = record
        case .failure(let error): self.error = error
        }
    }
    func fail(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        self.error = error
    }
    func remove(_ id: CKRecord.ID) {
        lock.lock()
        defer { lock.unlock() }
        records[id] = nil
    }
    func finish() throws -> [CKRecord] {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        return Array(records.values)
    }
}

actor LocalCloudMetadata: CloudMetadata {
    private struct State: Codable {
        var items: [CloudItem] = []
        var readings: [CloudReading] = []
    }
    private var state: State
    private let file: URL
    var offline = false
    var failedDeletions: Set<UUID> = []

    init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        } else { state = State() }
    }

    func setOffline(_ value: Bool) { offline = value }
    func failDeletion(_ id: UUID) { failedDeletions.insert(id) }
    func clearFailures() { failedDeletions = [] }

    func snapshot() throws -> CloudSnapshot {
        guard !offline else { throw CloudFailure.offline }
        return CloudSnapshot(items: state.items, readings: state.readings)
    }

    func create(_ item: CloudItem) throws {
        guard item.state == .active else { throw CloudFailure.stale }
        guard !offline else { throw CloudFailure.offline }
        if let previous = state.items.first(where: { $0.id == item.id }) {
            guard previous == item, previous.state == .active else { throw CloudFailure.stale }
            return
        }
        state.items.append(item)
        try persist()
    }

    func record(_ reading: CloudReading) throws {
        guard !offline else { throw CloudFailure.offline }
        guard state.items.contains(where: { $0.identity == reading.item && $0.state == .active }) else { throw CloudFailure.stale }
        if let previous = state.readings.first(where: { $0.id == reading.id }), previous.modified > reading.modified { return }
        state.readings.removeAll { $0.id == reading.id }
        state.readings.append(reading)
        try persist()
    }

    func beginDeletion(_ request: CloudDeletion) throws -> CloudItem {
        guard !offline else { throw CloudFailure.offline }
        guard !failedDeletions.contains(request.id) else { throw CloudFailure.message("This copy could not be deleted. Try again.") }
        if !state.items.contains(where: { $0.id == request.id }) {
            guard let candidate = request.unpublishedCopy else { throw CloudFailure.stale }
            state.items.append(candidate)
        }
        guard let index = state.items.firstIndex(where: { $0.id == request.id }),
              state.items[index].identity == request.item, state.items[index].storage == .copy,
              state.items[index].revision == request.revision else { throw CloudFailure.stale }
        if state.items[index].state == .active { state.items[index].state = .deleting }
        try persist()
        return state.items[index]
    }

    func finishDeletion(_ request: CloudDeletion) throws {
        guard !offline else { throw CloudFailure.offline }
        guard let index = state.items.firstIndex(where: { $0.identity == request.item }),
              state.items[index].state != .active, state.items[index].storage == .copy,
              state.items[index].revision == request.revision else { throw CloudFailure.stale }
        state.items[index].state = .deleted
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
    }
}
