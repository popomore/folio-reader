import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum Pane: String, CaseIterable {
    case left, right

    var other: Pane { self == .left ? .right : .left }
    var label: String { rawValue.capitalized }
}

enum ReaderMode: Hashable {
    case reading, source, split
}

struct FileLocation: Hashable, Sendable {
    let root: URL
    let path: String

    var name: String { String(path.split(separator: "/").last ?? "") }
    var url: URL? { Core.file(path, in: root) }
    var displayPath: String { "\(root.lastPathComponent) / \(path)" }
}

@MainActor
final class ReaderTab: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    let location: FileLocation
    let readOnly: Bool
    let archiveDepth: Int
    @Published private(set) var document: Document?
    @Published private(set) var loading = false
    @Published private(set) var mode: ReaderMode = .reading
    @Published var draft = "" {
        didSet { if mode == .split { renderDraft() } }
    }
    @Published private var draftPreview: Result<Document.Preview, Error>?
    @Published var loadError: String?
    @Published var error: String?
    @Published var finding = false
    @Published var query = ""

    weak var web: ReaderWeb.Coordinator?
    var pendingFragment: String?
    var scrollOffset = 0.0
    @Published var cloudItem: CloudItem?
    @Published var readingPosition = CloudPosition()
    var resumePosition: CloudPosition?
    var cloudReadOnly = false
    weak var cloud: CloudLibrary?
    var cloudAccess: CloudAccess?
    private var readTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var previewNeedsReload = false
    private var documentObserver: CloudFileObservation?

    init(location: FileLocation, readOnly: Bool = false, archiveDepth: Int = 0) {
        self.location = location
        self.readOnly = readOnly
        self.archiveDepth = archiveDepth
    }

    var editing: Bool { mode != .reading }
    var dirty: Bool { editing && document?.source != draft }
    var title: String { location.name }
    var canFind: Bool { mode != .source && preview != nil && previewError == nil }
    var canEdit: Bool { !readOnly && !cloudReadOnly && document?.revision != nil && document?.source != nil }
    var preview: Document.Preview? {
        if case .success(let preview) = draftPreview { return preview }
        return document?.preview
    }
    var previewError: String? {
        if case .failure(let error) = draftPreview { return error.localizedDescription }
        return nil
    }

    func load() {
        documentObserver?.stop()
        documentObserver = nil
        readTask?.cancel()
        let location = location
        if FileManager.default.isUbiquitousItem(at: location.root.appendingPathComponent(location.path)) {
            documentObserver = CloudFileObservation(url: location.root.appendingPathComponent(location.path)) { [weak self] moved in
                guard let self else { return }
                if moved != nil { self.error = "This document moved. Open it again from its folder." }
                else if !editing { resumePosition = readingPosition; scrollOffset = 0; load() }
                else if dirty { self.error = "This document changed elsewhere. Save checks for conflicts before replacing it." }
            }
        }
        mode = .reading
        clearDraftPreview()
        draft = ""
        document = nil
        previewNeedsReload = false
        loadError = nil
        loading = true
        readTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result<Document?, Error> {
                    try CloudReaderAccess.perform(root: location.root, path: location.path, writing: false) { path in
                        try Core.request("read", root: location.root, path: path)
                    }
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            loading = false
            switch result {
            case .success(let document):
                self.document = document
                if document != nil, let item = cloudItem {
                    var position = readingPosition
                    position.path = location.path
                    cloud?.recordPosition(item.identity, position: position)
                }
                if document == nil { loadError = "The reader did not return a document." }
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }
    }

    func setMode(_ mode: ReaderMode) {
        guard mode != self.mode else { return }
        if mode == .reading {
            _ = leaveDraft()
            return
        }
        guard canEdit, let source = document?.source else { return }
        if !editing { draft = source }
        self.mode = mode
        if mode == .split {
            renderDraft()
        } else {
            finding = false
            clearDraftPreview()
        }
    }

    func updateReadingPosition(_ value: CloudPosition) {
        var value = value
        value.path = location.path
        value.revision = document?.revision
        readingPosition = value
        if let cloudItem { cloud?.recordPosition(cloudItem.identity, position: value) }
    }

    private func renderDraft() {
        draftTask?.cancel()
        let source = draft
        let name = title
        draftTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    guard let preview = try Core.textPreview(for: name, source: source) else {
                        throw CoreError(message: "This draft could not be rendered.")
                    }
                    return preview
                }
            }.value
            guard !Task.isCancelled else { return }
            self?.draftPreview = result
        }
    }

    private func clearDraftPreview() {
        draftTask?.cancel()
        draftTask = nil
        draftPreview = nil
    }

    func stopObservation() {
        documentObserver?.stop()
        documentObserver = nil
    }

    deinit { documentObserver?.stop() }

    @discardableResult
    func save() -> Bool {
        guard canEdit, editing, let document, let revision = document.revision else { return false }
        guard dirty else { return true }
        do {
            let savedRevision: String? = try CloudReaderAccess.perform(root: location.root, path: location.path,
                writing: true, presenter: documentObserver) { path in
                    try Core.request("save", root: location.root, path: path, values: ["revision": revision, "source": draft])
                }
            guard let savedRevision else { throw CoreError(message: "The file could not be saved.") }
            let fileSize = try? location.url?.resourceValues(forKeys: [.fileSizeKey]).fileSize
            previewNeedsReload = true
            self.document = Document(kind: document.kind, bytes: fileSize.map(Int64.init) ?? document.bytes,
                                     source: draft, revision: savedRevision, preview: document.preview)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func leaveDraft(reload: Bool = false) -> Bool {
        if dirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to \(title)?"
            alert.informativeText = "Discarding changes restores the version currently on disk."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let discard = alert.addButton(withTitle: "Discard Changes")
            discard.hasDestructiveAction = true
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard save() else { return false }
            case .alertThirdButtonReturn:
                draft = ""
            default:
                return false
            }
        }
        if reload || previewNeedsReload {
            load()
        } else {
            mode = .reading
            clearDraftPreview()
        }
        return true
    }
}

@MainActor
final class ReaderModel: ObservableObject {
    struct Group {
        var tabs: [ReaderTab] = []
        var selected: UUID?
        var active: ReaderTab? { tabs.first { $0.id == selected } }

        mutating func insert(_ tab: ReaderTab, before anchor: UUID?) {
            let index = tabs.firstIndex { $0.id == anchor } ?? tabs.endIndex
            tabs.insert(tab, at: index)
        }

        mutating func remove(_ tab: ReaderTab) {
            guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            tabs.remove(at: index)
            if selected == tab.id { selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        }
    }

    struct Folder: Identifiable {
        let url: URL
        var entries: [String: [Entry]] = [:]
        var expanded: Set<String> = []
        var failures: [String: String] = [:]
        var id: URL { url }
        var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
    }

    private static let foldersKey = "savedWorkspaceFolders"
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var groups: [Pane: Group] = [.left: Group()]
    @Published private(set) var focusedPane: Pane = .left
    @Published private(set) var selectedRoot: URL?
    @Published var error: String?
    @Published var sidebar = true
    @Published var inspector = false
    @Published var showingGit = false
    @Published var appearance = Appearance() {
        didSet { if !InstanceMode.isSeparate { appearance.persist() } }
    }
    @Published private(set) var gitRefresh = UUID()
    @Published private(set) var folderTreeFocus: UUID?

    private var observation: AnyCancellable?
    private var activeMedia: Set<UUID> = []
    private var openPanels = 0

    var hasUpdateActivity: Bool {
        !activeMedia.isEmpty || openPanels > 0 ||
            groups.values.contains { $0.tabs.contains { $0.editing || $0.loading } }
    }

    func setMediaActivity(_ id: UUID, active: Bool) {
        if active { activeMedia.insert(id) } else { activeMedia.remove(id) }
    }
    private let defaults: UserDefaults
    let cloud: CloudLibrary

    init(defaults: UserDefaults = .standard, cloud: CloudLibrary? = nil) {
        self.defaults = defaults
        if let cloud { self.cloud = cloud }
        else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let root = InstanceMode.isSeparate ?
                ProcessInfo.processInfo.environment["FOLIO_CLOUD_QA_DIRECTORY"].map { URL(fileURLWithPath: $0) } ??
                    FileManager.default.temporaryDirectory.appendingPathComponent("FolioCloudQA-\(UUID().uuidString)") :
                support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.popomore.folio.tests")
            let storage = root.appendingPathComponent("Cloud")
            if InstanceMode.isSeparate, ProcessInfo.processInfo.environment["FOLIO_CLOUD_FIXTURE"] == "1",
               let fixture = try? CloudFixture.library(storage: storage, device: "QA Mac") { self.cloud = fixture }
            else { self.cloud = CloudLibrary(storage: storage, deviceName: Host.current().localizedName ?? "Mac") }
        }
        if !InstanceMode.isSeparate {
            folders = (defaults.stringArray(forKey: Self.foldersKey) ?? []).map {
                Folder(url: URL(fileURLWithPath: $0, isDirectory: true))
            }
        }
        selectedRoot = folders.first?.url
        if let selectedRoot { expand(root: selectedRoot, path: "") }
    }

    var active: ReaderTab? { groups[focusedPane]?.active }
    var split: Bool { groups[.right] != nil }
    var gitLocation: FileLocation? {
        active?.location ?? selectedRoot.map { FileLocation(root: $0, path: "") }
    }

    func focusFolderTree() {
        sidebar = true
        folderTreeFocus = UUID()
    }

    private func updateActive() {
        if let location = active?.location {
            selectedRoot = location.root
            reveal(location)
        }
        observation = active?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    private func reveal(_ location: FileLocation) {
        guard let folder = folders.first(where: { $0.url == location.root }) else { return }
        var parent = ""
        for component in location.path.split(separator: "/").dropLast() {
            if !folder.expanded.contains(parent) { expand(root: location.root, path: parent) }
            parent += parent.isEmpty ? String(component) : "/" + component
        }
        if !folder.expanded.contains(parent) { expand(root: location.root, path: parent) }
    }

    func focus(_ pane: Pane) {
        guard focusedPane != pane, groups[pane] != nil else { return }
        focusedPane = pane
        updateActive()
    }

    func activate(_ tab: ReaderTab, in pane: Pane) {
        guard var group = groups[pane], group.tabs.contains(where: { $0.id == tab.id }) else { return }
        if group.selected != tab.id {
            group.selected = tab.id
            groups[pane] = group
        }
        focusedPane = pane
        showingGit = false
        updateActive()
    }

    func cycle(_ offset: Int) {
        guard let group = groups[focusedPane], group.tabs.count > 1,
              let index = group.tabs.firstIndex(where: { $0.id == group.selected }) else { return }
        activate(group.tabs[(index + offset + group.tabs.count) % group.tabs.count], in: focusedPane)
    }

    func open(_ location: FileLocation, in pane: Pane? = nil, fragment: String? = nil, inheritSharing: Bool = true) {
        let target = pane ?? focusedPane
        let url = location.url
        guard url != nil else { error = "This file is outside the selected folder."; return }
        for source in Pane.allCases {
            guard let tab = groups[source]?.tabs.first(where: { $0.location == location || (url != nil && $0.location.url == url) }) else { continue }
            if inheritSharing { inheritCloud(tab) }
            if pane != nil, source != target {
                move(tab, from: source, to: target)
            } else {
                activate(tab, in: source)
            }
            if let fragment {
                if let web = tab.web { web.heading(fragment) }
                else { tab.pendingFragment = fragment }
            }
            return
        }
        let tab = ReaderTab(location: location)
        if inheritSharing { inheritCloud(tab) }
        tab.pendingFragment = fragment
        var group = groups[target] ?? Group()
        group.tabs.append(tab)
        groups[target] = group
        activate(tab, in: target)
        tab.load()
    }

    private func inheritCloud(_ tab: ReaderTab) {
        let peers = [active].compactMap { $0 } + groups.values.flatMap(\.tabs)
        guard let peer = peers.first(where: {
            $0.id != tab.id && $0.location.root.pathComponents == tab.location.root.pathComponents &&
                $0.cloudItem?.tracks(tab.location.path) == true
        }), !tab.dirty || !peer.cloudReadOnly else { return }
        tab.cloud = peer.cloud
        tab.cloudItem = peer.cloudItem
        tab.cloudReadOnly = peer.cloudReadOnly
        tab.cloudAccess = peer.cloudAccess
        if let item = tab.cloudItem, let document = tab.document {
            var position = tab.readingPosition
            position.path = tab.location.path
            position.revision = document.revision
            tab.readingPosition = position
            tab.cloud?.recordPosition(item.identity, position: position)
        }
    }

    func sendActiveToCloud(folder: Bool = false) {
        guard let tab = active, !tab.dirty, !tab.loading, !tab.cloudReadOnly else { return }
        if folder {
            let alert = NSAlert()
            alert.messageText = "Send this folder to iCloud?"
            alert.informativeText = "A reading copy of the selected folder and its visible files will be added to iCloud. The original folder will be kept."
            alert.addButton(withTitle: "Send Folder with Assets")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            do {
                let item = try await cloud.send(root: tab.location.root, path: tab.location.path, folder: folder, position: tab.readingPosition)
                tab.cloud = cloud
                tab.cloudItem = item
            } catch { self.error = error.localizedDescription }
        }
    }

    func openCloud(_ item: CloudItem, position: CloudPosition? = nil, localReview: Bool = false) async {
        do {
            if cloud.needsFolder(item) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.message = "Choose the iCloud folder containing \(item.name)."
                guard panel.runModal() == .OK, let root = panel.url else { return }
                do { try await cloud.bind(item, to: root) }
                catch CloudFailure.bindingChanged {
                    let alert = NSAlert()
                    alert.messageText = "Use this document?"
                    alert.informativeText = "The selected file differs from the shared version. It may have changed since sharing, or this may be a different folder."
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Use Selected Document")
                    guard alert.runModal() == .alertSecondButtonReturn else { return }
                    try await cloud.bind(item, to: root, allowChanged: true)
                }
            }
            let opened: CloudOpened
            if localReview { opened = try await cloud.openLocalReview(item) }
            else { opened = try await cloud.open(item) }
            let position = position ?? opened.position
            let path = try CloudPaths.relative(position?.sanitized.path ?? item.path)
            let location = FileLocation(root: opened.access.root, path: path)
            open(location, inheritSharing: false)
            guard let tab = active, tab.location == location else { throw CloudFailure.stale }
            guard !tab.dirty else { throw CloudFailure.message("Save or discard the current draft before continuing from another device.") }
            tab.cloud = cloud
            tab.cloudItem = item
            tab.cloudReadOnly = item.storage == .copy
            tab.cloudAccess = opened.access
            tab.resumePosition = position
            tab.scrollOffset = 0
            tab.readingPosition = position ?? CloudPosition()
            tab.load()
        } catch { self.error = error.localizedDescription }
    }

    func continueCloudActivity(_ activity: NSUserActivity) {
        guard let continuation = CloudContinuation.read(activity) else { return }
        Task {
            await cloud.refresh()
            guard let item = cloud.item(continuation.identity.id), item.identity == continuation.identity, item.state == .active else {
                error = CloudFailure.stale.localizedDescription
                return
            }
            if item.storage == .linked, let folder = continuation.folder { try? await cloud.bind(item, to: folder) }
            await openCloud(item, position: continuation.position)
        }
    }

    func retireCloudTabs(_ ids: Set<UUID>, all: Bool = false, downloadsOnly: Bool = false) {
        for (pane, group) in groups {
            for tab in group.tabs {
                guard let item = tab.cloudItem, all || ids.contains(item.id) else { continue }
                if tab.cloudReadOnly && !tab.dirty { close(tab, in: pane) }
                else if !downloadsOnly { tab.cloudItem = nil; tab.cloud = nil }
            }
        }
    }

    func dropTab(_ id: UUID, in target: Pane, before anchor: UUID?, createRightPane: Bool = false) {
        guard groups[target] != nil || (createRightPane && target == .right) else { return }
        for (source, group) in groups {
            if let tab = group.tabs.first(where: { $0.id == id }) {
                move(tab, from: source, to: target, before: anchor)
                return
            }
        }
    }

    func move(_ tab: ReaderTab, from source: Pane, to target: Pane, before anchor: UUID? = nil) {
        guard anchor != tab.id, var origin = groups[source],
              let index = origin.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if source == target {
            origin.tabs.remove(at: index)
            origin.insert(tab, before: anchor)
            groups[source] = origin
            return
        }

        origin.remove(tab)
        var destination = groups[target] ?? Group()
        destination.insert(tab, before: anchor)
        destination.selected = tab.id
        var updated = groups
        updated[source] = origin
        updated[target] = destination
        groups = updated
        activate(tab, in: target)
    }

    func close(_ tab: ReaderTab, in pane: Pane) {
        guard var group = groups[pane], tab.leaveDraft() else { return }
        tab.stopObservation()
        group.remove(tab)
        groups[pane] = group
        updateActive()
    }

    func closeActive() {
        if showingGit { showingGit = false }
        else if let active { close(active, in: focusedPane) }
        else { NSApp.keyWindow?.performClose(nil) }
    }

    func toggleSplit() {
        showingGit = false
        if let right = groups[.right], var left = groups[.left] {
            let selected = active?.id
            left.tabs.append(contentsOf: right.tabs)
            left.selected = selected ?? left.selected ?? right.selected
            groups = [.left: left]
            focusedPane = .left
        } else {
            groups[.right] = Group()
            focusedPane = .right
            sidebar = true
        }
        updateActive()
    }

    func protectAllDrafts() -> Bool {
        for pane in Pane.allCases {
            for tab in groups[pane]?.tabs ?? [] where tab.dirty {
                activate(tab, in: pane)
                guard tab.leaveDraft() else { return false }
            }
        }
        return true
    }

    func reload() {
        if showingGit {
            gitRefresh = UUID()
        } else if let active, active.leaveDraft(reload: true) {
            gitRefresh = UUID()
        } else if active == nil, let selectedRoot {
            refreshFolder(selectedRoot)
        }
    }

    func follow(_ url: URL, from tab: ReaderTab) {
        let relative = String(url.path.dropFirst())
        let location = FileLocation(root: tab.location.root, path: relative)
        guard let file = location.url, FileManager.default.fileExists(atPath: file.path) else { return }
        if let pane = Pane.allCases.first(where: { groups[$0]?.tabs.contains { $0.id == tab.id } == true }) {
            focus(pane)
        }
        let fragment = url.fragment?.removingPercentEncoding
        if location == tab.location, let fragment {
            tab.web?.heading(fragment)
        } else {
            open(location, fragment: fragment)
        }
    }

    func choose(foldersOnly: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !foldersOnly
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = foldersOnly ? "Add" : "Open"
        openPanels += 1
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                defer { openPanels -= 1 }
                if response == .OK { openURLs(panel.urls) }
            }
        } else {
            defer { openPanels -= 1 }
            if panel.runModal() == .OK { openURLs(panel.urls) }
        }
    }

    func openURLs(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            do {
                if try canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    addFolder(canonical)
                    continue
                }
                let parent = canonical.deletingLastPathComponent()
                let root = folders.map(\.url)
                    .filter { canonical.pathComponents.starts(with: $0.pathComponents) }
                    .max { $0.pathComponents.count < $1.pathComponents.count } ?? parent
                addFolder(root)
                let relative = canonical.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                open(FileLocation(root: root, path: relative))
            } catch { self.error = error.localizedDescription }
        }
    }

    func toggleFolder(root: URL, path: String) {
        guard let index = folders.firstIndex(where: { $0.url == root }) else { return }
        selectedRoot = root
        if folders[index].expanded.contains(path) {
            folders[index].expanded.remove(path)
        } else {
            expand(root: root, path: path)
        }
    }

    func removeFolder(_ root: URL) {
        let tabs = Pane.allCases.flatMap { pane in
            (groups[pane]?.tabs ?? []).filter { $0.location.root == root }.map { (pane, $0) }
        }
        for (pane, tab) in tabs where tab.dirty {
            activate(tab, in: pane)
            guard tab.leaveDraft() else { return }
        }
        for (pane, tab) in tabs { close(tab, in: pane) }
        folders.removeAll { $0.url == root }
        if selectedRoot == root { selectedRoot = folders.first?.url }
        persistFolders()
    }

    func refreshFolder(_ root: URL) {
        guard let folder = folders.first(where: { $0.url == root }) else { return }
        for path in folder.expanded.union([""]) { expand(root: root, path: path) }
        gitRefresh = UUID()
    }

    func openExternally(_ file: URL, application: URL? = nil) {
        if let application {
            NSWorkspace.shared.open([file], withApplicationAt: application, configuration: .init()) { [weak self] _, error in
                if let error { Task { @MainActor in self?.error = error.localizedDescription } }
            }
        } else if !NSWorkspace.shared.open(file) {
            error = "No application could open \(file.lastPathComponent)."
        }
    }

    func chooseApplication(for file: URL) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Open"
        panel.message = "Choose an application to open \(file.lastPathComponent)."
        openPanels += 1
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { openPanels -= 1 }
            if response == .OK, let application = panel.url { openExternally(file, application: application) }
        }
    }

    private func addFolder(_ root: URL) {
        if !folders.contains(where: { $0.url == root }) {
            folders.append(Folder(url: root))
            persistFolders()
        }
        selectedRoot = root
        if !folders.contains(where: { $0.url == root && $0.expanded.contains("") }) {
            expand(root: root, path: "")
        }
    }

    private func persistFolders() {
        guard !InstanceMode.isSeparate else { return }
        defaults.set(folders.map(\.url.path), forKey: Self.foldersKey)
    }

    private func expand(root: URL, path: String) {
        guard let index = folders.firstIndex(where: { $0.url == root }) else { return }
        folders[index].expanded.insert(path)
        do {
            folders[index].entries[path] = try Core.request("list", root: root, path: path) as [Entry]?
            folders[index].failures.removeValue(forKey: path)
        } catch {
            folders[index].entries.removeValue(forKey: path)
            folders[index].failures[path] = error.localizedDescription
        }
    }
}
