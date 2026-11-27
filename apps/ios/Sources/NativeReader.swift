import AVKit
import ImageIO
import PDFKit
import QuickLook
import SwiftUI

struct NativeReader: View {
    let file: URL
    let kind: FileKind

    var body: some View {
        switch kind {
        case .pdf: PDFReader(file: file)
        case .image: ImageReader(file: file)
        case .audio, .video: MediaReader(file: file)
        case .rtf: RichTextReader(file: file)
        default: ContentUnavailableView("Preview Unavailable", systemImage: "doc")
        }
    }
}

private struct PDFReader: View {
    let file: URL
    @State private var document: PDFDocument?
    @State private var loading = true
    var body: some View {
        Group {
            if let document { PDFCanvas(document: document) }
            else if loading { ProgressView("Opening PDF…") }
            else {
                ContentUnavailableView("PDF Unavailable", systemImage: "doc.richtext",
                                       description: Text("This file could not be decoded as a PDF."))
            }
        }
        .task { document = PDFDocument(url: file); loading = false }
    }
}

private struct PDFCanvas: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .secondarySystemBackground
        view.document = document
        view.accessibilityIdentifier = "pdf-preview"
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}

private struct ImageReader: View {
    let file: URL
    @State private var image: UIImage?
    @State private var loading = true
    @State private var zoom = 1.0
    @GestureState private var magnification = 1.0

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: geometry.size.width * zoom * magnification,
                               height: geometry.size.height * zoom * magnification)
                        .accessibilityLabel(file.lastPathComponent)
                        .gesture(MagnifyGesture().updating($magnification) { value, state, _ in
                            state = value.magnification
                        }.onEnded { value in zoom = min(4, max(1, zoom * value.magnification)) })
                        .onTapGesture(count: 2) { zoom = zoom > 1 ? 1 : 2 }
                        .accessibilityAction(named: "Zoom In") { zoom = min(4, zoom + 1) }
                        .accessibilityAction(named: "Reset Zoom") { zoom = 1 }
                }
            }
            .overlay {
                if loading { ProgressView("Opening Image…") }
                else if image == nil { ContentUnavailableView("Image Unavailable", systemImage: "photo") }
            }
        }
        .task {
            let file = file
            let data = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096
                      ] as CFDictionary) else { return nil as Data? }
                let result = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, cg, nil)
                guard CGImageDestinationFinalize(destination) else { return nil }
                return result as Data
            }.value
            image = data.flatMap(UIImage.init(data:))
            loading = false
        }
    }
}

private struct MediaReader: View {
    let file: URL
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player)
            .accessibilityLabel("Media Player")
            .onAppear { player = AVPlayer(url: file) }
            .onDisappear { player?.pause(); player = nil }
    }
}

private struct RichTextReader: UIViewControllerRepresentable {
    let file: URL
    func makeCoordinator() -> Coordinator { Coordinator(file: file) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let file: URL
        init(file: URL) { self.file = file }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { file as NSURL }
    }
}
