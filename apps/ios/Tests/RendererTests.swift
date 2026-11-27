import SwiftUI
import WebKit
import XCTest
@testable import Folio

@MainActor
final class RendererTests: XCTestCase {
    func testOfflineChartsLocalImagesAndSanitizedHTMLRenderInWebKit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolioRenderer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let samples = try XCTUnwrap(Bundle.main.url(forResource: "Sample Project", withExtension: nil))
        let png = try Data(contentsOf: samples.appendingPathComponent("Images/folio.png"))
        try png.write(to: root.appendingPathComponent("local.png"))
        let source = """
        # Offline fixtures

        ![local](local.png)
        ![blocked](https://example.invalid/tracker.png)

        <script>window.folioAttack = true</script>

        ```mermaid
        flowchart LR
            Read --> Write
        ```

        ```vega-lite
        {"data":{"values":[{"name":"Notes","count":3}]},"mark":"bar","encoding":{"x":{"field":"name","type":"nominal"},"y":{"field":"count","type":"quantitative"}}}
        ```
        """
        try Data(source.utf8).write(to: root.appendingPathComponent("note.md"))
        let folder = try await WorkspaceIO.remember(root)
        let opened = try await WorkspaceIO.open(folder, path: "note.md")
        let preview = try XCTUnwrap(opened.document.preview)
        let reader = ReaderWeb(access: opened.access, path: "note.md", html: preview.html,
                               size: 18, serif: false, heading: nil, error: .constant(nil), follow: { _ in })
        let controller = UIHostingController(rootView: reader.environment(\.colorScheme, .dark))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }

        var view: WKWebView?
        for _ in 0..<50 {
            view = webView(in: controller.view)
            if view != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let web = try XCTUnwrap(view)
        let condition = """
        document.readyState === 'complete' &&
        document.querySelectorAll('.diagram svg').length === 2 &&
        document.querySelector('img[alt="local"]')?.naturalWidth > 0
        """
        var complete = false
        for _ in 0..<150 {
            if (try? await web.evaluateJavaScript(condition)) as? Bool == true { complete = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let diagnostics = (try? await web.evaluateJavaScript("document.body.innerText")) as? String ?? "No page"
        XCTAssertTrue(complete, diagnostics)
        let safe = try await web.evaluateJavaScript("window.folioAttack !== true && document.querySelectorAll('.diagram-error').length === 0 && document.querySelector('img[alt=blocked]').naturalWidth === 0")
        XCTAssertEqual(safe as? Bool, true)
        let appearance = try await web.evaluateJavaScript("document.documentElement.dataset.colorScheme")
        XCTAssertEqual(appearance as? String, "dark")
    }

    private func webView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
    }
}
