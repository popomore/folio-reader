import AppKit
import SwiftUI

struct ReaderWindow: View {
    @ObservedObject var model: ReaderModel
    @State private var foldersWidth = WorkspaceColumns.defaultFolders
    @State private var outlineWidth = WorkspaceColumns.defaultOutline
    @GestureState private var foldersOffset: CGFloat = 0
    @GestureState private var outlineOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let contentHeight = max(0, geometry.size.height - StatusBar.height - 1)
            let folders = model.sidebar ? foldersWidth + foldersOffset : nil
            let outline = model.inspector && !model.showingGit ? outlineWidth + outlineOffset : nil
            let target = ReaderSplitStyle.workspace.sideBySideWidth
            let columns = WorkspaceColumns(width: geometry.size.width, folders: folders, outline: outline,
                                           contentTarget: model.showingGit ? 480 : (model.split ? target : 350))
            let splitColumns = model.split ? columns : WorkspaceColumns(width: geometry.size.width,
                folders: folders, outline: outline, contentTarget: target)
            let splitDirection = ReaderSplitStyle.workspace.direction(
                for: CGSize(width: splitColumns.content, height: contentHeight)
            )
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if folders != nil {
                        FolderSidebar(model: model, width: columns.folders)
                            .frame(width: columns.folders, height: contentHeight)
                            .clipped()
                        PaneDivider(label: "Resize Folder Tree", value: "\(Int(columns.folders.rounded())) points",
                                    offset: $foldersOffset) { movement in
                            foldersWidth = WorkspaceColumns.clamp(foldersWidth + movement, to: WorkspaceColumns.folderWidths)
                        } reset: { foldersWidth = WorkspaceColumns.defaultFolders }
                    }
                    Group {
                        if model.showingGit, let location = model.gitLocation {
                            GitView(location: location, refreshID: model.gitRefresh)
                                .id(location)
                        } else {
                            ReaderSplit(isSplit: model.split) {
                                ReaderPane(model: model, pane: .left, splitDirection: splitDirection)
                            } right: {
                                ReaderPane(model: model, pane: .right, splitDirection: splitDirection)
                            }
                        }
                    }
                    .frame(width: columns.content, height: contentHeight)
                    .clipped()
                    if outline != nil {
                        PaneDivider(growsForward: false, label: "Resize Outline", value: "\(Int(columns.outline.rounded())) points",
                                    offset: $outlineOffset) { movement in
                            outlineWidth = WorkspaceColumns.clamp(outlineWidth + movement, to: WorkspaceColumns.outlineWidths)
                        } reset: { outlineWidth = WorkspaceColumns.defaultOutline }
                        Inspector(tab: model.active, width: columns.outline)
                            .frame(width: columns.outline, height: contentHeight)
                            .clipped()
                    }
                }
                .frame(height: contentHeight)
                WorkspaceRule()
                StatusBar(model: model, splitDirection: splitDirection)
            }
        }
        .background(WorkspaceStyle.surface)
        .toolbarBackground(WorkspaceStyle.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .navigationTitle(model.showingGit ? "Git" : model.active?.title ?? "Folio")
        .navigationSubtitle(model.showingGit ? model.gitLocation?.displayPath ?? "" : "")
        .alert("Folio", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private extension Pane {
    func label(in direction: ReaderSplitStyle.Direction) -> String {
        guard direction == .vertical else { return label }
        return self == .left ? "Top" : "Bottom"
    }
}

struct ReaderPane: View {
    @ObservedObject var model: ReaderModel
    let pane: Pane
    let splitDirection: ReaderSplitStyle.Direction
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var insertionX: CGFloat?
    @State private var targetingEmptyPane = false
    @State private var readerSize: CGSize = .zero
    @State private var targetingSplit = false

    var body: some View {
        let group = model.groups[pane] ?? ReaderModel.Group()
        let stack = splitDirection == .vertical
        let splitEdge: Alignment = stack ? .bottom : .trailing
        VStack(spacing: 0) {
            tabBar(group)
            if let tab = group.active {
                ReaderBreadcrumbs(tab: tab, model: model, focusPane: { model.focus(pane) }) { location in
                    model.focus(pane)
                    model.open(location)
                }
                .id(tab.id)
                WorkspaceRule()
                TabDocument(tab: tab, appearance: model.appearance, setMediaActivity: model.setMediaActivity, follow: { model.follow($0, from: tab) })
                    .id(tab.id)
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { readerSize = $0 }
                    .overlay(alignment: splitEdge) {
                        if !model.split {
                            Color.clear
                                .frame(width: stack ? nil : readerSize.width / 4,
                                       height: stack ? readerSize.height / 4 : nil)
                                .onDrop(of: [TabDrag.type], delegate: SplitOnTabDrop(model: model, targetingSplit: $targetingSplit))
                        }
                    }
                    .overlay(alignment: splitEdge) {
                        if targetingSplit && !model.split {
                            Rectangle().fill(WorkspaceStyle.focus.opacity(0.12))
                                .overlay { Rectangle().strokeBorder(WorkspaceStyle.focus, lineWidth: 1) }
                                .frame(width: stack ? nil : readerSize.width / 2,
                                       height: stack ? readerSize.height / 2 : nil)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            } else {
                ContentUnavailableView {
                    Label(model.split ? "Open a file in this pane" : "Open a file", systemImage: "doc.text")
                } description: {
                    Text(model.sidebar ? "Choose a file in the sidebar, or open one from disk." : "Show the sidebar or open a file from disk.")
                } actions: {
                    Button("Open File…") { model.focus(pane); model.choose() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: [TabDrag.type], isTargeted: $targetingEmptyPane) { providers in
                    TabDrag.receive(providers, in: pane, before: nil, model: model)
                }
                .overlay {
                    if targetingEmptyPane {
                        Rectangle().strokeBorder(WorkspaceStyle.focus, lineWidth: 2)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(alignment: .center) {
            PaneFocus { model.focus(pane) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pane.label(in: model.split ? splitDirection : .horizontal)) Reader")
    }

    private func tabBar(_ group: ReaderModel.Group) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(group.tabs) { tab in
                        TabButton(model: model, pane: pane, tab: tab, selected: group.selected == tab.id,
                                  focused: model.focusedPane == pane)
                            .id(tab.id)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: TabFrames.self, value: [tab.id: geometry.frame(in: .named(pane))])
                                }
                            }
                        WorkspaceRule(vertical: true)
                            .frame(height: 30)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: group.selected, initial: true) { _, selected in
                if let selected { proxy.scrollTo(selected) }
            }
        }
        .accessibilityLabel("\(pane.label(in: model.split ? splitDirection : .horizontal)) Tabs")
        .workspaceHeader()
        .coordinateSpace(.named(pane))
        .onPreferenceChange(TabFrames.self) { tabFrames = $0 }
        .contentShape(Rectangle())
        .onDrop(of: [TabDrag.type], delegate: TabStripDrop(model: model, pane: pane, tabs: group.tabs.map(\.id),
                                                          frames: tabFrames, insertionX: $insertionX))
        .overlay(alignment: .topLeading) {
            if let insertionX {
                GeometryReader { geometry in
                    Rectangle().fill(WorkspaceStyle.focus).frame(width: 2)
                        .offset(x: max(0, min(insertionX, geometry.size.width - 2)))
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

}

private struct TabFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct TabButton: View {
    let model: ReaderModel
    let pane: Pane
    @ObservedObject var tab: ReaderTab
    let selected: Bool
    let focused: Bool

    var body: some View {
        let weight: Font.Weight = selected ? .medium : .regular
        HStack(spacing: 2) {
            Button {
                model.activate(tab, in: pane)
            } label: {
                HStack(spacing: 5) {
                    FileIcon(name: tab.title, kind: tab.document?.kind)
                    Text(tab.title)
                        .font(.system(size: WorkspaceStyle.navigationTextSize, weight: weight))
                        .foregroundStyle(selected ? Color.primary : WorkspaceStyle.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.leading, 7)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onDrag { TabDrag.itemProvider(for: tab.id) }
            Button { model.close(tab, in: pane) } label: {
                Image(systemName: tab.dirty ? "circle.fill" : "xmark")
                    .font(.system(size: tab.dirty ? 6 : 8, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close \(tab.title)")
        }
        .font(.system(size: 12, weight: weight))
        .frame(maxWidth: 218)
        .frame(height: 30)
        .background(selected ? (focused ? WorkspaceStyle.selection : WorkspaceStyle.hover) : .clear)
        .overlay(alignment: .bottom) {
            if selected && focused {
                Rectangle().fill(WorkspaceStyle.focus).frame(height: 2)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .help(tab.location.displayPath)
        .contextMenu {
            Button("Move to Other Pane") { model.move(tab, from: pane, to: pane.other) }
            if let file = tab.location.url {
                OpenWithMenu(file: file, model: model)
            }
            Divider()
            Button("Close Tab") { model.close(tab, in: pane) }
        }
    }
}

struct TabDocument: View {
    @ObservedObject var tab: ReaderTab
    let appearance: Appearance
    let setMediaActivity: (UUID, Bool) -> Void
    let follow: (URL) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var findFocus: Bool

    private var theme: FolioTheme { ThemeStore.shared[colorScheme == .dark ? .dark : .light] }

    var body: some View {
        Group {
            switch tab.mode {
            case .reading:
                readingPane
            case .source:
                SourceEditor(text: $tab.draft, name: tab.title, theme: theme)
            case .split:
                ReaderSplit(isSplit: true, style: .sourcePreview) {
                    SourceEditor(text: $tab.draft, name: tab.title, theme: theme)
                } right: {
                    readingPane
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Folio", isPresented: Binding(get: { tab.error != nil }, set: { if !$0 { tab.error = nil } })) {
            Button("OK") { tab.error = nil }
        } message: { Text(tab.error ?? "") }
    }

    private var readingPane: some View {
        VStack(spacing: 0) {
            if tab.finding, tab.canFind {
                HStack(spacing: 7) {
                    TextField("Find in document", text: $tab.query)
                        .textFieldStyle(.roundedBorder).focused($findFocus)
                        .onAppear { findFocus = true }
                        .onSubmit { tab.web?.find(tab.query) }
                    Button("Previous Match", systemImage: "chevron.up") { tab.web?.find(tab.query, backwards: true) }
                        .labelStyle(.iconOnly).disabled(tab.query.isEmpty)
                    Button("Next Match", systemImage: "chevron.down") { tab.web?.find(tab.query) }
                        .labelStyle(.iconOnly).disabled(tab.query.isEmpty)
                    Button("Done") { tab.finding = false }
                }
                .padding(8)
                .background(WorkspaceStyle.surface)
                .onExitCommand { tab.finding = false }
                Divider()
            }
            readingContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var readingContent: some View {
        if tab.loading {
            ProgressView("Opening \(tab.title)…").controlSize(.small)
        } else if let error = tab.previewError {
            ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text(error))
        } else if let error = tab.loadError {
            ContentUnavailableView {
                Label("Couldn’t open this file", systemImage: "exclamationmark.circle")
            } description: { Text(error) } actions: {
                Button("Reload from Disk", action: tab.load)
            }
        } else if let document = tab.document, let file = tab.location.url {
            if let preview = tab.preview {
                ReaderWeb(tab: tab, follow: follow, root: tab.location.root, path: tab.location.path,
                          html: preview.html, appearance: appearance, theme: theme)
            } else if document.kind == .archive {
                AnyView(ArchiveReader(file: file, depth: tab.archiveDepth, appearance: appearance,
                                      setMediaActivity: setMediaActivity))
                    .id(tab.id)
            } else {
                NativePreview(file: file, kind: document.kind, bytes: document.bytes,
                              playbackChanged: { setMediaActivity(tab.id, $0) },
                              initialPosition: tab.resumePosition, positionChanged: tab.updateReadingPosition)
            }
        }
    }
}

/// The reader contains AppKit and WebKit views, so track clicks without taking
/// their focus, selection or pointer events.
private struct PaneFocus: NSViewRepresentable {
    let focus: () -> Void

    func makeNSView(context: Context) -> Monitor { Monitor() }
    func updateNSView(_ view: Monitor, context: Context) { view.focus = focus }

    @MainActor
    final class Monitor: NSView {
        var focus: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) {
                    focus?()
                }
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct StatusBar: View {
    static let height: CGFloat = 30

    @ObservedObject var model: ReaderModel
    let splitDirection: ReaderSplitStyle.Direction

    var body: some View {
        HStack(spacing: 6) {
            workspaceControls
            Spacer(minLength: 12)
            if let tab = model.active, !model.showingGit {
                DocumentStatus(tab: tab, paneName: model.split ? model.focusedPane.label(in: splitDirection) : nil)
                WorkspaceRule(vertical: true).frame(height: 14)
            }
            readingControls
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .background(WorkspaceStyle.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status Bar")
    }

    private var workspaceControls: some View {
        HStack(spacing: 4) {
            iconButton(model.sidebar ? "Hide Folder Tree" : "Show Folder Tree", selected: model.sidebar,
                       action: { model.sidebar.toggle() }) {
                WorkspaceIcon.folderTree
            }
            iconButton(model.showingGit ? "Back to Reading" : "Open Git View", selected: model.showingGit,
                       action: { model.showingGit.toggle() }) {
                Image(systemName: "arrow.triangle.branch")
            }
            .disabled(model.gitLocation == nil)
        }
    }

    private var readingControls: some View {
        HStack(spacing: 4) {
            iconButton(model.split ? "Merge Panes" : "Split Pane", selected: model.split, action: model.toggleSplit) {
                Image(systemName: splitDirection == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
            }
            iconButton(model.inspector ? "Hide Outline" : "Show Outline", selected: model.inspector,
                       action: { model.inspector.toggle() }) {
                WorkspaceIcon.outline
            }
                .disabled(!model.inspector && model.active?.preview == nil)
        }
        .disabled(model.showingGit)
    }

    private func iconButton<Icon: View>(_ title: String, selected: Bool, action: @escaping () -> Void,
                                        @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon()
                .font(.system(size: 12, weight: .medium))
                .frame(width: 27, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceButton(selected: selected))
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct DocumentStatus: View {
    @ObservedObject var tab: ReaderTab
    let paneName: String?

    var body: some View {
        HStack(spacing: 9) {
            if let state {
                Text(state)
                    .foregroundStyle(tab.dirty ? WorkspaceStyle.focus : Color.primary)
            }
            if let document = tab.document {
                Text(document.kind.label)
                Text(ByteCountFormatter.string(fromByteCount: document.bytes, countStyle: .file))
            }
            if let paneName { Text(paneName + " Pane") }
        }
        .font(.system(size: WorkspaceStyle.detailTextSize))
        .foregroundStyle(WorkspaceStyle.secondaryText)
        .lineLimit(1)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var state: String? {
        if tab.loading { return "Opening…" }
        if tab.loadError != nil { return "Unavailable" }
        if tab.dirty { return "Unsaved" }
        return tab.editing ? "Editing" : nil
    }
}
