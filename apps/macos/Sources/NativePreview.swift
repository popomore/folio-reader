import AppKit
import AVKit
import PDFKit
import SwiftUI

struct NativePreview: View {
    let file: URL
    let kind: FileKind
    let bytes: Int64
    let playbackChanged: (Bool) -> Void

    @ViewBuilder
    var body: some View {
        switch kind {
        case .pdf:
            if let document = PDFDocument(url: file) {
                PDFReader(document: document)
            } else {
                unavailable("This PDF could not be opened.")
            }
        case .rtf:
            if bytes <= 8 * 1024 * 1024,
               let text = try? NSAttributedString(url: file, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                RichText(text: text)
            } else {
                unavailable("This RTF is too large or could not be read.")
            }
        case .image:
            if let image = NSImage(contentsOf: file), image.isValid {
                Image(nsImage: image).resizable().scaledToFit().padding(20)
                    .accessibilityLabel(file.lastPathComponent)
            } else {
                unavailable("This image could not be decoded.")
            }
        case .audio, .video:
            MediaReader(file: file, audio: kind == .audio, playbackChanged: playbackChanged)
        case .model:
            ModelReader(file: file).id(file)
        default:
            unavailable("Folio has no preview for this file type.")
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Preview unavailable", systemImage: "doc")
        } description: { Text(message) } actions: {
            Button("Open in Default App") { NSWorkspace.shared.open(file) }
        }
    }
}

struct PDFReader: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

struct RichText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let editor = scroll.documentView as? NSTextView {
            editor.isEditable = false
            editor.textContainerInset = NSSize(width: 28, height: 28)
            editor.textStorage?.setAttributedString(text)
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    let name: String
    let theme: FolioTheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = SourceTextView(frame: scroll.contentView.bounds)
        scroll.documentView = editor
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 24
        editor.defaultParagraphStyle = paragraph
        editor.font = SourceEditorStyle.font(size: 15)
        editor.textContainerInset = NSSize(width: 8, height: 12)
        editor.applyStyle(theme)
        editor.string = text
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.setAccessibilityLabel("Document Source")
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = SourceLineRuler(scrollView: scroll, editor: editor)
        scroll.rulersVisible = true
        context.coordinator.highlight(editor, immediately: true)
        DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let styleChanged = coordinator.owner.theme != theme
        let refreshColors = styleChanged || coordinator.owner.name != name
        coordinator.owner = self
        guard let editor = view.documentView as? SourceTextView else { return }
        if styleChanged { editor.applyStyle(theme) }
        if editor.string != text {
            editor.string = text
            (view.verticalRulerView as? SourceLineRuler)?.refreshLineStarts()
            coordinator.highlight(editor, immediately: true)
        } else if refreshColors {
            coordinator.highlight(editor, immediately: true)
        }
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: SourceEditor
        var highlightTask: Task<Void, Never>?
        init(_ owner: SourceEditor) { self.owner = owner }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? SourceTextView else { return }
            owner.text = editor.string
            (editor.enclosingScrollView?.verticalRulerView as? SourceLineRuler)?.refreshLineStarts()
            highlight(editor)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? SourceTextView)?.refreshActiveLine()
        }

        func highlight(_ editor: SourceTextView, immediately: Bool = false) {
            highlightTask?.cancel()
            let source = editor.string
            let name = owner.name
            // Match the core's input limit before serializing a draft across the bridge.
            guard !source.isEmpty, source.utf8.count <= 128 * 1024 else {
                apply([], to: editor)
                return
            }
            highlightTask = Task { [weak self, weak editor] in
                if !immediately {
                    do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                }
                let spans = await Task.detached(priority: .userInitiated) {
                    (try? Core.sourceHighlights(for: name, source: source)) ?? []
                }.value
                guard !Task.isCancelled, let self, let editor, editor.string == source, !editor.hasMarkedText() else { return }
                apply(spans, to: editor)
            }
        }

        private func apply(_ spans: [SourceHighlight], to editor: SourceTextView) {
            guard let layout = editor.layoutManager, let length = editor.textStorage?.length, length > 0 else { return }
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
            for span in spans where span.start >= 0 && span.end > span.start && span.end <= length {
                layout.addTemporaryAttribute(.foregroundColor, value: editor.style.color(for: span.token),
                                             forCharacterRange: NSRange(location: span.start, length: span.end - span.start))
            }
        }
    }
}

struct MediaReader: View {
    let file: URL
    let audio: Bool
    let playbackChanged: (Bool) -> Void
    @State private var player = AVPlayer()
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            if let error {
                ContentUnavailableView("Can’t play this file", systemImage: "exclamationmark.circle",
                                       description: Text(error))
            } else if audio {
                Spacer()
                Image(systemName: "waveform").font(.system(size: 38)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(file.lastPathComponent).font(.title3)
                PlayerControls(player: player).frame(maxWidth: 560, maxHeight: 54)
                Spacer()
            } else {
                PlayerControls(player: player)
            }
        }
        .padding(18)
        .task {
            do {
                let asset = AVURLAsset(url: file)
                guard try await asset.load(.isPlayable) else {
                    error = "The installed macOS media decoders couldn’t play this format."
                    return
                }
                if !Task.isCancelled { player.replaceCurrentItem(with: AVPlayerItem(asset: asset)) }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .onReceive(player.publisher(for: \.timeControlStatus)) { state in
            playbackChanged(state != .paused)
        }
        .onDisappear {
            playbackChanged(false)
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }
}

struct PlayerControls: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}
