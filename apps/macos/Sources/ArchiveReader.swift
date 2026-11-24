import SwiftUI

struct ArchiveNode: Identifiable {
    let item: ArchiveItem
    let children: [ArchiveNode]?

    var id: String { item.path }

    static func tree(_ items: [ArchiveItem]) -> [ArchiveNode] {
        var entries = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
        for item in items {
            let parts = item.path.split(separator: "/")
            for end in 1..<parts.count {
                let path = parts.prefix(end).joined(separator: "/")
                if entries[path] == nil {
                    entries[path] = ArchiveItem(path: path, directory: true, bytes: 0, unavailableReason: nil)
                }
            }
        }
        let grouped = Dictionary(grouping: entries.values) { item in
            item.path.split(separator: "/").dropLast().joined(separator: "/")
        }
        func children(of path: String) -> [ArchiveNode] {
            (grouped[path] ?? []).sorted {
                if $0.directory != $1.directory { return $0.directory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }.map { ArchiveNode(item: $0, children: $0.directory ? children(of: $0.path) : nil) }
        }
        return children(of: "")
    }
}

struct ArchiveReader: View {
    let file: URL
    let depth: Int
    let appearance: Appearance
    let setMediaActivity: (UUID, Bool) -> Void
    @State private var contents: ArchiveContents?
    @State private var nodes: [ArchiveNode] = []
    @State private var selected: String?
    @State private var tab: ReaderTab?
    @State private var filter = ""
    @State private var failure: String?
    @State private var entryFailure: String?
    @State private var pendingFragment: String?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView("Opening archive…").controlSize(.small)
            } else if let failure {
                ContentUnavailableView("Couldn’t open this archive", systemImage: "archivebox", description: Text(failure))
            } else if let contents {
                if contents.index.items.isEmpty {
                    ContentUnavailableView("This archive is empty", systemImage: "archivebox")
                } else {
                    browser(contents)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: file) { await load() }
        .onChange(of: selected) { _, path in
            show(path, fragment: pendingFragment)
            pendingFragment = nil
        }
    }

    private func browser(_ contents: ArchiveContents) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(contents.index.fileCount) files", systemImage: "archivebox")
                Text(ByteCountFormatter.string(fromByteCount: contents.index.bytes, countStyle: .file))
                Spacer()
                Text("Read Only")
            }
            .font(.system(size: WorkspaceStyle.detailTextSize))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(WorkspaceStyle.surface)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    TextField("Filter files", text: $filter)
                        .textFieldStyle(.roundedBorder).padding(8)
                    List(selection: $selected) {
                        if filter.isEmpty {
                            OutlineGroup(nodes, children: \.children) { node in row(node.item) }
                        } else {
                            ForEach(contents.index.items.filter { !$0.directory && $0.path.localizedCaseInsensitiveContains(filter) }) {
                                row($0, fullPath: true)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .accessibilityLabel("Archive Files")
                }
                .frame(minWidth: 170, idealWidth: 230, maxWidth: 340)
                preview.frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func row(_ item: ArchiveItem, fullPath: Bool = false) -> some View {
        HStack {
            Label(fullPath ? item.path : item.name,
                  systemImage: item.directory ? "folder" : item.unavailableReason == nil ? "doc" : "link")
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if !item.directory {
                Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .tag(item.path)
        .help(item.unavailableReason ?? item.path)
    }

    @ViewBuilder
    private var preview: some View {
        if let entryFailure {
            ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text(entryFailure))
        } else if let tab {
            TabDocument(tab: tab, appearance: appearance, setMediaActivity: setMediaActivity,
                        follow: { follow($0) })
                .id(tab.id)
        } else {
            ContentUnavailableView("Select a file to preview", systemImage: "doc.text")
        }
    }

    private func load() async {
        loading = true
        tab = nil
        selected = nil
        contents = nil
        failure = nil
        entryFailure = nil
        pendingFragment = nil
        guard depth < 3 else {
            failure = "Nested archives can be previewed up to three levels deep."
            loading = false
            return
        }
        let worker = Task.detached(priority: .userInitiated) { try ArchiveContents.open(file) }
        do {
            let opened = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            contents = opened
            nodes = ArchiveNode.tree(opened.index.items)
            loading = false
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
            loading = false
        }
    }

    private func show(_ path: String?, fragment: String? = nil) {
        tab = nil
        entryFailure = nil
        guard let contents, let path, let item = contents.index.items.first(where: { $0.path == path }), !item.directory else { return }
        if let reason = item.unavailableReason { entryFailure = reason; return }
        let tab = ReaderTab(location: FileLocation(root: contents.root, path: path), readOnly: true, archiveDepth: depth + 1)
        tab.pendingFragment = fragment
        self.tab = tab
        tab.load()
    }

    private func follow(_ url: URL) {
        let link = ArchiveLink(url)
        if tab?.location.path == link.path, let fragment = link.fragment {
            tab?.web?.heading(fragment)
        } else {
            pendingFragment = link.fragment
            selected = link.path
        }
    }
}
