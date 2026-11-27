import Foundation

struct FileSelection: Hashable, Identifiable, Sendable {
    let id = UUID()
    let folder: SavedFolder
    let path: String
    let fragment: String?
    let cloudItem: CloudItem?
    let position: CloudPosition?
    private let reader: SelectionSession

    @MainActor
    init(folder: SavedFolder, path: String, fragment: String? = nil, cloudItem: CloudItem? = nil, position: CloudPosition? = nil) {
        self.folder = folder
        self.path = path
        self.fragment = fragment
        self.cloudItem = cloudItem
        self.position = position
        reader = SelectionSession()
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    @MainActor
    func session(storage: URL) -> DocumentSession {
        if let session = reader.value { return session }
        let session = DocumentSession(folder: folder, path: path, storage: storage, readOnly: cloudItem?.storage == .copy)
        session.readingPosition = position ?? CloudPosition()
        reader.value = session
        return session
    }
}

@MainActor
private final class SelectionSession {
    var value: DocumentSession?
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
