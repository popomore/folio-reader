import Darwin
import Foundation

struct ArchiveLink: Sendable {
    let path: String
    let fragment: String?

    init(_ url: URL) {
        path = String(url.path.dropFirst())
        fragment = url.fragment?.removingPercentEncoding
    }
}

struct ArchiveItem: Identifiable, Sendable {
    let path: String
    let directory: Bool
    let bytes: Int64
    let unavailableReason: String?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct ArchiveIndex: Sendable {
    let items: [ArchiveItem]
    let bytes: Int64

    var fileCount: Int { items.filter { !$0.directory }.count }
}

final class ArchiveContents: Sendable {
    struct Limits: Sendable {
        var inputBytes: Int64 = 128 * 1024 * 1024
        var fileBytes: Int64 = 128 * 1024 * 1024
        var totalBytes: Int64 = 256 * 1024 * 1024
        var entries = 10_000
        var seconds: Double = 30
    }

    let root: URL
    let index: ArchiveIndex

    private init(root: URL, index: ArchiveIndex) {
        self.root = root
        self.index = index
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static func open(_ file: URL, limits: Limits = Limits()) throws -> ArchiveContents {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-archive-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            return try ArchiveContents(root: root, index: scan(file, destination: root, limits: limits))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    static func index(_ file: URL, limits: Limits = Limits()) throws -> ArchiveIndex {
        try scan(file, destination: nil, limits: limits)
    }

    private static func scan(_ file: URL, destination: URL?, limits: Limits) throws -> ArchiveIndex {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let descriptor = file.resolvingSymlinksInPath().path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw CoreError(message: "This archive could not be opened.") }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw CoreError(message: "Choose a regular archive file.")
        }
        guard metadata.st_size <= limits.inputBytes else {
            throw CoreError(message: "This archive exceeds the 128 MiB input limit.")
        }
        guard let reader = archive_read_new() else {
            throw CoreError(message: "The archive reader could not be created.")
        }
        defer { archive_read_free(reader) }
        // Enable only built-in filters, so reading never launches helper programs.
        let support = [
            archive_read_support_filter_none(reader), archive_read_support_filter_gzip(reader),
            archive_read_support_filter_bzip2(reader), archive_read_support_filter_xz(reader),
            archive_read_support_format_zip(reader), archive_read_support_format_tar(reader),
            archive_read_support_format_7zip(reader), archive_read_support_format_rar(reader),
            archive_read_support_format_rar5(reader)
        ]
        guard support.allSatisfy({ $0 == 0 }) else { throw failure(reader) }
        let raw = ["gz", "bz2", "xz"].contains(file.pathExtension.lowercased())
        if raw, archive_read_support_format_raw(reader) != 0 { throw failure(reader) }
        guard archive_read_open_fd(reader, descriptor, 64 * 1024) == 0 else {
            throw failure(reader)
        }

        let deadline = Date().addingTimeInterval(limits.seconds)
        var items: [ArchiveItem] = []
        var paths: [String: Bool] = [:]
        var explicitPaths = Set<String>()
        var total: Int64 = 0
        var headers = 0
        while true {
            try check(deadline)
            try checkInput(reader, limits: limits)
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == 1 { break }
            guard status == 0, let entry else { throw failure(reader) }
            headers += 1
            guard headers <= limits.entries else {
                throw CoreError(message: "This archive contains too many entries (maximum 10,000).")
            }
            guard archive_entry_is_encrypted(entry) == 0 else {
                throw CoreError(message: "Password-protected archives are not supported.")
            }
            let directory = archive_entry_filetype(entry) == 0o040000
            let regular = archive_entry_filetype(entry) == 0o100000 && archive_entry_hardlink(entry) == nil
            var name = try entryName(entry)
            if archive_format(reader) == 0x90000 {
                guard raw, archive_filter_code(reader, 0) != 0 else {
                    throw CoreError(message: "This file is not a supported compressed stream.")
                }
                name = file.deletingPathExtension().lastPathComponent
            }
            let path = try safePath(name, directory: directory)
            let advertised = archive_entry_size(entry)
            guard advertised >= 0, advertised <= limits.fileBytes else {
                throw CoreError(message: "An archive entry exceeds the 128 MiB preview limit.")
            }
            guard advertised <= limits.totalBytes - total else {
                throw CoreError(message: "This archive exceeds the 256 MiB unpacked limit.")
            }
            if path.isEmpty {
                _ = try consume(reader, output: nil, total: &total, limits: limits, deadline: deadline)
                continue
            }
            try register(path, directory: directory, paths: &paths, explicitPaths: &explicitPaths, limit: limits.entries)
            let reason: String?
            if !directory && !regular {
                reason = "Links and special files are not previewed."
            } else if path.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) {
                reason = "Git metadata is not previewed."
            } else {
                reason = nil
            }
            let output = destination.flatMap { regular && reason == nil ? $0.appendingPathComponent(path) : nil }
            if let destination, directory, reason == nil {
                try FileManager.default.createDirectory(at: destination.appendingPathComponent(path),
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let bytes = try consume(reader, output: output, total: &total, limits: limits, deadline: deadline)
            items.append(ArchiveItem(path: path, directory: directory, bytes: bytes, unavailableReason: reason))
        }
        return ArchiveIndex(items: items, bytes: total)
    }

    private static func consume(_ reader: OpaquePointer, output: URL?, total: inout Int64,
                                limits: Limits, deadline: Date) throws -> Int64 {
        var handle: FileHandle?
        if let output {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let descriptor = output.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
            guard descriptor >= 0 else { throw CoreError(message: "An archive entry conflicts with another path.") }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        defer { try? handle?.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var bytes: Int64 = 0
        while true {
            try check(deadline)
            try checkInput(reader, limits: limits)
            let count = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress!, $0.count) }
            guard count >= 0 else { throw failure(reader) }
            if count == 0 { return bytes }
            bytes += Int64(count)
            total += Int64(count)
            guard bytes <= limits.fileBytes, total <= limits.totalBytes else {
                throw CoreError(message: "This archive exceeds the unpacked preview limits (128 MiB per file, 256 MiB total).")
            }
            if let handle { try handle.write(contentsOf: Data(buffer.prefix(count))) }
        }
    }

    private static func entryName(_ entry: OpaquePointer) throws -> String {
        guard let raw = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry),
              strnlen(raw, 4097) <= 4096, let name = String(validatingCString: raw) else {
            throw CoreError(message: "An archive entry has an invalid or unsupported filename.")
        }
        return name
    }

    private static func safePath(_ name: String, directory: Bool) throws -> String {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !parts.contains(".."), parts.count <= 64 else {
            throw CoreError(message: "This archive contains an unsafe file path.")
        }
        let normalized = parts.filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
        guard !normalized.isEmpty || directory else {
            throw CoreError(message: "An archive entry has an empty filename.")
        }
        return normalized
    }

    private static func register(_ path: String, directory: Bool, paths: inout [String: Bool],
                                 explicitPaths: inout Set<String>, limit: Int) throws {
        let parts = path.split(separator: "/")
        let key = path.precomposedStringWithCanonicalMapping.lowercased()
        guard explicitPaths.insert(key).inserted else {
            throw CoreError(message: "This archive contains duplicate or conflicting file paths.")
        }
        for end in 1...parts.count {
            let component = parts.prefix(end).joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
            let isDirectory = end < parts.count || directory
            if let previous = paths[component], previous != isDirectory {
                throw CoreError(message: "This archive contains duplicate or conflicting file paths.")
            }
            paths[component] = isDirectory
            guard paths.count <= limit else {
                throw CoreError(message: "This archive contains too many entries (maximum 10,000).")
            }
        }
    }

    private static func check(_ deadline: Date) throws {
        try Task<Never, Never>.checkCancellation()
        guard Date() < deadline else { throw CoreError(message: "This archive took too long to open.") }
    }

    private static func checkInput(_ reader: OpaquePointer, limits: Limits) throws {
        guard archive_filter_bytes(reader, -1) <= limits.inputBytes else {
            throw CoreError(message: "This archive exceeds the 128 MiB input limit.")
        }
    }

    private static func failure(_ reader: OpaquePointer) -> CoreError {
        let message = archive_error_string(reader).map { String(cString: $0) } ?? "The archive could not be read."
        if ["password", "passphrase", "encrypt"].contains(where: { message.localizedCaseInsensitiveContains($0) }) {
            return CoreError(message: "Password-protected archives are not supported.")
        }
        return CoreError(message: "This archive is damaged or uses an unsupported format. \(message)")
    }
}
