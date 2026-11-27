import Foundation

struct FileSelection: Hashable, Identifiable, Sendable {
    let id = UUID()
    let folder: SavedFolder
    let path: String
    let fragment: String?
    let cloudItem: CloudItem?
    let position: CloudPosition?
    let readOnly: Bool
    private let reader: SelectionSession

    @MainActor
    init(folder: SavedFolder, path: String, fragment: String? = nil, cloudItem: CloudItem? = nil, position: CloudPosition? = nil,
         readOnly: Bool? = nil) {
        self.folder = folder
        self.path = path
        self.fragment = fragment
        self.cloudItem = cloudItem
        self.position = position
        self.readOnly = readOnly ?? (cloudItem?.storage == .copy)
        reader = SelectionSession(item: cloudItem)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    @MainActor
    func session(storage: URL) -> DocumentSession {
        if let session = reader.value { return session }
        let session = DocumentSession(folder: folder, path: path, storage: storage, readOnly: readOnly)
        session.readingPosition = position ?? CloudPosition()
        session.sharedItem = reader.sharedItem
        reader.value = session
        return session
    }

    @MainActor var sharedItem: CloudItem? { reader.value?.sharedItem ?? (reader.value == nil ? reader.sharedItem : nil) }
    @MainActor var hasProtectedDraft: Bool {
        reader.value.map { $0.hasChanges || $0.recovered || $0.saving } ?? false
    }
    @MainActor func detachSharing() { reader.sharedItem = nil; reader.value?.sharedItem = nil }
    @MainActor func keepRetiredDraft() {
        reader.value?.error = "This reading copy was deleted on another device. Your recovery draft is kept; share or discard it before closing."
    }
}

@MainActor
private final class SelectionSession {
    var value: DocumentSession?
    var sharedItem: CloudItem?
    init(item: CloudItem?) { sharedItem = item }
}

struct CloudFolderRequest {
    let item: CloudItem
    let position: CloudPosition?

    @MainActor
    func complete(using cloud: CloudLibrary, folder: URL, allowChanged: Bool = false) async throws -> CloudOpened {
        try await cloud.bind(item, to: folder, allowChanged: allowChanged)
        let opened = try await cloud.open(item)
        return CloudOpened(item: opened.item, access: opened.access, position: position ?? opened.position)
    }
}

struct FolderLocation: Hashable, Sendable {
    let folder: SavedFolder
    let path: String
}

enum LibraryRoute: Hashable, Sendable {
    case folder(FolderLocation)
    case file(FileSelection)
}

struct LibraryNavigation {
    var selected: FileSelection?
    var routes: [LibraryRoute] = []

    @MainActor mutating func retireCloudItems(_ ids: Set<UUID>, all: Bool = false, protecting: Set<UUID> = []) {
        func keep(_ file: FileSelection) -> Bool {
            guard let item = file.sharedItem, all || ids.contains(item.id) else { return true }
            if !file.readOnly { file.detachSharing(); return true }
            if file.hasProtectedDraft || protecting.contains(item.id) { file.keepRetiredDraft(); file.detachSharing(); return true }
            return false
        }
        if let selected, !keep(selected) { self.selected = nil }
        routes.removeAll { if case .file(let file) = $0 { !keep(file) } else { false } }
    }

    mutating func open(_ file: FileSelection, compact: Bool) {
        selected = file
        if compact { routes.append(.file(file)) }
    }

    mutating func synchronizeCompactSelection() {
        if let last = routes.last, case .file(let file) = last { selected = file }
        else { selected = nil }
    }

    mutating func adapt(toCompact compact: Bool) {
        if !compact { synchronizeCompactSelection() }
        routes.removeAll { if case .file = $0 { true } else { false } }
        if compact, let selected { routes.append(.file(selected)) }
    }
}
