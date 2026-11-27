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
                               size: 18, serif: false, heading: nil, error: .constant(nil), follow: { _, _ in })
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
        let complete = try await waitForScript(condition, in: web)
        let diagnostics = (try? await web.evaluateJavaScript("document.body.innerText")) as? String ?? "No page"
        XCTAssertTrue(complete, diagnostics)
        let safe = try await web.evaluateJavaScript("window.folioAttack !== true && document.querySelectorAll('.diagram-error').length === 0 && document.querySelector('img[alt=blocked]').naturalWidth === 0")
        XCTAssertEqual(safe as? Bool, true)
        let appearance = try await web.evaluateJavaScript("document.documentElement.dataset.colorScheme")
        XCTAssertEqual(appearance as? String, "dark")
    }

    func testCrossDocumentUnicodeFragmentReachesTheHeadingAfterLoading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolioLinks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Start\n\n[Details](destination.md#%E8%AF%A6%E6%83%85)".utf8)
            .write(to: root.appendingPathComponent("start.md"))
        let padding = String(repeating: "A paragraph that makes the target heading require scrolling.\n\n", count: 36)
        try Data(("# Overview\n\n" + padding + "# 详情\n\nTarget section.\n\n" + padding).utf8)
            .write(to: root.appendingPathComponent("destination.md"))
        let folder = try await WorkspaceIO.remember(root)
        let opened = try await WorkspaceIO.open(folder, path: "start.md")
        var followed: (path: String, fragment: String?)?
        let source = ReaderWeb(access: opened.access, path: "start.md", html: try XCTUnwrap(opened.document.preview).html,
                               size: 17, serif: false, heading: nil, error: .constant(nil),
                               follow: { followed = ($0, $1) })
        let controller = UIHostingController(rootView: source)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let web = try await waitForWebView(in: controller.view)
        let sourceReady = try await waitForScript("document.readyState === 'complete' && !!document.querySelector('a')", in: web)
        XCTAssertTrue(sourceReady, "The source page must finish loading before its link is clicked.")
        guard sourceReady else { return }
        _ = try await web.evaluateJavaScript("document.querySelector('a').click()")
        for _ in 0..<50 {
            if followed != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let link = try XCTUnwrap(followed)
        XCTAssertEqual(link.path, "destination.md")
        XCTAssertEqual(link.fragment, "详情")
        let selection = FileSelection(folder: folder, path: link.path, fragment: link.fragment)
        let destination = UIHostingController(rootView: DocumentReader(selection: selection, follow: { _, _ in })
            .environment(LibraryStore(base: root.appendingPathComponent("App")))
            .environment(ReaderPreferences(defaults: UserDefaults(suiteName: "FolioLinks.\(UUID())")!)))
        window.rootViewController = destination
        let destinationWeb = try await waitForWebView(in: destination.view)
        let landed = try await waitForScript("""
            (() => {
              const heading = document.getElementById('详情');
              return !!heading && window.scrollY > 300 && heading.getBoundingClientRect().top >= 0 && heading.getBoundingClientRect().top < 100;
            })()
            """, in: destinationWeb)
        XCTAssertTrue(landed, "The destination reader must scroll to the decoded heading after its page loads.")
    }

    func testPendingHeadingWinsOverScrollRestorationDuringReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolioReload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let padding = String(repeating: "A paragraph that provides enough space to scroll.\n\n", count: 36)
        try Data(("# Top\n\n" + padding + "# Target\n\n" + padding).utf8).write(to: root.appendingPathComponent("note.md"))
        let folder = try await WorkspaceIO.remember(root)
        let opened = try await WorkspaceIO.open(folder, path: "note.md")
        let html = try XCTUnwrap(opened.document.preview).html
        func reader(_ html: String, heading: HeadingTarget? = nil) -> ReaderWeb {
            ReaderWeb(access: opened.access, path: "note.md", html: html, size: 17, serif: false,
                      heading: heading, error: .constant(nil), follow: { _, _ in })
        }
        let controller = UIHostingController(rootView: reader(html))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let web = try await waitForWebView(in: controller.view)
        let ready = try await waitForScript("!!document.getElementById('target') && typeof window.folioHeading === 'function'", in: web)
        XCTAssertTrue(ready)
        guard ready else { return }
        let coordinator = try XCTUnwrap(web.navigationDelegate as? ReaderWeb.Coordinator)
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 600)")
        for _ in 0..<100 {
            if abs(coordinator.scroll - 600) < 5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(coordinator.scroll, 600, accuracy: 5)
        let heading = HeadingTarget(fragment: "target")
        controller.rootView = reader(html + "<p>First reload</p>", heading: heading)
        let landed = try await waitForScript("""
            document.body.innerText.includes('First reload') &&
            Math.abs(document.getElementById('target')?.getBoundingClientRect().top) < 100 &&
            window.scrollY > 600
            """, in: web)
        XCTAssertTrue(landed, "A new heading request must take priority over the saved scroll position.")
        guard landed else { return }
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 600)")
        for _ in 0..<100 {
            if abs(coordinator.scroll - 600) < 5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        controller.rootView = reader(html + "<p>Second reload</p>", heading: heading)
        let restored = try await waitForScript("""
            document.body.innerText.includes('Second reload') && Math.abs(window.scrollY - 600) < 5
            """, in: web)
        XCTAssertTrue(restored, "A reload with no new heading request must retain ordinary scroll restoration.")
    }

    private func waitForScript(_ condition: String, in web: WKWebView) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        repeat {
            if (try? await web.evaluateJavaScript(condition)) as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return false
    }

    private func waitForWebView(in view: UIView) async throws -> WKWebView {
        for _ in 0..<50 {
            if let web = webView(in: view) { return web }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CoreError(message: "The reader did not create its WebKit view.")
    }

    private func webView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
    }
}
