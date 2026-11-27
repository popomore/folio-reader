import SwiftUI
import WebKit

struct HeadingTarget: Equatable {
    let id = UUID()
    let fragment: String
}

struct ReaderWeb: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let access: FolderAccess
    let path: String
    let html: String
    let size: Double
    let serif: Bool
    let heading: HeadingTarget?
    @Binding var error: String?
    let follow: (String, String?) -> Void
    var initialPosition: CloudPosition? = nil
    var revision: String? = nil
    var positionChanged: (CloudPosition) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "folio")
        configuration.userContentController.add(context.coordinator, name: "folioScroll")
        configuration.userContentController.add(context.coordinator, name: "folioReading")
        configuration.userContentController.addUserScript(WKUserScript(source: CloudReadingScript.tracking,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.scrollView.backgroundColor = .systemBackground
        view.allowsLinkPreview = false
        view.accessibilityIdentifier = "document-preview"
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(self, in: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "folioScroll")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "folioReading")
        view.stopLoading()
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler {
        var owner: ReaderWeb
        private var html: String?
        private var style = ""
        private var heading: HeadingTarget?
        private var ready = false
        private(set) var scroll: Double = 0
        private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

        init(owner: ReaderWeb) { self.owner = owner }

        func update(_ owner: ReaderWeb, in view: WKWebView) {
            self.owner = owner
            if html != owner.html {
                html = owner.html
                ready = false
                view.load(URLRequest(url: URL(string: "folio://reader/index.html")!))
            } else if ready {
                appearance(in: view)
                navigateHeading(in: view)
            }
        }

        private var scheme: String { owner.colorScheme == .dark ? "dark" : "light" }

        private var theme: FolioTheme {
            let mode: ThemeMode = scheme == "dark" ? .dark : .light
            guard let url = try? FolioTheme.bundledURL(for: mode, in: .main), let theme = try? FolioTheme.read(url) else {
                return .system
            }
            return theme
        }

        private func appearance(in view: WKWebView) {
            let next = "\(scheme)/\(owner.size)/\(owner.serif)"
            guard style != next else { return }
            style = next
            view.callAsyncJavaScript("window.folioAppearance(scheme, size, 700, serif, colors)", arguments: [
                "scheme": scheme, "size": owner.size, "serif": owner.serif, "colors": theme.readerVariables
            ], in: nil, in: .page)
        }

        private func navigateHeading(in view: WKWebView) {
            guard let target = owner.heading, target != heading else { return }
            heading = target
            view.callAsyncJavaScript("window.folioHeading(id)", arguments: ["id": target.fragment], in: nil, in: .page)
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            style = ""
            appearance(in: view)
            let headingPending = owner.heading != nil && owner.heading != heading
            navigateHeading(in: view)
            if !headingPending, scroll > 0 {
                view.callAsyncJavaScript("window.scrollTo(0, y)", arguments: ["y": scroll], in: nil, in: .page)
            } else if !headingPending, let position = owner.initialPosition {
                view.callAsyncJavaScript("window.folioResumeReading(position, sameRevision)",
                    arguments: CloudReadingScript.arguments(position, revision: owner.revision), in: nil, in: .page)
            }
            view.callAsyncJavaScript("window.webkit.messageHandlers.folioReading.postMessage(window.folioReadingLocation())",
                arguments: [:], in: nil, in: .page)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if ready, message.frameInfo.isMainFrame, message.name == "folioReading",
               let position = CloudReadingScript.position(message.body, revision: owner.revision) {
                owner.positionChanged(position)
                return
            }
            if ready, message.frameInfo.isMainFrame, let y = message.body as? Double, y.isFinite {
                scroll = max(0, y)
            }
        }

        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { owner.error = error.localizedDescription }
        }

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if action.navigationType == .other, url.scheme == "folio", url.host == "reader", url.path == "/index.html" {
                return .allow
            }
            if action.navigationType == .linkActivated {
                if url.scheme == "folio", url.host == "files" {
                    let relative = String(url.path.dropFirst())
                    if (try? WorkspaceIO.file(relative, in: owner.access)) != nil {
                        owner.follow(relative, URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment)
                    }
                } else if ["http", "https", "mailto"].contains(url.scheme ?? "") {
                    await UIApplication.shared.open(url)
                }
            }
            return .cancel
        }

        func webView(_ view: WKWebView, start task: any WKURLSchemeTask) {
            let id = ObjectIdentifier(task)
            tasks[id] = Task {
                defer { tasks[id] = nil }
                do {
                    guard let url = task.request.url else { throw URLError(.badURL) }
                    let (data, mime) = try await resource(url)
                    guard !Task.isCancelled else { return }
                    task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                                textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
                    task.didReceive(data)
                    task.didFinish()
                } catch {
                    if !Task.isCancelled { task.didFailWithError(error) }
                }
            }
        }

        func webView(_ view: WKWebView, stop task: any WKURLSchemeTask) {
            tasks.removeValue(forKey: ObjectIdentifier(task))?.cancel()
        }

        func cancel() {
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
        }

        private func resource(_ url: URL) async throws -> (Data, String) {
            if url.host == "reader", url.path == "/index.html" { return (Data(page.utf8), "text/html") }
            if url.host == "reader", ["/reader.css", "/reader.js", "/page.js"].contains(url.path) {
                guard let file = Bundle.main.url(forResource: url.deletingPathExtension().lastPathComponent,
                                                 withExtension: url.pathExtension) else { throw URLError(.fileDoesNotExist) }
                let data = try await Task.detached { try Data(contentsOf: file) }.value
                return (data, url.pathExtension == "css" ? "text/css" : "text/javascript")
            }
            if url.host == "files" {
                let access = owner.access
                return try await Task.detached { try WorkspaceIO.image(String(url.path.dropFirst()), access: access) }.value
            }
            throw URLError(.unsupportedURL)
        }

        private var page: String {
            var base = URLComponents()
            base.scheme = "folio"
            base.host = "files"
            let folder = owner.path.split(separator: "/").dropLast().joined(separator: "/")
            base.path = folder.isEmpty ? "/" : "/\(folder)/"
            let escapedBase = (base.url?.absoluteString ?? "folio://files/")
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            let charts = owner.html.contains("language-mermaid") || owner.html.contains("language-vega-lite")
            return """
            <!doctype html>
            <html data-color-scheme="\(scheme)" data-serif="\(owner.serif)" style="--text-size:\(owner.size)px;--reading-width:700px;\(theme.readerDeclarations)">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src folio://reader; style-src folio://reader 'unsafe-inline'; img-src folio://files; base-uri folio://files">
            <base href="\(escapedBase)">
            <link rel="stylesheet" href="folio://reader/reader.css">
            <script defer src="folio://reader/page.js"></script>
            \(charts ? "<script defer src=\"folio://reader/reader.js\"></script>" : "")
            <title>\(owner.path.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</title>
            </head>
            <body><article>\(owner.html)</article></body>
            </html>
            """
        }
    }
}
