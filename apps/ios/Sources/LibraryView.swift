import SwiftUI
import UniformTypeIdentifiers

private enum PickerMode {
    case folder, files
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var navigation = LibraryNavigation()
    @State private var pickerMode: PickerMode = .folder
    @State private var showingPicker = false
    @State private var settings = false

    var body: some View {
        @Bindable var library = library
        Group {
            if sizeClass == .compact {
                NavigationStack(path: $navigation.routes) { libraryRoot }
            } else {
                NavigationSplitView {
                    NavigationStack(path: $navigation.routes) { libraryRoot }
                } detail: {
                    NavigationStack {
                        if let selected = navigation.selected {
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
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: pickerMode == .folder ? [.folder] : [.item],
                      allowsMultipleSelection: pickerMode == .files) { result in
            switch result {
            case .success(let urls):
                perform {
                    if pickerMode == .folder, let url = urls.first {
                        let folder = try await library.add(url)
                        show(folder)
                    } else if !urls.isEmpty {
                        let folder = try await library.importFiles(urls)
                        show(folder)
                    }
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    library.error = error.localizedDescription
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
            navigation.adapt(toCompact: next == .compact)
        }
        .onChange(of: navigation.routes) { _, _ in
            if sizeClass == .compact { navigation.synchronizeCompactSelection() }
        }
    }

    private var libraryRoot: some View {
        libraryList
            .navigationTitle("Folio")
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .folder(let location):
                    FolderBrowser(folder: location.folder, path: location.path, open: { open($0, $1) })
                case .file(let selection): document(selection)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reading Settings", systemImage: "textformat.size") { settings = true }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add Folder", systemImage: "folder.badge.plus") { pick(.folder) }
                        Button("Import Files", systemImage: "square.and.arrow.down") { pick(.files) }
                    } label: { Label("Add", systemImage: "plus") }
                }
            }
    }

    private func pick(_ mode: PickerMode) {
        pickerMode = mode
        showingPicker = true
    }

    private func document(_ selection: FileSelection) -> some View {
        DocumentReader(selection: selection, follow: { path, fragment in
            open(selection.folder, path, fragment: fragment)
        }).id(selection.id)
    }

    private func show(_ folder: SavedFolder) {
        navigation.routes = [.folder(FolderLocation(folder: folder, path: ""))]
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
                        Button { pick(.folder) } label: {
                            Label("Add Folder", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, minHeight: 36)
                        }.buttonStyle(.borderedProminent)
                        Button { pick(.files) } label: {
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
                                if navigation.selected?.folder.id == folder.id { navigation.selected = nil }
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

    private func open(_ folder: SavedFolder, _ path: String, fragment: String? = nil) {
        navigation.open(FileSelection(folder: folder, path: path, fragment: fragment), compact: sizeClass == .compact)
        library.record(folder, path: path)
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
    @State private var listing = FolderListing()
    @State private var query = ""
    private var filtered: [Entry] {
        query.isEmpty ? listing.entries : listing.entries.filter { $0.name.localizedStandardContains(query) }
    }

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
            if listing.loading {
                ProgressView("Opening Folder…")
            } else if let failure = listing.failure {
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
                    .disabled(listing.loading)
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
        await listing.reload(folder, path: path)
    }
}
