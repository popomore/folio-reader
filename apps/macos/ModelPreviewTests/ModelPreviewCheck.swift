import AppKit
import Foundation
import WebKit

@main
struct ModelPreviewCheck {
    struct Fixture: Decodable {
        let name: String
        let meshes: Int
        let triangles: Int
        let error: String?
    }

    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, let app = Bundle(path: args[1]) else {
            throw CoreError(message: "Usage: check-model-preview <app> <fixtures> <parser-check.js>")
        }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: args[2], isDirectory: true).resolvingSymlinksInPath()
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let parserChecks = try String(contentsOfFile: args[3], encoding: .utf8)
        try verifyAccess(root: root)
        let documentTypes = app.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        let imported = app.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]] ?? []
        let declared = Set(documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        let quicklook = Bundle(path: "\(args[1])/Contents/PlugIns/FolioQuickLook.appex")!
        let extensionInfo = quicklook.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
        let attributes = extensionInfo?["NSExtensionAttributes"] as? [String: Any]
        let registered = Set(attributes?["QLSupportedContentTypes"] as? [String] ?? [])
        for fixture in fixtures {
            let file = root.appendingPathComponent(fixture.name)
            let kind = try Core.kind(of: fixture.name)
            try require(kind == .model, "The core did not recognize \(fixture.name).")
            let suffix = file.pathExtension.lowercased()
            let identifiers = imported.compactMap { type -> String? in
                let tags = type["UTTypeTagSpecification"] as? [String: Any]
                guard (tags?["public.filename-extension"] as? [String])?.contains(suffix) == true else { return nil }
                return type["UTTypeIdentifier"] as? String
            }
            try require(!declared.isDisjoint(with: identifiers) && !registered.isDisjoint(with: identifiers),
                        "The app and Quick Look must register .\(suffix).")
            guard case .model(let routed) = try PreviewProvider.content(at: file, resources: quicklook), routed == file else {
                throw CoreError(message: "Quick Look did not route \(fixture.name) to the model renderer.")
            }
            let session = ModelPreviewSession(file: file, resources: app, snapshot: true)
            let view = session.makeView(size: CGSize(width: 800, height: 600))
            defer { session.dispose(view) }
            let deadline = ContinuousClock.now + .seconds(20)
            while session.state == "loading", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if let expected = fixture.error {
                try require(session.state == "error" && session.failure?.localizedCaseInsensitiveContains(expected) == true,
                            "Expected \(fixture.name) to fail with '\(expected)', got \(session.failure ?? session.state).")
            } else {
                try require(session.state == "ready", "\(fixture.name): \(session.failure ?? "model timed out")")
                let state = try await view.callAsyncJavaScript("return window.folioModelState", contentWorld: .page) as? [String: Any]
                try require(state?["meshes"] as? Int == fixture.meshes && state?["triangles"] as? Int == fixture.triangles,
                            "Unexpected rendered geometry for \(fixture.name): \(state ?? [:])")
                if fixture.name == "shear.3mf" {
                    try require(state?["dimensions"] as? String == "60 × 20 × 20",
                                "The rendered 3MF must preserve component and build shear transforms.")
                }
                if fixture.name == "assembly.3mf" {
                    _ = try await view.evaluateJavaScript(parserChecks)
                    let checks = try await view.callAsyncJavaScript("return await window.folioModelParserChecks()", contentWorld: .page)
                    print(checks ?? "")
                    let wireframe = try await view.callAsyncJavaScript("document.querySelector('#wireframe').click(); return document.querySelector('#wireframe').getAttribute('aria-pressed')", contentWorld: .page)
                    try require(wireframe as? String == "true", "The wireframe control did not toggle.")
                    _ = try await view.callAsyncJavaScript("document.querySelector('#wireframe').click(); document.querySelector('#reset').click()", contentWorld: .page)
                    let zoomAndReset = try await view.callAsyncJavaScript("""
                        const before = window.folioModelSnapshot();
                        document.querySelector('canvas').dispatchEvent(new KeyboardEvent('keydown', {key: '+'}));
                        const zoomed = window.folioModelSnapshot();
                        document.querySelector('#reset').click();
                        return before !== zoomed && before === window.folioModelSnapshot();
                        """, contentWorld: .page)
                    try require(zoomAndReset as? Bool == true, "Zoom must change the rendered model and Reset view must restore it.")
                    let encoded = try await view.callAsyncJavaScript("return window.folioModelSnapshot()", contentWorld: .page) as? String
                    try require(encoded.flatMap { Data(base64Encoded: $0) }.map(hasModelPixels) == true,
                                "The WebGL canvas did not contain rendered geometry.")
                }
            }
            print("Verified \(fixture.name): \(session.state)")
        }
        let still = try await ModelSnapshot.render(root.appendingPathComponent("assembly.3mf"), resources: quicklook)
        try require(hasModelPixels(still), "Finder's snapshot must contain visible geometry.")
        try still.write(to: root.appendingPathComponent("quicklook-assembly.png"))
        print("Verified \(fixtures.count) model fixtures, offline resource boundaries, WebGL controls and Finder snapshot.")
    }

    @MainActor
    private static func verifyAccess(root: URL) throws {
        let session = ModelPreviewSession(file: root.appendingPathComponent("cube.gltf"))
        _ = try session.resource(URL(string: "folio-model://preview/files/cube.bin")!)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).bin")
        try Data([0]).write(to: outside)
        let link = root.appendingPathComponent("escape-link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let large = root.appendingPathComponent("oversized.stl")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ModelPreviewSession.maxBytes + 1))
        try handle.close()
        defer {
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: large)
        }
        for url in ["https://example.com/model.bin", "folio-model://preview/files/../outside.bin",
                    "folio-model://preview/files/escape-link.bin", "folio-model://preview/files/oversized.stl",
                    "folio-model://preview/files/manifest.json"] {
            var rejected = false
            do { _ = try session.resource(URL(string: url)!) } catch { rejected = true }
            try require(rejected, "The model resource boundary accepted \(url).")
        }
    }

    private static func hasModelPixels(_ data: Data) -> Bool {
        guard let image = NSBitmapImageRep(data: data), image.pixelsWide >= 400, image.pixelsHigh >= 300 else { return false }
        var colors = Set<String>()
        for x in stride(from: image.pixelsWide / 4, to: image.pixelsWide * 3 / 4, by: 16) {
            for y in stride(from: image.pixelsHigh / 4, to: image.pixelsHigh * 3 / 4, by: 16) {
                if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        return colors.count > 8
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CoreError(message: message) }
    }
}
