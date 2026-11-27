import SwiftUI
import PDFKit
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

    func testCloudReadingPositionSurvivesReflowAndUsesAHeadingForChangedContent() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: CloudReadingScript.tracking,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: configuration)
        controller.view.addSubview(web)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let paragraphs = (0..<80).map { "<h2 id='part-\($0)'>Part \($0)</h2><p>\(String(repeating: "Reading at another width preserves a meaningful place. ", count: 8))</p>" }.joined()
        web.loadHTMLString("<style>article{font:18px/1.6 system-ui;padding:16px}</style><article>\(paragraphs)</article>", baseURL: nil)
        let ready = try await waitForScript("typeof window.folioReadingLocation === 'function'", in: web)
        XCTAssertTrue(ready)
        guard ready else { return }
        _ = try await web.evaluateJavaScript("document.querySelector('article').style.marginTop='80px'; window.scrollTo(0,0)")
        let topRaw = try await web.evaluateJavaScript("window.folioReadingLocation()")
        let top = try XCTUnwrap(CloudReadingScript.position(topRaw as Any, revision: "original-revision"))
        _ = try await web.evaluateJavaScript("window.scrollTo(0,800)")
        _ = try await web.callAsyncJavaScript("window.folioResumeReading(position, sameRevision)",
            arguments: CloudReadingScript.arguments(top, revision: "original-revision"), in: nil, contentWorld: .page)
        let stayedAtTop = try await waitForScript("window.scrollY === 0", in: web)
        XCTAssertTrue(stayedAtTop, "A saved top position must not jump to the first block's margin.")
        _ = try await web.evaluateJavaScript("document.querySelector('article').style.marginTop='0px'")
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 2400)")
        let raw = try await web.evaluateJavaScript("window.folioReadingLocation()")
        let body = try XCTUnwrap(raw)
        let saved = try XCTUnwrap(CloudReadingScript.position(body, revision: "original-revision"))
        XCTAssertGreaterThan(saved.progress, 0)
        let block = try XCTUnwrap(saved.block)
        web.frame.size.width = 820
        _ = try await web.evaluateJavaScript("document.querySelector('article').style.fontSize='24px'; window.scrollTo(0,0)")
        _ = try await web.callAsyncJavaScript("window.folioResumeReading(position, sameRevision)",
            arguments: CloudReadingScript.arguments(saved, revision: "original-revision"), in: nil, contentWorld: .page)
        let restored = try await waitForScript("window.folioReadingLocation().block === \(block)", in: web)
        XCTAssertTrue(restored)
        let changed = CloudPosition(heading: "part-40", block: 0, progress: 0, revision: "old-revision")
        _ = try await web.callAsyncJavaScript("window.folioResumeReading(position, sameRevision)",
            arguments: CloudReadingScript.arguments(changed, revision: "new-revision"), in: nil, contentWorld: .page)
        let heading = try await waitForScript("Math.abs(document.getElementById('part-40').getBoundingClientRect().top) < 5", in: web)
        XCTAssertTrue(heading)
    }

    func testNativePDFRestoresAndReportsThePage() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("FolioPages-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: file) { context in
            for page in 0..<3 {
                context.beginPage()
                ("Page \(page + 1)" as NSString).draw(at: CGPoint(x: 30, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let probe = CloudPageProbe()
        let controller = UIHostingController(rootView: NativeReader(file: file, kind: .pdf,
            initialPosition: CloudPosition(page: 1), positionChanged: { probe.page = $0.page }))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        @MainActor func find(_ view: UIView) -> PDFView? {
            if let pdf = view as? PDFView { return pdf }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        var pdf: PDFView?
        for _ in 0..<100 {
            pdf = find(controller.view)
            if let pdf, let document = pdf.document, let page = pdf.currentPage, document.index(for: page) == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let view = try XCTUnwrap(pdf)
        let document = try XCTUnwrap(view.document)
        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 1)
        view.go(to: try XCTUnwrap(document.page(at: 2)))
        for _ in 0..<100 {
            if probe.page == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(probe.page, 2)
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

@MainActor
private final class CloudPageProbe {
    var page: Int?
}
