import SwiftUI

struct ReaderBreadcrumbs: View {
    @ObservedObject var tab: ReaderTab
    let model: ReaderModel
    let focusPane: () -> Void
    let open: (FileLocation) -> Void

    @State private var presentedPath: String?
    private var location: FileLocation { tab.location }

    private struct Segment: Identifiable {
        let path: String
        let name: String
        var id: String { path }
    }

    private var segments: [Segment] {
        let rootName = tab.cloudItem?.folderName ?? location.root.lastPathComponent
        var result = [Segment(path: "", name: rootName.isEmpty ? location.root.path : rootName)]
        var parents: [Substring] = []
        for name in location.path.split(separator: "/") {
            parents.append(name)
            result.append(Segment(path: parents.joined(separator: "/"), name: String(name)))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 6) {
            breadcrumbs
            fileActions
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 9)
        }
        .font(.system(size: 11))
        .frame(height: 26)
        .background(WorkspaceStyle.surface)
    }

    private var breadcrumbs: some View {
        let path = segments
        return ViewThatFits(in: .horizontal) {
            pathRow(path).fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 2) {
                ScrollView(.horizontal) {
                    pathRow(Array(path.dropLast()))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)

                if let file = path.last {
                    HStack(spacing: 2) { breadcrumb(file) }
                        .layoutPriority(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File Path")
    }

    private func pathRow(_ path: [Segment]) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ForEach(path) { segment in breadcrumb(segment) }
        }
    }

    @ViewBuilder
    private func breadcrumb(_ segment: Segment) -> some View {
        if !segment.path.isEmpty {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        button(segment)
    }

    private var fileActions: some View {
        HStack(spacing: 6) {
            modeSwitch

            if let file = location.url {
                OpenWithMenu(file: file, model: model, showsIcon: true)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .help("Open With Another Application")
            }
        }
        .controlSize(.small)
    }

    private var modeSwitch: some View {
        // Updating the native segmented picker can trigger an AppKit accessibility crash.
        HStack(spacing: 1) {
            modeButton(.reading, title: "Reading", icon: "doc")
            modeButton(.source, title: "Source", icon: "chevron.left.forwardslash.chevron.right")
            modeButton(.split, title: "Source and Preview", icon: "rectangle.split.2x1")
        }
        .padding(2)
        .background(WorkspaceStyle.line.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document Mode")
        .disabled(!tab.canEdit)
    }

    private func modeButton(_ mode: ReaderMode, title: LocalizedStringKey, icon: String) -> some View {
        let selected = tab.mode == mode
        return Button {
            focusPane()
            tab.setMode(mode)
        } label: {
            Image(systemName: icon)
                .foregroundStyle(selected ? WorkspaceStyle.focus : WorkspaceStyle.secondaryText)
                .frame(width: 25, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceButton(selected: selected))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(tab.canEdit ? Text(title) : Text("This file is read-only in Folio"))
    }

    private func button(_ segment: Segment) -> some View {
        let currentFile = segment.path == location.path
        let isPresented = presentedPath == segment.path
        let folder = currentFile ? segment.path.split(separator: "/").dropLast().joined(separator: "/") : segment.path
        return Button {
            presentedPath = presentedPath == segment.path ? nil : segment.path
        } label: {
            Text(segment.name)
                .font(.system(size: WorkspaceStyle.detailTextSize, weight: currentFile ? .medium : .regular))
                .foregroundStyle(currentFile || isPresented ? Color.primary : WorkspaceStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .frame(maxWidth: 160, minHeight: 21)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceButton(selected: isPresented))
        .accessibilityHint(currentFile ? "Browse files in this folder" : "Browse this folder")
        .help(segment.path.isEmpty ? location.root.path : segment.path)
        .popover(isPresented: Binding(
            get: { presentedPath == segment.path },
            set: { if !$0 && presentedPath == segment.path { presentedPath = nil } }
        ), arrowEdge: .bottom) {
            ScrollView {
                DirectoryContents(root: location.root, folder: folder, current: location.path) { entry in
                    presentedPath = nil
                    open(FileLocation(root: location.root, path: entry.path))
                }
                .padding(8)
            }
            .frame(width: 320, height: 280)
            .accessibilityLabel("Browse Folder")
            .onExitCommand { presentedPath = nil }
        }
    }
}

private struct DirectoryContents: View {
    let root: URL
    let folder: String
    let current: String
    let open: (Entry) -> Void

    @State private var listing: Result<[Entry], Error>?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            switch listing {
            case .none:
                ProgressView().controlSize(.small).padding(6)
                    .accessibilityLabel("Loading Folder")
            case .success(let entries) where entries.isEmpty:
                message("No visible files")
            case .success(let entries):
                ForEach(entries) { entry in
                    if entry.directory {
                        DirectoryBranch(root: root, entry: entry, current: current, open: open)
                    } else {
                        file(entry)
                    }
                }
            case .failure(let error):
                message(error.localizedDescription)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard listing == nil else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result<[Entry], Error> { try Core.request("list", root: root, path: folder) ?? [] }
            }.value
            if !Task.isCancelled { listing = result }
        }
    }

    private func file(_ entry: Entry) -> some View {
        let selected = current == entry.path
        return Button { open(entry) } label: {
            HStack(spacing: 5) {
                FileIcon(name: entry.name, kind: entry.kind)
                Text(entry.name).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceButton(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(entry.path)
    }

    private func message(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary).padding(6)
    }
}

private struct DirectoryBranch: View {
    let root: URL
    let entry: Entry
    let current: String
    let open: (Entry) -> Void

    @State private var isExpanded: Bool

    init(root: URL, entry: Entry, current: String, open: @escaping (Entry) -> Void) {
        self.root = root
        self.entry = entry
        self.current = current
        self.open = open
        _isExpanded = State(initialValue: current.hasPrefix(entry.path + "/"))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded {
                DirectoryContents(root: root, folder: entry.path, current: current, open: open)
                    .padding(.leading, 10)
            }
        } label: {
            Label(entry.name, systemImage: isExpanded ? "folder.fill" : "folder")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12))
                .lineLimit(1).truncationMode(.middle)
                .frame(minHeight: 24)
                .help(entry.path)
        }
    }
}
