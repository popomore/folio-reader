import AppKit
import SwiftUI
import WebKit

struct ModelReader: View {
    let file: URL
    @Environment(\.colorScheme) private var colorScheme
    @State private var state = "loading"
    @State private var failure: String?

    var body: some View {
        ZStack {
            ModelWeb(file: file, scheme: colorScheme == .dark ? "dark" : "light",
                     theme: ThemeStore.shared[colorScheme == .dark ? .dark : .light]) { state, failure in
                self.state = state
                self.failure = failure
            }
            .opacity(failure == nil ? 1 : 0)
            if state == "loading" { ProgressView("Opening 3D model…").controlSize(.small) }
            if let failure {
                ContentUnavailableView {
                    Label("Preview unavailable", systemImage: "cube")
                } description: { Text(failure) } actions: {
                    Button("Open in Default App") { NSWorkspace.shared.open(file) }
                }
            }
        }
    }
}

private struct ModelWeb: NSViewRepresentable {
    let file: URL
    let scheme: String
    let theme: FolioTheme
    let changed: (String, String?) -> Void

    func makeCoordinator() -> ModelPreviewSession { ModelPreviewSession(file: file, changed: changed) }

    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.appearance(scheme, colors: theme.readerVariables, in: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: ModelPreviewSession) { coordinator.dispose(view) }
}
