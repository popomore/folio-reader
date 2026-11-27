import Foundation

struct FileSelection: Hashable, Identifiable, Sendable {
    let id = UUID()
    let folder: SavedFolder
    let path: String
    var fragment: String? = nil
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
