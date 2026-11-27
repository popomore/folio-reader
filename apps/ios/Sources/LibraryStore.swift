import CryptoKit
import Foundation
import Observation

struct RecentFile: Codable, Hashable, Identifiable {
    let folderID: UUID
    let path: String
    let opened: Date
    var id: String { "\(folderID)/\(path)" }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

@MainActor @Observable
final class LibraryStore {
    private struct State: Codable {
        var folders: [SavedFolder] = []
        var recent: [RecentFile] = []
    }

    private var state = State()
    let documents: URL
    let storage: URL
    var error: String?
    var busy = false
    var folders: [SavedFolder] { state.folders }
    var recent: [RecentFile] { state.recent }

    init(base: URL? = nil) {
        let manager = FileManager.default
        documents = base?.appendingPathComponent("Documents") ?? manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storage = base?.appendingPathComponent("Library") ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            try manager.createDirectory(at: storage, withIntermediateDirectories: true)
            try manager.createDirectory(at: documents, withIntermediateDirectories: true)
            let url = storage.appendingPathComponent("library.json")
            if manager.fileExists(atPath: url.path) {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            }
        } catch { self.error = "The library could not be loaded: \(error.localizedDescription)" }
    }

    @discardableResult
    func add(_ url: URL) async throws -> SavedFolder {
        let folder = try await WorkspaceIO.remember(url)
        let access = try FolderAccess(folder: folder)
        defer { withExtendedLifetime(access) {} }
        if let index = folders.firstIndex(where: { (try? FolderAccess.bookmarkLocation($0)) == access.root }) {
            let refreshed = SavedFolder(id: folders[index].id, name: folder.name, bookmark: folder.bookmark)
            state.folders[index] = refreshed
            persist()
            return refreshed
        }
        state.folders.append(folder)
        persist()
        return folder
    }

    func remove(_ folder: SavedFolder) {
        state.folders.removeAll { $0.id == folder.id }
        state.recent.removeAll { $0.folderID == folder.id }
        persist()
    }

    func record(_ folder: SavedFolder, path: String) {
        state.recent.removeAll { $0.folderID == folder.id && $0.path == path }
        state.recent.insert(RecentFile(folderID: folder.id, path: path, opened: Date()), at: 0)
        state.recent = Array(state.recent.prefix(20))
        persist()
    }

    func importFiles(_ urls: [URL]) async throws -> SavedFolder {
        let imports = documents.appendingPathComponent("Imported Files")
        _ = try await WorkspaceIO.importFiles(urls, into: imports)
        return try await add(imports)
    }

    func sample() async throws -> SavedFolder {
        let destination = documents.appendingPathComponent("Sample Project")
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard let source = Bundle.main.url(forResource: "Sample Project", withExtension: nil) else {
                throw CoreError(message: "The sample project is missing from this build.")
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return try await add(destination)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: storage.appendingPathComponent("library.json"), options: .atomic)
        } catch { self.error = "The library could not be saved: \(error.localizedDescription)" }
    }
}

struct DraftRecord: Codable, Sendable {
    let source: String
    let revision: String
    let owner: UUID?

    init(source: String, revision: String, owner: UUID? = nil) {
        self.source = source
        self.revision = revision
        self.owner = owner
    }
}

actor DraftStore {
    @MainActor private static var stores: [[String]: DraftStore] = [:]
    let directory: URL

    private init(directory: URL) { self.directory = directory }

    @MainActor
    static func shared(directory: URL) -> DraftStore {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        let key = directory.pathComponents.filter { $0 != "/" }
        if let store = stores[key] { return store }
        let store = DraftStore(directory: directory)
        stores[key] = store
        return store
    }

    func read(_ key: String) throws -> DraftRecord? {
        let url = location(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(DraftRecord.self, from: Data(contentsOf: url))
    }

    func write(_ record: DraftRecord, key: String, onlyIfOwnedBy owner: UUID? = nil) throws {
        if let owner {
            guard let current = try read(key), current.owner == owner else { return }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: location(key), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func recover(_ key: String, owner: UUID) throws -> DraftRecord? {
        guard let record = try read(key) else { return nil }
        let recovered = DraftRecord(source: record.source, revision: record.revision, owner: owner)
        try write(recovered, key: key)
        return recovered
    }

    func remove(_ key: String, owner: UUID) throws {
        guard let record = try read(key), record.owner == owner else { return }
        let url = location(key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func location(_ key: String) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }
}
