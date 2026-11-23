import Foundation
import QuickLookUI
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    static let previewSize = CGSize(width: 800, height: 680)

    enum Content {
        case native(URL)
        case model(URL)
        case html(Data, hasCharts: Bool)
    }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let resources = Bundle(for: PreviewProvider.self)
        switch try Self.content(at: request.fileURL, resources: resources) {
        case .native(let file):
            return QLPreviewReply(fileURL: file)
        case .model(let file):
            let png = try await ModelSnapshot.render(file, resources: resources)
            return QLPreviewReply(dataOfContentType: .png, contentSize: Self.previewSize) { _ in png }
        case .html(let page, let hasCharts):
            if hasCharts, let pdf = try? await ChartPreview.render(page, resources: resources) {
                return QLPreviewReply(dataOfContentType: .pdf, contentSize: Self.previewSize) { _ in pdf }
            }
            return QLPreviewReply(dataOfContentType: .html, contentSize: Self.previewSize) { _ in page }
        }
    }

    static func content(at file: URL, resources: Bundle) throws -> Content {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }

        let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard metadata.isRegularFile == true else {
            throw CoreError(message: "Choose a file to preview.")
        }
        switch try Core.kind(of: file.lastPathComponent) {
        case .pdf, .rtf, .image, .audio, .video:
            return .native(file)
        case .model:
            return .model(file)
        case .markdown, .text, .html, .table, .mermaid, .vega:
            return try textContent(at: file, resources: resources)
        case .other:
            let nativeTypes: [UTType] = [.plainText, .xml, .rtf, .pdf, .image, .audio, .movie]
            if let type = metadata.contentType, nativeTypes.contains(where: { type.conforms(to: $0) }) {
                return .native(file)
            }
            throw CoreError(message: "Folio has no preview for this file type.")
        }
    }

    private static func textContent(at file: URL, resources: Bundle) throws -> Content {
        let maxBytes = 2 * 1024 * 1024
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // Finder can classify .ts as a transport stream or TypeScript.
        if file.pathExtension.lowercased() == "ts" {
            let header = [UInt8](try handle.read(upToCount: 377) ?? Data())
            if header.count == 377 && [0, 188, 376].allSatisfy({ header[$0] == 0x47 }) {
                return .native(file)
            }
            try handle.seek(toOffset: 0)
        }
        let bytes = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard bytes.count <= maxBytes else {
            throw CoreError(message: "This file is too large for Quick Look. Open it in Folio.")
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CoreError(message: "Quick Look previews UTF-8 text files.")
        }
        guard let preview = try Core.textPreview(for: file.lastPathComponent, source: text) else {
            throw CoreError(message: "Folio has no text preview for this file type.")
        }
        guard let styleURL = resources.url(forResource: "reader", withExtension: "css") else {
            throw CoreError(message: "The preview stylesheet is missing.")
        }
        let style = try String(contentsOf: styleURL, encoding: .utf8)
        let light = try FolioTheme.read(FolioTheme.bundledURL(for: .light, in: resources))
        let dark = try FolioTheme.read(FolioTheme.bundledURL(for: .dark, in: resources))
        let page = Data("""
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
            <style>
            \(style)
            :root { \(light.readerDeclarations) }
            @media (prefers-color-scheme: dark) { :root { \(dark.readerDeclarations) } }
            article { padding-block-end: 46px; }
            </style>
            </head>
            <body><article>\(preview.html)</article></body>
            </html>
            """.utf8)
        let hasCharts = preview.html.contains("<code class=\"language-mermaid\">")
            || preview.html.contains("<code class=\"language-vega-lite\">")
        return .html(page, hasCharts: hasCharts)
    }
}
