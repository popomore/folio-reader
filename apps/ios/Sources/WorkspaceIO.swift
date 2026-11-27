import Foundation

struct SavedFolder: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let bookmark: Data
}

final class FolderAccess: @unchecked Sendable {
    let root: URL
    private let scoped: Bool
    private let scopeURL: URL

    init(url: URL) throws {
        scopeURL = url
        scoped = url.startAccessingSecurityScopedResource()
        root = url.resolvingSymlinksInPath().standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().pathComponents
        guard scoped || root.pathComponents.starts(with: home) else {
            throw CoreError(message: "Access to this folder has expired. Add it again from Files.")
        }
    }

    convenience init(folder: SavedFolder) throws {
        var stale = false
        let url = try URL(resolvingBookmarkData: folder.bookmark, options: .withoutUI,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else {
            throw CoreError(message: "This folder's location or permissions changed. Add it again from Files.")
        }
        try self.init(url: url)
    }

    static func bookmarkLocation(_ folder: SavedFolder) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: folder.bookmark, options: .withoutUI,
                       relativeTo: nil, bookmarkDataIsStale: &stale).resolvingSymlinksInPath().standardizedFileURL
    }

    deinit {
        if scoped { scopeURL.stopAccessingSecurityScopedResource() }
    }
}

final class PreviewFile: Sendable {
    let url: URL
    let directory: URL

    init(url: URL, directory: URL) {
        self.url = url
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

struct OpenedFile: Sendable {
    let access: FolderAccess
    let document: Document
    let preview: PreviewFile?
}

enum WorkspaceIO {
    static let maximumPreviewBytes = 128 * 1024 * 1024

    static func remember(_ url: URL) async throws -> SavedFolder {
        try await Task.detached(priority: .userInitiated) {
            let access = try FolderAccess(url: url)
            return try coordinated(at: access.root) { root in
                guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw CoreError(message: "Choose a folder to add to your library.")
                }
                let bookmark = try root.bookmarkData(options: .minimalBookmark,
                                                     includingResourceValuesForKeys: nil, relativeTo: nil)
                return SavedFolder(id: UUID(), name: root.lastPathComponent, bookmark: bookmark)
            }
        }.value
    }

    static func list(_ folder: SavedFolder, path: String = "",
                     coordination: any FileCoordinating = SystemFileCoordination()) async throws -> [Entry] {
        try await Task.detached(priority: .userInitiated) {
            let access = try FolderAccess(folder: folder)
            let target = try file(path, in: access, allowRoot: true)
            return try coordination.coordinate(at: target, writing: false) { url in
                let path = try relativePath(for: url, in: access, allowRoot: true)
                let entries: [Entry]? = try Core.request("list", root: access.root, path: path)
                return entries ?? []
            }
        }.value
    }

    static func open(_ folder: SavedFolder, path: String,
                     coordination: any FileCoordinating = SystemFileCoordination()) async throws -> OpenedFile {
        try await Task.detached(priority: .userInitiated) {
            let access = try FolderAccess(folder: folder)
            let target = try file(path, in: access)
            return try coordination.coordinate(at: target, writing: false) { url in
                let path = try relativePath(for: url, in: access)
                guard let document: Document = try Core.request("read", root: access.root, path: path) else {
                    throw CoreError(message: "This file could not be opened.")
                }
                let native = [.pdf, .image, .rtf, .audio, .video].contains(document.kind)
                let preview = native ? try snapshot(file(path, in: access)) : nil
                return OpenedFile(access: access, document: document, preview: preview)
            }
        }.value
    }

    static func save(_ folder: SavedFolder, path: String, revision: String, source: String,
                     coordination: any FileCoordinating = SystemFileCoordination()) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let access = try FolderAccess(folder: folder)
            let target = try file(path, in: access)
            return try coordination.coordinate(at: target, writing: true) { url in
                if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
                    try CloudVersions.ensureWritable(url)
                }
                let path = try relativePath(for: url, in: access)
                guard let revision: String = try Core.request("save", root: access.root, path: path,
                                                              values: ["revision": revision, "source": source]) else {
                    throw CoreError(message: "This file could not be saved. Your draft is still available.")
                }
                return revision
            }
        }.value
    }

    static func image(_ path: String, access: FolderAccess,
                      coordination: any FileCoordinating = SystemFileCoordination()) throws -> (Data, String) {
        let target = try file(path, in: access)
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                     "webp": "image/webp", "avif": "image/avif", "bmp": "image/bmp", "svg": "image/svg+xml"]
        return try coordination.coordinate(at: target, writing: false) { url in
            let path = try relativePath(for: url, in: access)
            let actual = try file(path, in: access)
            guard let mime = types[actual.pathExtension.lowercased()] else { throw URLError(.noPermissionsToReadFile) }
            let values = try actual.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 24 * 1024 * 1024 else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            return (try Data(contentsOf: actual), mime)
        }
    }

    static func importFiles(_ urls: [URL], into directory: URL) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("FolioImport-\(UUID())")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            var staged: [URL] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try coordinated(at: url) { source in
                    let attrs = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard attrs.isRegularFile == true, attrs.isSymbolicLink != true else {
                        throw CoreError(message: "Use Add Folder to open a folder. Import Files accepts individual files.")
                    }
                    guard let size = attrs.fileSize, size <= maximumPreviewBytes else {
                        throw CoreError(message: "This file exceeds the 128 MiB import limit.")
                    }
                    let item = staging.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
                    let copy = item.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.copyItem(at: source, to: copy)
                    staged.append(copy)
                }
            }
            var imported: [URL] = []
            do {
                for source in staged {
                    var destination = directory.appendingPathComponent(source.lastPathComponent)
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: destination.path) {
                        let stem = source.deletingPathExtension().lastPathComponent
                        let ext = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
                        destination = directory.appendingPathComponent("\(stem) \(suffix)\(ext)")
                        suffix += 1
                    }
                    try FileManager.default.moveItem(at: source, to: destination)
                    imported.append(destination)
                }
            } catch {
                for item in imported { try? FileManager.default.removeItem(at: item) }
                throw error
            }
            return imported.map(\.lastPathComponent)
        }.value
    }

    static func export(_ folder: SavedFolder, path: String,
                       coordination: any FileCoordinating = SystemFileCoordination()) async throws -> PreviewFile {
        try await Task.detached(priority: .userInitiated) {
            let access = try FolderAccess(folder: folder)
            return try coordination.coordinate(at: file(path, in: access), writing: false) { url in
                let path = try relativePath(for: url, in: access)
                return try snapshot(file(path, in: access))
            }
        }.value
    }

    static func file(_ path: String, in access: FolderAccess, allowRoot: Bool = false) throws -> URL {
        if allowRoot && path.isEmpty { return access.root }
        guard let url = Core.file(path, in: access.root) else { throw URLError(.noPermissionsToReadFile) }
        return url
    }

    private static func relativePath(for url: URL, in access: FolderAccess, allowRoot: Bool = false) throws -> String {
        let root = access.root.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard url.isFileURL, components.starts(with: root) else { throw URLError(.noPermissionsToReadFile) }
        let path = components.dropFirst(root.count).joined(separator: "/")
        _ = try file(path, in: access, allowRoot: allowRoot)
        return path
    }

    static func coordinated<T>(at url: URL, writing: Bool = false, _ operation: (URL) throws -> T) throws -> T {
        try SystemFileCoordination().coordinate(at: url, writing: writing, operation)
    }

    private static func snapshot(_ url: URL) throws -> PreviewFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumPreviewBytes else {
            throw CoreError(message: "This preview exceeds the 128 MiB limit or is not a regular file.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = PreviewFile(url: directory.appendingPathComponent(url.lastPathComponent), directory: directory)
        try FileManager.default.copyItem(at: url, to: file.url)
        return file
    }
}
