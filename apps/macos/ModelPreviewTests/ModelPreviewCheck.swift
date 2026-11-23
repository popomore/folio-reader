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
                    _ = try await view.callAsyncJavaScript("document.querySelector('#wireframe').click()", contentWorld: .page)
                    view.setFrameSize(CGSize(width: 500, height: 700))
                    try await Task.sleep(for: .milliseconds(100))
                    _ = try await view.callAsyncJavaScript("""
                        document.querySelector('#reset').click();
                        window.folioModelSnapshot();
                        """, contentWorld: .page)
                    try await Task.sleep(for: .milliseconds(50))
                    _ = try await view.callAsyncJavaScript("""
                        window.folioControlBefore = {state: window.folioModelViewState(), image: window.folioModelSnapshot()};
                        document.querySelector('canvas').dispatchEvent(new KeyboardEvent('keydown', {key: '+'}));
                        window.folioModelSnapshot();
                        """, contentWorld: .page)
                    try await Task.sleep(for: .milliseconds(50))
                    _ = try await view.callAsyncJavaScript("""
                        window.folioControlZoom = {state: window.folioModelViewState(), image: window.folioModelSnapshot()};
                        document.querySelector('#reset').click();
                        window.folioModelSnapshot();
                        """, contentWorld: .page)
                    try await Task.sleep(for: .milliseconds(50))
                    let zoomAndReset = try await view.callAsyncJavaScript("""
                        const beforeState = window.folioControlBefore.state;
                        const zoomState = window.folioControlZoom.state;
                        const resetState = window.folioModelViewState();
                        const zoomChanged = window.folioControlBefore.image !== window.folioControlZoom.image;
                        const values = (state) => [...state.position, ...state.target, state.aspect, state.near, state.far];
                        const resetRestored = values(beforeState).every((value, i) => Math.abs(value - values(resetState)[i]) < 1e-8);
                        const cameraMoved = beforeState.position.some((value, i) => Math.abs(value - zoomState.position[i]) > 1e-6);
                        let gpu;
                        if (!zoomChanged) {
                            const canvas = document.querySelector('canvas');
                            const gl = canvas.getContext('webgl2');
                            const colors = new Set();
                            if (gl) {
                                const pixel = new Uint8Array(4);
                                for (let x = 1; x <= 5; x++) for (let y = 1; y <= 5; y++) {
                                    gl.readPixels(Math.floor(gl.drawingBufferWidth * x / 6), Math.floor(gl.drawingBufferHeight * y / 6),
                                                  1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
                                    colors.add([...pixel].join(','));
                                }
                            }
                            gpu = {lost: gl?.isContextLost(), error: gl?.getError(), attributes: gl?.getContextAttributes(),
                                   pixels: [...colors], width: canvas.width, height: canvas.height,
                                   beforeLength: window.folioControlBefore.image.length, zoomLength: window.folioControlZoom.image.length,
                                   modelState: window.folioModelState};
                        }
                        return {zoomChanged, cameraMoved, resetRestored, beforeState, zoomState, resetState, gpu};
                        """, contentWorld: .page) as? [String: Any]
                    try require(zoomAndReset?["zoomChanged"] as? Bool == true && zoomAndReset?["cameraMoved"] as? Bool == true &&
                                zoomAndReset?["resetRestored"] as? Bool == true,
                                "Zoom/reset must change the rendered view and restore its camera state: \(zoomAndReset ?? [:])")
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
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("appearance during loading", { try await verifyLoadingAppearance(app: app, root: root) }),
            ("first resource failure", { try await verifyFirstFailure(app: app, root: root) }),
            ("Quick Look sibling-resource policy", {
                var rejected = false
                do { _ = try await ModelSnapshot.render(root.appendingPathComponent("cube.gltf"), resources: quicklook) }
                catch { rejected = error.localizedDescription.contains("self-contained") }
                try require(rejected, "Finder must explicitly reject glTF dependencies outside the selected file.")
            }),
        ]
        var failures: [String] = []
        for (name, check) in checks {
            do { try await check(); print("Verified \(name)") }
            catch { failures.append("\(name): \(error.localizedDescription)") }
        }
        try require(failures.isEmpty, failures.joined(separator: "\n"))
        print("Verified \(fixtures.count) model fixtures, offline resource boundaries, WebGL controls and Finder snapshot.")
    }

    @MainActor
    private static func verifyLoadingAppearance(app: Bundle, root: URL) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: """
            let modelLoader;
            Object.defineProperty(window, 'folioLoadModel', {
                get() { return modelLoader; },
                set(loader) {
                    modelLoader = async (...args) => {
                        await new Promise(resolve => { window.releaseModel = resolve; });
                        return loader(...args);
                    };
                }
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let session = ModelPreviewSession(file: root.appendingPathComponent("cube.glb"), resources: app, snapshot: true)
        let view = session.makeView(size: CGSize(width: 600, height: 400), configuration: configuration)
        defer { session.dispose(view) }
        let deadline = ContinuousClock.now + .seconds(20)
        var paused = false
        while !paused, ContinuousClock.now < deadline {
            paused = (try? await view.callAsyncJavaScript("return typeof window.releaseModel === 'function'", contentWorld: .page)) as? Bool == true
            if !paused { try await Task.sleep(for: .milliseconds(50)) }
        }
        try require(paused, "The loading fixture did not reach its controlled pause.")
        session.appearance("dark", colors: ["--paper": "#123456"], in: view)
        _ = try await view.callAsyncJavaScript("window.releaseModel()", contentWorld: .page)
        while session.state == "loading", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try require(session.state == "ready", session.failure ?? "The appearance fixture timed out.")
        let actual = try await view.callAsyncJavaScript("return document.documentElement.dataset.colorScheme + '|' + getComputedStyle(document.documentElement).getPropertyValue('--paper').trim()", contentWorld: .page)
        try require(actual as? String == "dark|#123456", "The latest appearance was lost during model loading: \(actual ?? "nil")")
    }

    @MainActor
    private static func verifyFirstFailure(app: Bundle, root: URL) async throws {
        let file = root.appendingPathComponent("oversized-preview.stl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ModelPreviewSession.maxBytes + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: file) }
        let session = ModelPreviewSession(file: file, resources: app, snapshot: true)
        let view = session.makeView(size: CGSize(width: 600, height: 400))
        defer { session.dispose(view) }
        let deadline = ContinuousClock.now + .seconds(20)
        var javascriptFailed = false
        while !javascriptFailed, ContinuousClock.now < deadline {
            javascriptFailed = (try? await view.callAsyncJavaScript("return window.folioModelState?.state === 'error'", contentWorld: .page)) as? Bool == true
            if !javascriptFailed { try await Task.sleep(for: .milliseconds(50)) }
        }
        try require(javascriptFailed, "The oversized fixture did not finish reporting its error.")
        try await Task.sleep(for: .milliseconds(50))
        try require(session.failure?.contains("128 MiB") == true, "The specific resource error was overwritten: \(session.failure ?? "nil")")
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
