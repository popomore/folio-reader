import SwiftUI

struct DocumentReader: View {
    @Environment(LibraryStore.self) private var library
    let selection: FileSelection
    let follow: (String, String?) -> Void

    var body: some View {
        ReaderContent(session: selection.session(storage: library.storage),
                      fragment: selection.fragment, cloudItem: selection.cloudItem, follow: follow)
    }
}

private struct ReaderContent: View {
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(CloudLibrary.self) private var cloud: CloudLibrary?
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 17
    @State private var session: DocumentSession
    @State private var settings = false
    @State private var outline = false
    @State private var heading: HeadingTarget?
    @State private var export: PreviewFile?
    @State private var exporting = false
    @State private var didSend = false
    @State private var sendFolder = false
    @State private var discardRecovered = false
    let cloudItem: CloudItem?
    let follow: (String, String?) -> Void
    private var sharedItem: CloudItem? { session.sharedItem }

    init(session: DocumentSession, fragment: String?, cloudItem: CloudItem?,
         follow: @escaping (String, String?) -> Void) {
        _session = State(initialValue: session)
        _heading = State(initialValue: fragment.map { HeadingTarget(fragment: $0) })
        self.follow = follow
        self.cloudItem = cloudItem
    }

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            if session.recovered {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Unsaved draft recovered", systemImage: "arrow.uturn.backward")
                    HStack {
                        if session.canEdit { Button("Review") { session.beginEditing() } }
                        if session.readOnly {
                            ShareLink("Share Recovered Draft", item: session.draft)
                            Button("Discard Draft", role: .destructive) { discardRecovered = true }
                        }
                    }
                }
                .font(.subheadline).padding().background(.quaternary)
            }
            if session.loading {
                ProgressView("Opening Document…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let opened = session.opened {
                if let preview = opened.document.preview {
                    ReaderWeb(access: opened.access, path: session.path, html: preview.html,
                              size: Double(textSize) * preferences.scale, serif: preferences.serif,
                              heading: heading, error: $session.error, follow: follow,
                              initialPosition: session.readingPosition,
                              revision: session.revision, positionChanged: updatePosition)
                } else if let file = opened.preview {
                    NativeReader(file: file.url, kind: opened.document.kind,
                        initialPosition: session.readingPosition, positionChanged: updatePosition)
                } else {
                    ContentUnavailableView("Preview Unavailable", systemImage: opened.document.kind.icon,
                                           description: Text("This file type has no iOS preview. Use Share to open it in another app."))
                }
            } else {
                ContentUnavailableView {
                    Label("Document Unavailable", systemImage: "doc.badge.ellipsis")
                } description: { Text(session.error ?? "This file could not be opened.") } actions: {
                    Button("Try Again") { Task { await session.load() } }
                }
            }
            if let error = session.error, session.opened != nil {
                Text(error).font(.footnote).foregroundStyle(.red).padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            if session.readOnly {
                Text("iCloud reading copy. Edit the original file to make changes.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            if didSend, let notice = cloud?.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let headings = session.opened?.document.preview?.headings, !headings.isEmpty {
                    Button("Document Outline", systemImage: "list.bullet.indent") { outline = true }
                }
                Menu {
                    if let cloud, !session.readOnly {
                        Section("Continue on Another Device") {
                            Button("Send Document to iCloud", systemImage: "icloud.and.arrow.up") { send(folder: false) }
                            Button("Send Folder with Assets", systemImage: "folder.badge.plus") { sendFolder = true }
                        }.disabled(!cloud.available || cloud.sharing || session.opened == nil || session.hasChanges)
                    }
                    Button("Settings", systemImage: "gearshape") { settings = true }
                    Button("Reload Document", systemImage: "arrow.clockwise") { Task { await session.load() } }
                        .disabled(session.loading)
                    Button("Share File", systemImage: "square.and.arrow.up") {
                        exporting = true
                        Task {
                            defer { exporting = false }
                            do { export = try await WorkspaceIO.export(session.folder, path: session.path) }
                            catch { session.error = error.localizedDescription }
                        }
                    }.disabled(exporting || session.opened == nil)
                } label: { Label("Document Actions", systemImage: "ellipsis.circle") }
                if session.canEdit {
                    Button("Edit Document", systemImage: "square.and.pencil") { session.beginEditing() }
                }
            }
        }
        .sheet(isPresented: $settings) { ReadingSettings() }
        .alert("Discard this recovery draft?", isPresented: $discardRecovered) {
            Button("Discard Draft", role: .destructive) { Task { await session.discard() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The saved reading copy will be kept.") }
        .confirmationDialog("Send this folder to iCloud?", isPresented: $sendFolder, titleVisibility: .visible) {
            Button("Send Folder with Assets") { send(folder: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A reading copy of the selected folder and its visible files will be added to iCloud. The original folder will be kept.")
        }
        .sheet(isPresented: $outline) {
            NavigationStack {
                List(session.opened?.document.preview?.headings ?? []) { item in
                    Button {
                        heading = HeadingTarget(fragment: item.id)
                        outline = false
                    } label: { Text(item.title).padding(.leading, CGFloat(max(0, item.level - 1)) * 12).frame(minHeight: 32) }
                }
                .navigationTitle("Contents")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { outline = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $session.editing) { DocumentEditor(session: session) }
        .sheet(item: $export) { file in ShareSheet(file: file.url) }
        .task {
            await session.resumeObservation()
            await session.loadIfNeeded()
            guard !Task.isCancelled else { return }
            if session.opened != nil, let item = sharedItem {
                var position = session.readingPosition
                position.path = session.path
                cloud?.recordPosition(item.identity, position: position)
            }
            updateProtection()
        }
        .onDisappear {
            session.stopObservation()
            if session.readOnly, let cloudItem { cloud?.releaseProtection(cloudItem.identity, owner: session.protectionOwner) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await session.persistDraft() } }
        }
        .onChange(of: session.hasChanges) { _, dirty in
            updateProtection()
        }
        .onChange(of: session.recovered) { _, recovered in
            updateProtection()
        }
        .onChange(of: session.saving) { _, saving in
            updateProtection()
        }
        .userActivity(CloudEnvironment.activityType,
            isActive: sharedItem.map { cloud?.canContinue($0) == true } == true && session.opened != nil && cloud?.testOnly != true) { activity in
            if let item = sharedItem {
                var position = session.readingPosition
                position.path = session.path
                CloudContinuation.configure(activity, item: item, position: position,
                    folder: item.storage == .linked ? session.opened?.access.root : nil)
            }
        }
    }

    private func updateProtection() {
        guard session.readOnly, let cloudItem else { return }
        cloud?.setProtected(cloudItem.identity, session.hasChanges || session.recovered || session.saving,
            owner: session.protectionOwner, document: session.path)
    }

    private func updatePosition(_ position: CloudPosition) {
        var position = position
        position.path = session.path
        position.revision = session.revision
        session.readingPosition = position
        if let sharedItem { cloud?.recordPosition(sharedItem.identity, position: position) }
    }

    private func send(folder: Bool) {
        guard let cloud, let opened = session.opened else { return }
        Task {
            do {
                session.sharedItem = try await cloud.send(root: opened.access.root, path: session.path, folder: folder,
                                                         position: session.readingPosition)
                didSend = true
            }
            catch { session.error = error.localizedDescription }
        }
    }
}

private struct DocumentEditor: View {
    @Bindable var session: DocumentSession
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = session.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.subheadline).foregroundStyle(.red)
                        ShareLink("Copy or Share Draft", item: session.draft)
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary)
                }
                TextEditor(text: $session.draft)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .accessibilityLabel("Document Source")
                    .accessibilityIdentifier("document-source")
                    .disabled(session.saving)
            }
            .navigationTitle(session.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if session.hasChanges { confirmDiscard = true }
                        else { dismiss() }
                    }.disabled(session.saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(session.saving ? "Saving…" : "Save") {
                        Task { if await session.save() { dismiss() } }
                    }
                    .disabled(!session.hasChanges || session.saving)
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
            .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { Task { await session.discard() } }
                Button("Keep Editing") { confirmDiscard = false }
            }
        }
        .interactiveDismissDisabled(session.hasChanges || session.saving)
        .onChange(of: session.draft) { session.draftChanged() }
        .onDisappear { Task { await session.persistDraft() } }
    }
}

extension PreviewFile: Identifiable {
    var id: URL { url }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
