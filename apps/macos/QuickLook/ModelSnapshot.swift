import Foundation
import WebKit

enum ModelSnapshot {
    @MainActor
    static func render(_ file: URL, resources: Bundle) async throws -> Data {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let session = ModelPreviewSession(file: file, resources: resources, snapshot: true)
        let view = session.makeView(size: PreviewProvider.previewSize)
        defer { session.dispose(view) }
        let deadline = ContinuousClock.now + .seconds(20)
        while session.state == "loading", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard session.state == "ready" else {
            throw CoreError(message: session.failure ?? "The 3D preview took too long. Open the model in Folio.")
        }
        let result = try await view.callAsyncJavaScript("return window.folioModelSnapshot()", contentWorld: .page)
        guard let encoded = result as? String, let png = Data(base64Encoded: encoded) else {
            throw CoreError(message: "The 3D preview could not be captured.")
        }
        return png
    }
}
