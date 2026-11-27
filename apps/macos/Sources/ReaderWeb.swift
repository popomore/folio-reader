import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ReaderWeb: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var tab: ReaderTab
    let follow: (URL) -> Void
    let root: URL
    let path: String
    let html: String
    let appearance: Appearance
    let theme: FolioTheme

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, root: root, follow: follow)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "folio")
        config.userContentController.add(context.coordinator, name: "folioScroll")
        config.userContentController.add(context.coordinator, name: "folioReading")
        config.userContentController.addUserScript(WKUserScript(source: CloudReadingScript.tracking,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.view = view
        tab.web = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(root: root, path: path, html: html, appearance: appearance,
                                   colorScheme: colorScheme, theme: theme)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "folioScroll")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "folioReading")
        if coordinator.tab?.web === coordinator {
            coordinator.tab?.web = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler {
        weak var tab: ReaderTab?
        let follow: (URL) -> Void
        weak var view: WKWebView?
        private var root: URL
        private var path = ""
        private var html: String?
        private var appearance: Appearance?
        private var theme = FolioTheme.system
        private var colorScheme: ColorScheme = .light
        private var webColorScheme: String { colorScheme == .dark ? "dark" : "light" }
        private var pending = true
        private var headingID: String?
        private var navigation: WKNavigation?

        init(tab: ReaderTab, root: URL, follow: @escaping (URL) -> Void) {
            self.tab = tab
            self.root = root
            self.follow = follow
        }

        func update(root: URL, path: String, html: String, appearance: Appearance, colorScheme: ColorScheme, theme: FolioTheme) {
            let change = self.appearance != appearance || self.colorScheme != colorScheme || self.theme != theme
            self.appearance = appearance
            self.colorScheme = colorScheme
            self.theme = theme
            if self.root != root || self.path != path || self.html != html {
                self.root = root
                self.path = path
                self.html = html
                pending = true
                headingID = tab?.pendingFragment
                tab?.pendingFragment = nil
                navigation = view?.load(URLRequest(url: URL(string: "folio://reader/index.html")!))
            } else if change && !pending {
                applyAppearance()
            }
        }

        func heading(_ id: String) {
            if pending {
                headingID = id
            } else {
                view?.callAsyncJavaScript("window.folioHeading(id)", arguments: ["id": id], in: nil, in: .page)
            }
        }

        func find(_ query: String, backwards: Bool = false) {
            guard let view, !query.isEmpty else { return }
            let config = WKFindConfiguration()
            config.backwards = backwards
            config.wraps = true
            view.find(query, configuration: config) { result in
                if !result.matchFound { NSSound.beep() }
            }
        }

        private func applyAppearance() {
            guard let appearance else { return }
            view?.callAsyncJavaScript("window.folioAppearance(scheme, size, width, serif, colors)", arguments: [
                "scheme": webColorScheme, "size": appearance.size, "width": appearance.width,
                "serif": appearance.serif,
                "colors": theme.readerVariables,
            ], in: nil, in: .page)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation == self.navigation else { return }
            pending = false
            applyAppearance()
            if let headingID {
                self.headingID = nil
                heading(headingID)
            } else if let y = tab?.scrollOffset, y > 0 {
                webView.callAsyncJavaScript("window.scrollTo(0, y)", arguments: ["y": y], in: nil, in: .page)
            } else if let position = tab?.resumePosition {
                tab?.resumePosition = nil
                webView.callAsyncJavaScript("window.folioResumeReading(position, sameRevision)",
                    arguments: CloudReadingScript.arguments(position, revision: tab?.document?.revision), in: nil, in: .page)
            }
            webView.callAsyncJavaScript("window.webkit.messageHandlers.folioReading.postMessage(window.folioReadingLocation())",
                arguments: [:], in: nil, in: .page)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if !pending, message.frameInfo.isMainFrame, message.name == "folioReading",
               let position = CloudReadingScript.position(message.body, revision: tab?.document?.revision) {
                tab?.updateReadingPosition(position)
                return
            }
            if !pending, message.frameInfo.isMainFrame, let offset = message.body as? Double, offset.isFinite {
                tab?.scrollOffset = max(0, offset)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if navigation == self.navigation && (error as NSError).code != NSURLErrorCancelled {
                tab?.loadError = error.localizedDescription
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == "folio", url.host == "reader", url.path == "/index.html",
               action.navigationType == .other {
                return .allow
            }
            if action.navigationType == .linkActivated {
                if url.scheme == "folio", url.host == "files" {
                    follow(url)
                } else if ["https", "http", "mailto"].contains(url.scheme ?? "") {
                    NSWorkspace.shared.open(url)
                }
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else {
                task.didFailWithError(URLError(.badURL))
                return
            }
            do {
                let (data, mime) = try resource(url)
                let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                           textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil)
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            } catch {
                task.didFailWithError(error)
            }
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        private func resource(_ url: URL) throws -> (Data, String) {
            switch (url.host, url.path) {
            case ("reader", "/index.html"):
                return (Data(page.utf8), "text/html")
            case ("reader", "/reader.css"), ("reader", "/reader.js"), ("reader", "/page.js"):
                guard let resource = Bundle.main.url(forResource: url.deletingPathExtension().lastPathComponent,
                                                     withExtension: url.pathExtension)
                else { throw URLError(.fileDoesNotExist) }
                return (try Data(contentsOf: resource), url.pathExtension == "css" ? "text/css" : "text/javascript")
            case ("files", _):
                let relative = String(url.path.dropFirst())
                let extensions = ["png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "svg"]
                guard let resource = Core.file(relative, in: root),
                      extensions.contains(resource.pathExtension.lowercased()),
                      let type = UTType(filenameExtension: resource.pathExtension)?.preferredMIMEType
                else { throw URLError(.noPermissionsToReadFile) }
                let attrs = try resource.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard attrs.isRegularFile == true, let size = attrs.fileSize, size <= 24 * 1024 * 1024 else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                return (try Data(contentsOf: resource), type)
            default:
                throw URLError(.unsupportedURL)
            }
        }

        private var page: String {
            var base = URLComponents()
            base.scheme = "folio"
            base.host = "files"
            let folder = path.split(separator: "/").dropLast().joined(separator: "/")
            base.path = folder.isEmpty ? "/" : "/\(folder)/"
            let escapedBase = (base.url?.absoluteString ?? "folio://files/")
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            let a = appearance ?? Appearance()
            let charts = html?.contains("language-mermaid") == true || html?.contains("language-vega-lite") == true
            let scripts = charts
                ? "<script defer src=\"folio://reader/reader.js\"></script>"
                : ""
            return """
            <!doctype html>
            <html data-color-scheme="\(webColorScheme)" data-serif="\(a.serif)" style="--text-size:\(a.size)px;--reading-width:\(a.width)px;\(theme.readerDeclarations)">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src folio://reader; style-src folio://reader 'unsafe-inline'; img-src folio://files; base-uri folio://files">
            <base href="\(escapedBase)">
            <link rel="stylesheet" href="folio://reader/reader.css">
            <script defer src="folio://reader/page.js"></script>
            \(scripts)
            </head>
            <body><article>\(html ?? "")</article></body>
            </html>
            """
        }
    }
}
