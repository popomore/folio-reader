import AppKit
import Foundation
import WebKit

enum ModelSnapshot {
    @MainActor
    static func render(_ file: URL, resources: Bundle) async throws -> Data {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let session = ModelPreviewSession(file: file, resources: resources, snapshot: true, allowsFolderResources: false)
        let view = session.makeView(size: PreviewProvider.previewSize)
        defer { session.dispose(view) }
        let deadline = ContinuousClock.now + .seconds(20)
        while session.state == "loading", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard session.state == "ready" else {
            throw CoreError(message: session.failure ?? "The 3D preview took too long. Open the model in Folio.")
        }
        return try await capture(view, timeout: ContinuousClock.now.duration(to: deadline))
    }

    @MainActor
    static func capture(_ view: WKWebView, timeout: Duration) async throws -> Data {
        guard timeout > .zero else { throw CoreError(message: "The 3D preview took too long to capture.") }
        let request = CaptureRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.start(continuation, timeout: timeout)
                view.callAsyncJavaScript("return window.folioModelSnapshot()", arguments: [:], in: nil, in: .page) { [weak request] result in
                    guard let request, request.pending else { return }
                    do { request.finish(.success(try png(from: result.get()))) }
                    catch { request.finish(.failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor in request.finish(.failure(CancellationError())) }
        }
    }

    @MainActor
    private static func png(from result: Any) throws -> Data {
        guard let frame = result as? [String: Any], let width = frame["width"] as? Int, let height = frame["height"] as? Int,
              (1...4096).contains(width), (1...4096).contains(height), width * height <= 4_194_304,
              let encoded = frame["rgba"] as? String, encoded.utf8.count <= 22_369_624,
              let pixels = Data(base64Encoded: encoded), pixels.count == width * height * 4,
              let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
                                          bytesPerRow: width * 4, bitsPerPixel: 32), let destination = image.bitmapData else {
            throw CoreError(message: "The 3D preview could not be captured.")
        }
        let stride = width * 4
        pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            let bytes = source.bindMemory(to: UInt8.self).baseAddress!
            for row in 0..<height {
                // WebGL rows start at the bottom; PNG rows start at the top.
                destination.advanced(by: row * stride).update(from: bytes.advanced(by: (height - row - 1) * stride), count: stride)
            }
        }
        guard let png = image.representation(using: .png, properties: [:]), !png.isEmpty else {
            throw CoreError(message: "The 3D preview could not be captured.")
        }
        return png
    }

    @MainActor
    private final class CaptureRequest {
        private var continuation: CheckedContinuation<Data, any Error>?
        private var timer: Task<Void, Never>?
        var pending: Bool { continuation != nil }

        func start(_ continuation: CheckedContinuation<Data, any Error>, timeout: Duration) {
            self.continuation = continuation
            timer = Task { @MainActor in
                do { try await Task.sleep(for: timeout) } catch { return }
                finish(.failure(CoreError(message: "The 3D preview took too long to capture.")))
            }
        }

        func finish(_ result: Result<Data, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel()
            timer = nil
            continuation.resume(with: result)
        }
    }
}
