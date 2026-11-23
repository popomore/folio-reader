import AppKit
import Foundation
import UniformTypeIdentifiers

@main
struct ArchiveCheck {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw CoreError(message: message) }
    }

    static func reject(_ file: URL, limits: ArchiveContents.Limits = .init(), containing text: String? = nil) throws {
        do {
            _ = try ArchiveContents.open(file, limits: limits)
        } catch {
            if let text { try require(error.localizedDescription.localizedCaseInsensitiveContains(text), "Unexpected error for \(file.lastPathComponent): \(error)") }
            return
        }
        throw CoreError(message: "Expected rejection of \(file.lastPathComponent)")
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let app = Bundle(path: CommandLine.arguments[1]),
              let resources = Bundle(path: CommandLine.arguments[1] + "/Contents/PlugIns/FolioQuickLook.appex") else {
            throw CoreError(message: "Usage: check-archive-preview <app> <fixtures>")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let before = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("folio-archive-") }.sorted()
        let extensions = ["zip", "tar", "tar.gz", "tgz", "tar.bz2", "tbz", "tbz2", "tar.xz", "txz", "7z", "rar"]
        for ext in extensions {
            let file = root.appendingPathComponent("example." + ext)
            let original = try Data(contentsOf: file)
            let contents = try ArchiveContents.open(file)
            let readme = contents.index.items.first { $0.path == "README.md" }
            try require(readme != nil && readme?.unavailableReason == nil, "Missing README for \(ext)")
            let document: Document? = try Core.request("read", root: contents.root, path: "README.md")
            try require(document?.preview?.html.contains("Archive fixture") == true, "Missing Markdown preview for \(ext)")
            try require(FileManager.default.fileExists(atPath: contents.root.appendingPathComponent("docs/guide.md").path), "Relative document missing for \(ext)")
            if ext != "rar" {
                try require(FileManager.default.fileExists(atPath: contents.root.appendingPathComponent("images/pixel.png").path), "Relative image missing for \(ext)")
                let png = try Data(contentsOf: contents.root.appendingPathComponent("images/pixel.png"))
                guard let image = NSImage(data: png), image.isValid, let bitmap = NSBitmapImageRep(data: png),
                      let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
                    throw CoreError(message: "The archived image could not be decoded.")
                }
                try require(bitmap.pixelsWide >= 100 && bitmap.pixelsHigh >= 100 && center.alphaComponent > 0.9 && center.blueComponent < 0.8,
                            "The archive image fixture must have a visible size and colored content.")
                try require(contents.index.items.contains { $0.path == "资料/说明.md" }, "Unicode path missing for \(ext)")
            }
            try require(try Data(contentsOf: file) == original, "The original archive changed.")
            try verifyQuickLook(file, app: app, resources: resources, expected: "README.md")
        }
        for ext in ["gz", "bz2", "xz"] {
            let file = root.appendingPathComponent("notes.md." + ext)
            let contents = try ArchiveContents.open(file)
            try require(contents.index.items.map(\.path) == ["notes.md"], "Compressed streams should retain the original filename.")
            try require(try String(contentsOf: contents.root.appendingPathComponent("notes.md"), encoding: .utf8).contains("Archive fixture"), "Compressed stream content missing.")
            try verifyQuickLook(file, app: app, resources: resources, expected: "notes.md")
        }
        try require(try ArchiveContents.index(root.appendingPathComponent("empty.zip")).items.isEmpty, "Empty ZIP should open.")
        var temporary: URL?
        do {
            let contents = try ArchiveContents.open(root.appendingPathComponent("example.zip"))
            temporary = contents.root
        }
        try require(temporary.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "Unpacked contents were not removed.")
        let links = try ArchiveContents.open(root.appendingPathComponent("links.tar"))
        try require(links.index.items.count == 3 && links.index.items.allSatisfy { $0.unavailableReason != nil }, "Links and Git metadata must be unavailable.")
        for item in links.index.items {
            try require((try? FileManager.default.attributesOfItem(atPath: links.root.appendingPathComponent(item.path).path)) == nil,
                        "A blocked entry was materialized.")
        }
        let nested = try ArchiveContents.open(root.appendingPathComponent("nested.zip"))
        let inner = try ArchiveContents.open(nested.root.appendingPathComponent("example.zip"))
        try require(inner.index.items.contains { $0.path == "README.md" }, "Nested archive should open.")
        for name in ["traversal", "absolute", "windows", "backslash", "control", "deep"] {
            try reject(root.appendingPathComponent(name + ".zip"), containing: "unsafe")
        }
        for name in ["duplicate", "unicode-collision", "conflict"] {
            try reject(root.appendingPathComponent(name + ".zip"), containing: "conflict")
        }
        try reject(root.appendingPathComponent("encrypted.zip"), containing: "Password-protected")
        try reject(root.appendingPathComponent("damaged.zip"), containing: "damaged")
        try reject(root.appendingPathComponent("corrupt-data.zip"))
        try reject(root.appendingPathComponent("fake.gz"), containing: "compressed stream")
        var limits = ArchiveContents.Limits()
        limits.fileBytes = 64
        try reject(root.appendingPathComponent("large.zip"), limits: limits, containing: "limit")
        limits = .init()
        limits.totalBytes = 64
        try reject(root.appendingPathComponent("example.zip"), limits: limits, containing: "limit")
        limits = .init()
        limits.entries = 3
        try reject(root.appendingPathComponent("many.zip"), limits: limits, containing: "too many")
        limits = .init()
        limits.inputBytes = 8
        try reject(root.appendingPathComponent("example.zip"), limits: limits, containing: "input limit")
        limits = .init()
        limits.seconds = -1
        try reject(root.appendingPathComponent("example.zip"), limits: limits, containing: "too long")
        try verifyQuickLook(root.appendingPathComponent("html-name.zip"), app: app, resources: resources, expected: "&lt;img src=x onerror=alert(1)&gt;.md")
        try verifyQuickLook(root.appendingPathComponent("listing.zip"), app: app, resources: resources, expected: "Showing the first 500 entries")
        let cancelled = Task {
            try Task.checkCancellation()
            return try ArchiveContents.open(root.appendingPathComponent("example.zip"))
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw CoreError(message: "Cancelled archive reads should stop.")
        } catch is CancellationError {}
        let after = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("folio-archive-") }.sorted()
        let retained = Set([links.root.lastPathComponent, nested.root.lastPathComponent, inner.root.lastPathComponent])
        try require(after.filter { !retained.contains($0) } == before, "An archive read leaked a temporary folder.")
        print("Archive checks passed: formats, extraction, document rendering, Quick Look registration, unsafe paths, links, corruption, encryption, limits, cancellation, and cleanup.")
    }

    static func verifyQuickLook(_ file: URL, app: Bundle, resources: Bundle, expected: String) throws {
        let extensionInfo = resources.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
        let attributes = extensionInfo?["NSExtensionAttributes"] as? [String: Any]
        let registered = Set(attributes?["QLSupportedContentTypes"] as? [String] ?? [])
        let imported = app.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]] ?? []
        let documentTypes = app.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        let openTypes = Set(documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        let candidates = UTType.types(tag: file.pathExtension, tagClass: .filenameExtension, conformingTo: nil).map(\.identifier)
        let declared = imported.compactMap { declaration -> String? in
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            guard (tags?["public.filename-extension"] as? [String])?.contains(file.pathExtension) == true else { return nil }
            return declaration["UTTypeIdentifier"] as? String
        }
        try require(!registered.isDisjoint(with: candidates + declared), "Missing archive Quick Look registration: \(file.pathExtension)")
        try require(!openTypes.isDisjoint(with: candidates + declared), "Missing archive Open With registration: \(file.pathExtension)")
        guard case .html(let data, let charts) = try PreviewProvider.content(at: file, resources: resources) else {
            throw CoreError(message: "Expected an HTML archive listing.")
        }
        let html = String(decoding: data, as: UTF8.self)
        try require(!charts && html.contains(expected) && html.contains("default-src 'none'"), "Missing safe archive listing: \(file.lastPathComponent)")
        try require(!html.contains("<img src=x"), "Archive filenames must be escaped.")
    }
}
