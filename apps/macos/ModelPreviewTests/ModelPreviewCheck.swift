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
                    log(checks ?? "")
                    _ = try await view.callAsyncJavaScript("window.dispatchEvent(new PageTransitionEvent('pagehide'))", contentWorld: .page)
                    try await Task.sleep(for: .milliseconds(100))
                    try require(session.state == "ready", "A retained native preview must not destroy its renderer on pagehide: \(session.failure ?? session.state)")
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
                        window.folioControlBefore = {state: window.folioModelViewState(), image: window.folioModelSnapshot().rgba};
                        document.querySelector('canvas').dispatchEvent(new KeyboardEvent('keydown', {key: '+'}));
                        window.folioModelSnapshot();
                        """, contentWorld: .page)
                    try await Task.sleep(for: .milliseconds(50))
                    _ = try await view.callAsyncJavaScript("""
                        window.folioControlZoom = {state: window.folioModelViewState(), image: window.folioModelSnapshot().rgba};
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
                    let png = try await ModelSnapshot.capture(view, timeout: .seconds(5))
                    try require(hasModelPixels(png),
                                "The WebGL canvas did not contain rendered geometry.")
                    let disposed = try await view.callAsyncJavaScript("window.folioModelDispose(); window.folioModelDispose(); return window.folioModelViewState().disposed", contentWorld: .page)
                    try require(disposed as? Bool == true, "Explicit native renderer cleanup must be idempotent.")
                }
            }
            log("Verified \(fixture.name): \(session.state)")
        }
        let still = try await ModelSnapshot.render(root.appendingPathComponent("assembly.3mf"), resources: quicklook)
        try require(hasModelPixels(still), "Finder's snapshot must contain visible geometry.")
        try still.write(to: root.appendingPathComponent("quicklook-assembly.png"))
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("appearance during loading", { try await verifyLoadingAppearance(app: app, root: root) }),
            ("context failure during the first frame", { try await verifyFirstFrameFailure(app: app, root: root) }),
            ("snapshot without WebKit PNG serialization", { try await verifySnapshotReadback(app: app, root: root) }),
            ("first resource failure", { try await verifyFirstFailure(app: app) }),
            ("Quick Look sibling-resource policy", {
                var rejected = false
                do { _ = try await ModelSnapshot.render(root.appendingPathComponent("cube.gltf"), resources: quicklook) }
                catch { rejected = error.localizedDescription.contains("self-contained") }
                try require(rejected, "Finder must explicitly reject glTF dependencies outside the selected file.")
            }),
        ]
        var failures: [String] = []
        for (name, check) in checks {
            do { try await check(); log("Verified \(name)") }
            catch { failures.append("\(name): \(error.localizedDescription)") }
        }
        try require(failures.isEmpty, failures.joined(separator: "\n"))
        log("Verified \(fixtures.count) model fixtures, offline resource boundaries, WebGL controls and Finder snapshot.")
    }

    private static func log(_ message: Any) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    @MainActor
    private static func verifySnapshotReadback(app: Bundle, root: URL) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: """
            HTMLCanvasElement.prototype.toDataURL = () => 'data:,';
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let session = ModelPreviewSession(file: root.appendingPathComponent("assembly.3mf"), resources: app, snapshot: true)
        let view = session.makeView(size: CGSize(width: 800, height: 600), configuration: configuration)
        defer { session.dispose(view) }
        let deadline = ContinuousClock.now + .seconds(20)
        while session.state == "loading", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try require(session.state == "ready", session.failure ?? "The snapshot fixture timed out.")
        let png = try await ModelSnapshot.capture(view, timeout: .seconds(5))
        try require(hasModelPixels(png), "Native PNG capture must retain model pixels when WebKit serialization fails.")
        try await verifyCaptureDeadline(in: view)
        _ = try await view.callAsyncJavaScript("""
            window.folioModelSnapshot = () => ({width:2, height:2,
                rgba:btoa(String.fromCharCode(255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255))});
            """, contentWorld: .page)
        let corners = try await ModelSnapshot.capture(view, timeout: .seconds(5))
        let bitmap = NSBitmapImageRep(data: corners)
        let top = bitmap?.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)
        let bottom = bitmap?.colorAt(x: 0, y: 1)?.usingColorSpace(.deviceRGB)
        try require(top?.blueComponent == 1 && bottom?.redComponent == 1, "Native PNG encoding must preserve RGBA channels and flip WebGL rows.")
        _ = try await view.callAsyncJavaScript("window.folioModelSnapshot = () => ({width:2, height:2, rgba:'AAAA'})", contentWorld: .page)
        var rejected = false
        do { _ = try await ModelSnapshot.capture(view, timeout: .seconds(5)) } catch { rejected = true }
        try require(rejected, "Native capture must reject an incomplete RGBA buffer.")
    }

    @MainActor
    private static func verifyCaptureDeadline(in view: WKWebView) async throws {
        _ = try await view.callAsyncJavaScript("""
            window.originalSnapshot = window.folioModelSnapshot;
            window.folioModelSnapshot = () => new Promise(resolve => {
                window.releaseSnapshot = () => resolve(window.originalSnapshot());
            });
            """, contentWorld: .page)
        for cancel in [false, true] {
            let release = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                _ = try? await view.callAsyncJavaScript("window.releaseSnapshot?.()", contentWorld: .page)
            }
            let capture = Task { @MainActor in try await ModelSnapshot.capture(view, timeout: cancel ? .seconds(5) : .milliseconds(100)) }
            if cancel { try await Task.sleep(for: .milliseconds(100)); capture.cancel() }
            var rejected = false
            do { _ = try await capture.value }
            catch { rejected = cancel ? error is CancellationError : error.localizedDescription.contains("too long") }
            release.cancel()
            _ = try? await view.callAsyncJavaScript("window.releaseSnapshot?.()", contentWorld: .page)
            try require(rejected, "Native capture must honor its deadline and cancellation while JavaScript remains pending.")
        }
        _ = try await view.callAsyncJavaScript("window.folioModelSnapshot = window.originalSnapshot", contentWorld: .page)
    }

    @MainActor
    private static func verifyFirstFrameFailure(app: Bundle, root: URL) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: """
            window.heldFrames = [];
            window.requestAnimationFrame = callback => window.heldFrames.push(callback);
            window.cancelAnimationFrame = id => { window.heldFrames[id - 1] = undefined; };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let session = ModelPreviewSession(file: root.appendingPathComponent("cube.glb"), resources: app)
        let view = session.makeView(size: CGSize(width: 600, height: 400), configuration: configuration)
        defer { session.dispose(view) }
        let deadline = ContinuousClock.now + .seconds(20)
        var paused = false
        while !paused, ContinuousClock.now < deadline {
            paused = (try? await view.callAsyncJavaScript("return window.heldFrames?.length >= 2", contentWorld: .page)) as? Bool == true
            if !paused { try await Task.sleep(for: .milliseconds(50)) }
        }
        try require(paused, "The model did not pause before its first frame.")
        _ = try await view.callAsyncJavaScript("""
            document.querySelector('canvas').dispatchEvent(new Event('webglcontextlost', {cancelable:true}));
            for (const callback of window.heldFrames.splice(0)) callback?.(performance.now());
            """, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(50))
        let state = try await view.callAsyncJavaScript("return window.folioModelState.state", contentWorld: .page)
        try require(state as? String == "error", "A late first frame must not overwrite a renderer failure: \(state ?? "nil")")
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
    private static func verifyFirstFailure(app: Bundle) async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("oversized-preview.stl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ModelPreviewSession.maxBytes + 1))
        try handle.close()
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
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for name in ["cube.gltf", "cube.bin", "manifest.json"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        let session = ModelPreviewSession(file: folder.appendingPathComponent("cube.gltf"))
        _ = try session.resource(URL(string: "folio-model://preview/files/cube.bin")!)
        let outside = scratch.appendingPathComponent("outside.bin")
        try Data([0]).write(to: outside)
        let link = folder.appendingPathComponent("escape-link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let large = folder.appendingPathComponent("oversized.stl")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ModelPreviewSession.maxBytes + 1))
        try handle.close()
        for url in ["https://example.com/model.bin", "folio-model://preview/files/../\(outside.lastPathComponent)",
                    "folio-model://preview/files/escape-link.bin", "folio-model://preview/files/oversized.stl",
                    "folio-model://preview/files/manifest.json"] {
            var rejected = false
            do { _ = try session.resource(URL(string: url)!) } catch { rejected = true }
            try require(rejected, "The model resource boundary accepted \(url).")
        }
    }

    private static func scratchDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("folio-model-check-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
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
