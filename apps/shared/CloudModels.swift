import CryptoKit
import Foundation

enum CloudFailure: LocalizedError, Equatable, Sendable {
    case unavailable, notEnabled, accountChanged, offline, stale, unsafe, protectedDraft, waitingForFile, bindingChanged
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "iCloud is unavailable. Check iCloud Drive and your Apple account in Settings."
        case .notEnabled: "iCloud is not enabled for this build. Use an iCloud-enabled build to connect."
        case .accountChanged: "Your iCloud account changed. Refresh the library before continuing."
        case .offline: "Waiting for an iCloud connection."
        case .stale: "This reading copy changed. Refresh and review it before trying again."
        case .unsafe: "This item is outside Folio's managed reading copies."
        case .protectedDraft: "Save or explicitly discard this document's unsaved draft before removing it."
        case .waitingForFile: "Waiting for the file to arrive from iCloud. Try again after synchronization finishes."
        case .bindingChanged: "This file differs from the shared document. Confirm that this is the document you want to use."
        case .message(let message): message
        }
    }
}

struct CloudPosition: Codable, Hashable, Sendable {
    var path: String?
    var heading: String?
    var block: Int?
    var blockOffset: Double = 0
    var progress: Double = 0
    var page: Int?
    var revision: String?

    var sanitized: Self {
        var value = self
        value.progress = progress.isFinite ? min(1, max(0, progress)) : 0
        value.blockOffset = blockOffset.isFinite ? min(1, max(0, blockOffset)) : 0
        if let block, block < 0 || block > 100_000 { value.block = nil }
        if let page, page < 0 || page > 100_000 { value.page = nil }
        value.heading = heading.map { String($0.prefix(1_024)) }
        value.path = path.flatMap { $0.utf8.count <= 4_096 ? try? CloudPaths.relative($0) : nil }
        return value
    }
}

struct CloudItem: Codable, Hashable, Sendable, Identifiable {
    enum Storage: String, Codable, Sendable { case copy, linked }
    enum State: String, Codable, Sendable { case active, deleting, deleted }
    let id: UUID
    let generation: UUID
    let name: String
    let sourceDevice: String
    let created: Date
    let storage: Storage
    let path: String
    let folderName: String
    let folderCopy: Bool
    let byteCount: Int64?
    let fileCount: Int
    let revision: String
    var state: State = .active

    var identity: CloudIdentity { CloudIdentity(id: id, generation: generation) }
    var directoryName: String { "\(id.uuidString)/\(generation.uuidString)" }
}

struct CloudIdentity: Codable, Hashable, Sendable {
    let id: UUID
    let generation: UUID
}

struct CloudReading: Codable, Hashable, Sendable, Identifiable {
    let item: CloudIdentity
    let deviceID: UUID
    let deviceName: String
    var modified: Date
    var position: CloudPosition
    var id: String { "\(item.id.uuidString)-\(deviceID.uuidString)" }
}

struct CloudSnapshot: Sendable {
    var items: [CloudItem] = []
    var readings: [CloudReading] = []
}

struct CloudDeletion: Codable, Hashable, Sendable, Identifiable {
    enum Phase: String, Codable, Sendable { case queued, requesting, started }
    let item: CloudIdentity
    let revision: String
    var phase: Phase = .queued
    var candidate: CloudItem? = nil
    var id: UUID { item.id }
    var unpublishedCopy: CloudItem? {
        guard let candidate, candidate.identity == item, candidate.revision == revision,
              candidate.storage == .copy, candidate.state == .active else { return nil }
        return candidate
    }
}

struct CloudManifest: Codable, Equatable, Sendable {
    let owner: String
    let identity: CloudIdentity
    let path: String
    let revision: String
    var files: [String: String]? = nil
    static let ownerID = "org.popomore.folio.reading-copy.v1"

    static func snapshotRevision(_ files: [String: String]) -> String {
        CloudPaths.digest(Data(files.keys.sorted().map { "\($0)\0\(files[$0]!)\0" }.joined().utf8))
    }
}

struct CloudEviction: Equatable, Sendable {
    let event = UUID()
    let item: UUID
}

struct CloudReview: Equatable, Sendable {
    let id = UUID()
    let item: UUID
}

protocol CloudMetadata: Sendable {
    func snapshot() async throws -> CloudSnapshot
    func create(_ item: CloudItem) async throws
    func record(_ reading: CloudReading) async throws
    func beginDeletion(_ request: CloudDeletion) async throws -> CloudItem
    func finishDeletion(_ request: CloudDeletion) async throws
}

enum CloudMode: String, Sendable {
    case development = "Development", production = "Production"
}

struct CloudConnection: Sendable {
    let account: String
    let root: URL
    let metadata: any CloudMetadata
    let isCurrent: @Sendable () -> Bool
    var environment: CloudMode = .development
    var testOnly = false
    var copies: URL { root.appendingPathComponent("Documents/Reading Copies/\(environment.rawValue)") }

    func validate() throws {
        guard isCurrent() else { throw CloudFailure.accountChanged }
    }
}

final class CloudAccess: @unchecked Sendable {
    let root: URL
    let scoped: Bool
    init(_ root: URL) {
        self.root = root
        scoped = root.startAccessingSecurityScopedResource()
    }
    deinit { if scoped { root.stopAccessingSecurityScopedResource() } }
}

struct CloudOpened: Sendable {
    let item: CloudItem
    let access: CloudAccess
    let position: CloudPosition?
    var path: String { position?.sanitized.path ?? item.path }
}

enum CloudPaths {
    static func relative(_ value: String, allowEmpty: Bool = false) throws -> String {
        guard !value.hasPrefix("/"), !value.contains("\0"), !value.contains("\\") else { throw CloudFailure.unsafe }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (allowEmpty && value.isEmpty) || (!value.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CloudFailure.unsafe
        }
        return value
    }

    static func contained(_ url: URL, in root: URL) throws -> URL {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.pathComponents.starts(with: base.pathComponents) else { throw CloudFailure.unsafe }
        return canonical
    }

    static func relative(_ url: URL, in root: URL) throws -> String {
        let canonical = try contained(url, in: root)
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        return try relative(canonical.pathComponents.dropFirst(base.pathComponents.count).joined(separator: "/"))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func rejectLinks(_ target: URL, under root: URL) throws {
        let base = root.standardizedFileURL
        let path = target.standardizedFileURL
        guard path.pathComponents.starts(with: base.pathComponents) else { throw CloudFailure.unsafe }
        var current = base
        guard (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CloudFailure.unsafe }
        for component in path.pathComponents.dropFirst(base.pathComponents.count) {
            current.appendPathComponent(component)
            guard (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CloudFailure.unsafe }
        }
    }
}
