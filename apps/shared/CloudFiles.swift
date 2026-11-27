import Foundation

actor CloudFiles {
    private let connection: CloudConnection
    private let local: URL
    static let maximumFileBytes = 128 * 1_024 * 1_024
    static let maximumFolderBytes = 512 * 1_024 * 1_024
    static let maximumManifestBytes = 2 * 1_024 * 1_024

    init(connection: CloudConnection, local: URL) {
        self.connection = connection
        self.local = local
    }

    private var copies: URL { connection.copies }

    private func directory(_ item: CloudItem) throws -> URL {
        guard item.storage == .copy else { throw CloudFailure.unsafe }
        try CloudPaths.rejectLinks(copies, under: connection.root)
        _ = try CloudPaths.contained(copies, in: connection.root)
        let url = copies.appendingPathComponent(item.directoryName)
        try CloudPaths.rejectLinks(url, under: copies)
        let resolved = try CloudPaths.contained(url, in: copies)
        guard resolved.path == url.standardizedFileURL.path,
              !isLink(copies), !isLink(url.deletingLastPathComponent()), !isLink(url) else { throw CloudFailure.unsafe }
        return resolved
    }

    func create(root: URL, path: String, folder: Bool, device: String) throws -> CloudItem {
        try connection.validate()
        let path = try CloudPaths.relative(path)
        let source = try CloudPaths.contained(root.appendingPathComponent(path), in: root)
        guard !isLink(root), !isLink(source) else { throw CloudFailure.unsafe }
        let stage = local.appendingPathComponent("Staging/\(UUID().uuidString)")
        let payload = stage.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        var paths = [path]
        if folder {
            paths = []
            var enumerationError: (any Error)?
            guard let entries = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else {
                throw CloudFailure.message("This folder could not be listed.")
            }
            for case let file as URL in entries {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CloudFailure.message("Folders with symbolic links cannot be sent.") }
                if values.isRegularFile == true {
                    paths.append(try CloudPaths.relative(file, in: root))
                    guard paths.count <= 5_000 else { throw CloudFailure.message("Send a folder with no more than 5,000 files.") }
                }
            }
            if let enumerationError { throw enumerationError }
            guard paths.contains(path) else { throw CloudFailure.unsafe }
        }
        var total: Int64 = 0
        var hashes: [String: String] = [:]
        for relative in paths.sorted() {
            try Task.checkCancellation()
            try connection.validate()
            let file = root.appendingPathComponent(relative)
            let data = try coordinate(file, writing: false) { coordinated in
                let file = try CloudPaths.contained(coordinated, in: root)
                guard !isLink(file) else { throw CloudFailure.unsafe }
                return try Self.read(file, limit: Self.maximumFileBytes)
            }
            total += Int64(data.count)
            guard total <= Self.maximumFolderBytes else { throw CloudFailure.message("Send a folder smaller than 512 MiB.") }
            hashes[relative] = CloudPaths.digest(data)
            let target = payload.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        let revision = CloudManifest.snapshotRevision(hashes)
        let item = CloudItem(id: UUID(), generation: UUID(), name: source.lastPathComponent,
                             sourceDevice: device, created: Date(), storage: .copy, path: path,
                             folderName: root.lastPathComponent, folderCopy: folder,
                             byteCount: total, fileCount: paths.count, revision: revision)
        let manifest = CloudManifest(owner: CloudManifest.ownerID, identity: item.identity, path: path, revision: revision, files: hashes)
        let manifestData = try JSONEncoder().encode(manifest)
        guard manifestData.count <= Self.maximumManifestBytes else { throw CloudFailure.message("This folder's file list is too large to send.") }
        try manifestData.write(to: stage.appendingPathComponent(".folio-copy.json"), options: .atomic)
        let destination = try directory(item)
        try connection.validate()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let incoming = destination.deletingLastPathComponent().appendingPathComponent("incoming-\(UUID().uuidString)")
        defer {
            if connection.isCurrent() { try? FileManager.default.removeItem(at: incoming) }
        }
        try FileManager.default.copyItem(at: stage, to: incoming)
        try coordinate(destination, writing: true) { url in
            try connection.validate()
            guard url.standardizedFileURL == destination.standardizedFileURL else { throw CloudFailure.unsafe }
            _ = try directory(item)
            try FileManager.default.moveItem(at: incoming, to: url)
        }
        return item
    }

    func link(root: URL, path: String, device: String) throws -> CloudItem {
        try connection.validate()
        let access = CloudAccess(root)
        defer { withExtendedLifetime(access) {} }
        let file = root.appendingPathComponent(try CloudPaths.relative(path))
        return try coordinate(file, writing: false) { actual in
            try connection.validate()
            let actual = try CloudPaths.contained(actual, in: root)
            guard !isLink(actual) else { throw CloudFailure.unsafe }
            let path = actual.pathComponents.dropFirst(root.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
            let data = try Self.read(actual, limit: Self.maximumFileBytes)
            return CloudItem(id: UUID(), generation: UUID(), name: actual.lastPathComponent,
                sourceDevice: device, created: Date(), storage: .linked, path: try CloudPaths.relative(path),
                folderName: root.lastPathComponent, folderCopy: false, byteCount: Int64(data.count),
                fileCount: 1, revision: CloudPaths.digest(data))
        }
    }

    func open(_ item: CloudItem) async throws -> CloudAccess {
        try connection.validate()
        guard item.state == .active else { throw CloudFailure.stale }
        _ = try CloudPaths.relative(item.path)
        let directory = try directory(item)
        let cache = local.appendingPathComponent("Downloads/\(item.directoryName)")
        try CloudPaths.rejectLinks(cache, under: local)
        _ = try CloudPaths.contained(cache, in: local)
        if completeDownload(item, at: cache) {
            let payload = try CloudPaths.contained(cache.appendingPathComponent("payload"), in: cache)
            guard !isLink(cache), !isLink(payload), !isLink(cache.deletingLastPathComponent()) else { throw CloudFailure.unsafe }
            return CloudAccess(payload)
        }
        let sourceManifest = directory.appendingPathComponent(".folio-copy.json")
        try await download(sourceManifest)
        let manifest = try validateManifest(item, at: directory)
        if !completeDownload(item, at: cache) {
            try verifyLocalCleanup(item, allowingMissing: true)
            let stage = local.appendingPathComponent("Downloads/incoming-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: stage) }
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            var total = 0
            for (path, hash) in manifest.files ?? [:] {
                let source = directory.appendingPathComponent("payload/\(path)")
                try await download(source)
                let data = try coordinate(source, writing: false) { actual in
                    try connection.validate()
                    try CloudPaths.rejectLinks(actual, under: directory)
                    return try Self.read(CloudPaths.contained(actual, in: directory), limit: Self.maximumFileBytes)
                }
                total += data.count
                guard total <= Self.maximumFolderBytes, CloudPaths.digest(data) == hash else { throw CloudFailure.stale }
                let destination = stage.appendingPathComponent("payload/\(path)")
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination)
            }
            try JSONEncoder().encode(manifest).write(to: stage.appendingPathComponent(".folio-copy.json"))
            try connection.validate()
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinate(cache, writing: true) { actual in
                let target = try CloudPaths.contained(actual, in: local)
                guard target.path == cache.resolvingSymlinksInPath().standardizedFileURL.path else { throw CloudFailure.unsafe }
                try CloudPaths.rejectLinks(cache, under: local)
                try verifyLocalCleanup(item, allowingMissing: true)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: stage, to: target)
            }
        }
        return CloudAccess(cache.appendingPathComponent("payload"))
    }

    func cachedDownload(_ item: CloudItem) throws -> CloudAccess {
        try connection.validate()
        guard item.storage == .copy else { throw CloudFailure.unsafe }
        let cache = local.appendingPathComponent("Downloads/\(item.directoryName)")
        try CloudPaths.rejectLinks(cache, under: local)
        _ = try CloudPaths.contained(cache, in: local)
        _ = try validateManifest(item, at: cache)
        let payload = cache.appendingPathComponent("payload")
        try CloudPaths.rejectLinks(payload, under: cache)
        guard try payload.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CloudFailure.unsafe }
        return CloudAccess(payload)
    }

    func remove(_ item: CloudItem) async throws {
        try connection.validate()
        guard item.state != .active else { throw CloudFailure.unsafe }
        try verifyLocalCleanup(item)
        let directory = try directory(item)
        if FileManager.default.fileExists(atPath: directory.path) {
            try await download(directory.appendingPathComponent(".folio-copy.json"), requireCurrent: true)
            let manifest = try validateManifest(item, at: directory)
            for path in manifest.files?.keys ?? Dictionary<String, String>().keys {
                try await download(directory.appendingPathComponent("payload/\(path)"), requireCurrent: true)
            }
            try coordinate(directory, writing: true) { url in
                try connection.validate()
                guard url.standardizedFileURL == directory.standardizedFileURL else { throw CloudFailure.unsafe }
                let current = try validateManifest(item, at: url)
                guard current == manifest else { throw CloudFailure.stale }
                let top = Set(try FileManager.default.contentsOfDirectory(atPath: url.path)).subtracting([".DS_Store"])
                guard top == ["payload", ".folio-copy.json"] else {
                    throw CloudFailure.message("Files were added to this copy outside Folio. Review them in Files or Finder before deleting it.")
                }
                let payload = url.appendingPathComponent("payload")
                try CloudPaths.rejectLinks(payload, under: url)
                guard let entries = FileManager.default.enumerator(at: payload,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw CloudFailure.unsafe }
                var found: Set<String> = []
                for case let file as URL in entries {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw CloudFailure.unsafe }
                    if values.isRegularFile == true, file.lastPathComponent != ".DS_Store" {
                        found.insert(try CloudPaths.relative(file, in: payload))
                    }
                }
                guard found == Set(current.files?.keys ?? Dictionary<String, String>().keys) else {
                    throw CloudFailure.message("Files were added to this copy outside Folio. Review them in Files or Finder before deleting it.")
                }
                for (path, hash) in current.files ?? [:] {
                    let file = url.appendingPathComponent("payload/\(path)")
                    try CloudPaths.rejectLinks(file, under: url)
                    guard CloudPaths.digest(try Self.read(file, limit: Self.maximumFileBytes)) == hash else {
                        throw CloudFailure.message("This copy was edited outside Folio. Review it in Files or Finder before deleting it.")
                    }
                }
                try FileManager.default.removeItem(at: url)
            }
        }
        try removePrivateDownload(item)
    }

    func hasResidue(_ item: CloudItem) throws -> Bool {
        try connection.validate()
        let cache = local.appendingPathComponent("Downloads/\(item.directoryName)")
        try CloudPaths.rejectLinks(cache, under: local)
        _ = try CloudPaths.contained(cache, in: local)
        return FileManager.default.fileExists(atPath: try directory(item).path) || FileManager.default.fileExists(atPath: cache.path)
    }

    func evict(_ item: CloudItem) throws {
        try connection.validate()
        guard item.storage == .copy, item.state == .active else { throw CloudFailure.unsafe }
        try removePrivateDownload(item)
        let directory = try directory(item)
        if !connection.testOnly, FileManager.default.isUbiquitousItem(at: directory) {
            try connection.validate()
            try FileManager.default.evictUbiquitousItem(at: directory)
        }
    }

    private func removePrivateDownload(_ item: CloudItem) throws {
        let downloads = local.appendingPathComponent("Downloads")
        let cache = downloads.appendingPathComponent(item.directoryName)
        try CloudPaths.rejectLinks(cache, under: local)
        _ = try CloudPaths.contained(cache, in: local)
        _ = try CloudPaths.contained(cache, in: downloads)
        guard !isLink(cache), !isLink(cache.deletingLastPathComponent()) else { throw CloudFailure.unsafe }
        if FileManager.default.fileExists(atPath: cache.path) {
            try verifyLocalCleanup(item)
            try FileManager.default.removeItem(at: cache)
        }
    }

    func verifyLocalCleanup(_ item: CloudItem, allowingMissing: Bool = false) throws {
        try connection.validate()
        let cache = local.appendingPathComponent("Downloads/\(item.directoryName)")
        try CloudPaths.rejectLinks(cache, under: local)
        guard FileManager.default.fileExists(atPath: cache.path) else { return }
        let manifest = try validateManifest(item, at: cache)
        let top = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)).subtracting([".DS_Store"])
        guard top == ["payload", ".folio-copy.json"] else { throw CloudFailure.protectedDraft }
        let payload = cache.appendingPathComponent("payload")
        try CloudPaths.rejectLinks(payload, under: cache)
        guard let entries = FileManager.default.enumerator(at: payload,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw CloudFailure.unsafe }
        var found: Set<String> = []
        for case let file as URL in entries {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CloudFailure.unsafe }
            if values.isRegularFile == true, file.lastPathComponent != ".DS_Store" {
                found.insert(try CloudPaths.relative(file, in: payload))
            }
        }
        let expected = Set(manifest.files?.keys ?? Dictionary<String, String>().keys)
        guard allowingMissing ? found.isSubset(of: expected) : found == expected else { throw CloudFailure.protectedDraft }
        for (path, hash) in manifest.files ?? [:] {
            if allowingMissing, !found.contains(path) { continue }
            let file = payload.appendingPathComponent(path)
            try CloudPaths.rejectLinks(file, under: cache)
            guard CloudPaths.digest(try Self.read(file, limit: Self.maximumFileBytes)) == hash else {
                throw CloudFailure.message("This local download has changes from another app. Keep or export those changes before removing it.")
            }
        }
    }

    private func completeDownload(_ item: CloudItem, at cache: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: cache.path) else { return false }
        do { try verifyLocalCleanup(item); return true }
        catch { return false }
    }

    @discardableResult
    private func validateManifest(_ item: CloudItem, at directory: URL) throws -> CloudManifest {
        guard !isLink(directory), !isLink(directory.appendingPathComponent(".folio-copy.json")) else { throw CloudFailure.unsafe }
        let manifest = try JSONDecoder().decode(CloudManifest.self,
            from: Self.read(directory.appendingPathComponent(".folio-copy.json"), limit: Self.maximumManifestBytes))
        guard manifest.owner == CloudManifest.ownerID, manifest.identity == item.identity,
              manifest.path == item.path, manifest.revision == item.revision else { throw CloudFailure.unsafe }
        guard let files = manifest.files, files.count == item.fileCount, files.count <= 5_000,
              files[item.path] != nil, CloudManifest.snapshotRevision(files) == item.revision else { throw CloudFailure.unsafe }
        for path in files.keys { _ = try CloudPaths.relative(path) }
        return manifest
    }

    private func download(_ url: URL, requireCurrent: Bool = false) async throws {
        try connection.validate()
        if connection.testOnly { return }
        for _ in 0..<120 {
            try Task.checkCancellation()
            try connection.validate()
            do { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { }
            let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .isRegularFileKey, .isDirectoryKey])
            if values?.ubiquitousItemDownloadingStatus == .current ||
                (!requireCurrent && values?.ubiquitousItemDownloadingStatus == .downloaded) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CloudFailure.waitingForFile
    }

    private static func read(_ file: URL, limit: Int) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw CloudFailure.unsafe }
        guard (values.fileSize ?? Int.max) <= limit else { throw CloudFailure.message("This file is too large to send.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            guard data.count + chunk.count <= limit else { throw CloudFailure.message("This file is too large to send.") }
            data.append(chunk)
        }
        return data
    }

    private func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func coordinate<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        let accessor: (URL) -> Void = { actual in result = Result { try body(actual) } }
        let coordinator = NSFileCoordinator()
        if writing { coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError, byAccessor: accessor) }
        else { coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError, byAccessor: accessor) }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CloudFailure.waitingForFile }
        return try result.get()
    }
}
