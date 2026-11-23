import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves bundled viewer code and bounded model resources without network access.
@MainActor
final class ModelPreviewSession: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler {
    static let maxBytes = 128 * 1024 * 1024
    let file: URL
    private let resources: Bundle
    private let snapshot: Bool
    private let allowsFolderResources: Bool
    private let changed: (String, String?) -> Void
    private var bytesRead = 0
    private var scheme = "light"
    private var colors: [String: String] = [:]
    private(set) var state = "loading"
    private(set) var failure: String?

    init(file: URL, resources: Bundle = .main, snapshot: Bool = false, allowsFolderResources: Bool = true,
         changed: @escaping (String, String?) -> Void = { _, _ in }) {
        self.file = file.resolvingSymlinksInPath().standardizedFileURL
        self.resources = resources
        self.snapshot = snapshot
        self.allowsFolderResources = allowsFolderResources
        self.changed = changed
    }

    func makeView(size: CGSize = .zero, configuration: WKWebViewConfiguration = WKWebViewConfiguration()) -> WKWebView {
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self, forURLScheme: "folio-model")
        configuration.userContentController.add(self, name: "folioModel")
        let view = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        view.navigationDelegate = self
        view.load(URLRequest(url: URL(string: "folio-model://preview/model-viewer.html")!))
        return view
    }

    func appearance(_ scheme: String, colors: [String: String], in view: WKWebView) {
        guard self.scheme != scheme || self.colors != colors else { return }
        self.scheme = scheme
        self.colors = colors
        if state == "ready" { applyAppearance(in: view) }
    }

    private func applyAppearance(in view: WKWebView) {
        view.callAsyncJavaScript("window.folioModelAppearance(scheme, colors)",
                                 arguments: ["scheme": scheme, "colors": colors], in: nil, in: .page)
    }

    func resource(_ url: URL) throws -> (Data, String) {
        guard url.scheme == "folio-model", url.host == "preview" else { throw URLError(.unsupportedURL) }
        if ["/model-viewer.html", "/model-viewer.css", "/model-viewer.js"].contains(url.path) {
            let ext = url.pathExtension
            guard let asset = resources.url(forResource: "model-viewer", withExtension: ext) else {
                throw CoreError(message: "The 3D preview resources are missing.")
            }
            let mime = ["html": "text/html", "css": "text/css", "js": "text/javascript"][ext]!
            return (try Data(contentsOf: asset), mime)
        }
        guard url.path.hasPrefix("/files/") else { throw URLError(.noPermissionsToReadFile) }
        let relative = String(url.path.dropFirst("/files/".count))
        if !allowsFolderResources, relative != file.lastPathComponent {
            throw CoreError(message: "Finder Quick Look only previews self-contained models. Open this model in Folio to load files from its folder.")
        }
        let root = file.deletingLastPathComponent()
        let allowed = ["stl", "obj", "ply", "gltf", "glb", "3mf", "bin", "png", "jpg", "jpeg", "webp", "avif"]
        guard let target = Core.file(relative, in: root), allowed.contains(target.pathExtension.lowercased()) else {
            throw URLError(.noPermissionsToReadFile)
        }
        let attributes = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true else { throw URLError(.noPermissionsToReadFile) }
        guard let size = attributes.fileSize, size <= Self.maxBytes, bytesRead + size <= 2 * Self.maxBytes else {
            throw CoreError(message: "This model exceeds the 128 MiB file or 256 MiB resource preview limit.")
        }
        let handle = try FileHandle(forReadingFrom: target)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
        guard data.count <= Self.maxBytes, bytesRead + data.count <= 2 * Self.maxBytes else {
            throw CoreError(message: "This model is too large to preview.")
        }
        bytesRead += data.count
        return (data, UTType(filenameExtension: target.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        do {
            guard let url = task.request.url else { throw URLError(.badURL) }
            let (data, mime) = try resource(url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": mime.hasPrefix("text/") ? "\(mime); charset=utf-8" : mime,
                "Content-Length": String(data.count),
            ])!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
            if task.request.url?.path.hasPrefix("/files/") == true { fail(error.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        var url = URLComponents()
        url.scheme = "folio-model"
        url.host = "preview"
        url.path = "/files/\(file.lastPathComponent)"
        webView.callAsyncJavaScript("await window.folioLoadModel(url, name, scheme, colors, snapshot)", arguments: [
            "url": url.url!.absoluteString, "name": file.lastPathComponent,
            "scheme": scheme, "colors": colors, "snapshot": snapshot,
        ], in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { self?.fail(error.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        return url?.scheme == "folio-model" && url?.host == "preview" && url?.path == "/model-viewer.html"
            && action.navigationType == .other ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        fail(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail("The 3D renderer stopped. Reload the file to try again.")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let state = body["state"] as? String else { return }
        if state == "error" { fail(body["message"] as? String ?? "This model could not be opened.") }
        else if state == "ready", failure == nil {
            self.state = "ready"
            if let view = message.webView { applyAppearance(in: view) }
            changed("ready", nil)
        }
    }

    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message
        state = "error"
        changed("error", message)
    }

    func dispose(_ view: WKWebView) {
        view.evaluateJavaScript("window.folioModelDispose?.()")
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "folioModel")
        view.navigationDelegate = nil
    }
}
