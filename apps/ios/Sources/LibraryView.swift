import SwiftUI
import UniformTypeIdentifiers

struct FileSelection: Hashable, Identifiable {
    let folder: SavedFolder
    let path: String
    var id: String { "\(folder.id)/\(path)" }
}

private enum PickerMode: String, Identifiable {
    case folder, files
    var id: String { rawValue }
}

private struct FolderLocation: Hashable {
    let folder: SavedFolder
    let path: String
}

private enum LibraryRoute: Hashable {
    case folder(FolderLocation)
    case file(FileSelection)
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selected: FileSelection?
    @State private var routes: [LibraryRoute] = []
    @State private var picker: PickerMode?
    @State private var settings = false

    var body: some View {
        @Bindable var library = library
        Group {
            if sizeClass == .compact {
                NavigationStack(path: $routes) { libraryRoot }
            } else {
                NavigationSplitView {
                    NavigationStack(path: $routes) { libraryRoot }
                } detail: {
                    NavigationStack {
                        if let selected {
                            document(selected)
                        } else {
                            ContentUnavailableView("Choose a File", systemImage: "doc.text",
                                                   description: Text("Open a folder, then select a document to read."))
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .sheet(item: $picker) { mode in
            DocumentPicker(folder: mode == .folder) { urls in
                picker = nil
                perform {
                    if mode == .folder, let url = urls.first {
                        let folder = try await library.add(url)
                        show(folder)
                    } else if !urls.isEmpty {
                        let folder = try await library.importFiles(urls)
                        show(folder)
                    }
                }
            }
        }
        .sheet(isPresented: $settings) { ReadingSettings() }
        .alert("Unable to Complete Action", isPresented: Binding(
            get: { library.error != nil }, set: { if !$0 { library.error = nil } }
        )) { Button("OK") { library.error = nil } } message: { Text(library.error ?? "") }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            perform {
                let folder = try await library.importFiles([url])
                show(folder)
            }
        }
        .onChange(of: sizeClass) { _, next in
            routes.removeAll { if case .file = $0 { true } else { false } }
            if next == .compact, let selected { routes.append(.file(selected)) }
        }
    }

    private var libraryRoot: some View {
        libraryList
            .navigationTitle("Folio")
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .folder(let location):
                    FolderBrowser(folder: location.folder, path: location.path, open: open)
                case .file(let selection): document(selection)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reading Settings", systemImage: "textformat.size") { settings = true }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add Folder", systemImage: "folder.badge.plus") { picker = .folder }
                        Button("Import Files", systemImage: "square.and.arrow.down") { picker = .files }
                    } label: { Label("Add", systemImage: "plus") }
                }
            }
    }

    private func document(_ selection: FileSelection) -> some View {
        DocumentReader(selection: selection, follow: { open(selection.folder, $0) }).id(selection.id)
    }

    private func show(_ folder: SavedFolder) {
        routes = [.folder(FolderLocation(folder: folder, path: ""))]
    }

    private var libraryList: some View {
        List {
            if library.folders.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Image("FolioIcon").resizable().frame(width: 72, height: 72).accessibilityHidden(true)
                        Text("Your files, ready to read.").font(.title2.weight(.semibold))
                        Text("Keep project notes, documents, and reference files together.")
                            .foregroundStyle(.secondary)
                        Button { picker = .folder } label: {
                            Label("Add Folder", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, minHeight: 36)
                        }.buttonStyle(.borderedProminent)
                        Button { picker = .files } label: {
                            Label("Import Files", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 36)
                        }.buttonStyle(.bordered)
                    }.padding(.vertical, 16)
                }
            } else {
                Section("Folders") {
                    ForEach(library.folders) { folder in
                        NavigationLink(value: LibraryRoute.folder(FolderLocation(folder: folder, path: ""))) {
                            Label { Text(folder.name).lineLimit(2) } icon: { Image(systemName: "folder").foregroundStyle(.tint) }
                                .frame(minHeight: 32)
                        }
                        .contextMenu {
                            Button("Remove from Library", systemImage: "minus.circle", role: .destructive) {
                                if selected?.folder == folder { selected = nil }
                                library.remove(folder)
                            }
                        }
                    }
                }
            }
            if !library.recent.isEmpty {
                Section("Recently Read") {
                    ForEach(library.recent) { recent in
                        if let folder = library.folders.first(where: { $0.id == recent.folderID }) {
                            Button { open(folder, recent.path) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recent.name).foregroundStyle(.primary).lineLimit(2)
                                    Text(folder.name).font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 36)
                            }
                        }
                    }
                }
            }
            Section {
                Button("Explore Sample Folder", systemImage: "sparkle.magnifyingglass") {
                    perform {
                        let folder = try await library.sample()
                        show(folder)
                    }
                }
                .disabled(library.busy)
            } footer: {
                Text("Add a folder from Files to read and edit in place. Import individual files to keep a copy in Folio.")
            }
        }
        .disabled(library.busy)
        .overlay { if library.busy { ProgressView("Opening…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
    }

    private func open(_ folder: SavedFolder, _ path: String) {
        selected = FileSelection(folder: folder, path: path)
        library.record(folder, path: path)
        if sizeClass == .compact, let selected { routes.append(.file(selected)) }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !library.busy else { return }
        library.busy = true
        Task {
            defer { library.busy = false }
            do { try await operation() }
            catch { library.error = error.localizedDescription }
        }
    }
}

struct FolderBrowser: View {
    let folder: SavedFolder
    let path: String
    let open: (SavedFolder, String) -> Void
    @State private var entries: [Entry] = []
    @State private var query = ""
    @State private var loading = true
    @State private var failure: String?
    private var filtered: [Entry] { query.isEmpty ? entries : entries.filter { $0.name.localizedStandardContains(query) } }

    var body: some View {
        List(filtered) { entry in
            if entry.directory {
                NavigationLink(value: LibraryRoute.folder(FolderLocation(folder: folder, path: entry.path))) { row(entry) }
                .accessibilityIdentifier("file:\(entry.path)")
            } else {
                Button { open(folder, entry.path) } label: { row(entry) }
                    .accessibilityIdentifier("file:\(entry.path)")
            }
        }
        .overlay {
            if loading {
                ProgressView("Opening Folder…")
            } else if let failure {
                ContentUnavailableView {
                    Label("Folder Unavailable", systemImage: "folder.badge.questionmark")
                } description: { Text(failure) } actions: { Button("Try Again") { Task { await reload() } } }
            } else if filtered.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("This Folder Is Empty", systemImage: "folder",
                                           description: Text("Files added to this folder will appear after a refresh."))
                } else { ContentUnavailableView.search(text: query) }
            }
        }
        .navigationTitle(path.isEmpty ? folder.name : URL(fileURLWithPath: path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search This Folder")
        .refreshable { await reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh Folder", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .disabled(loading)
            }
        }
        .task { await reload() }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.directory ? "folder" : (entry.kind ?? .other).icon)
                .foregroundStyle(entry.directory ? Color.accentColor : .secondary)
                .font(.title3).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).foregroundStyle(.primary).lineLimit(2)
                Text(entry.directory ? "Folder" : (entry.kind ?? .other).label)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !entry.directory { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }.frame(minHeight: 44)
    }

    private func reload() async {
        loading = entries.isEmpty
        failure = nil
        do { entries = try await WorkspaceIO.list(folder, path: path) }
        catch { failure = error.localizedDescription }
        loading = false
    }
}

private struct DocumentPicker: UIViewControllerRepresentable {
    let folder: Bool
    let picked: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let view = UIDocumentPickerViewController(forOpeningContentTypes: folder ? [.folder] : [.item], asCopy: false)
        view.allowsMultipleSelection = !folder
        view.delegate = context.coordinator
        return view
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let picked: ([URL]) -> Void
        init(picked: @escaping ([URL]) -> Void) { self.picked = picked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { picked(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { picked([]) }
    }
}
