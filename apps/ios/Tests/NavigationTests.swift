import Foundation
import XCTest
@testable import Folio

final class NavigationTests: XCTestCase {
    func testBackThenExpansionPreservesTheVisibleDocumentAndItsHeading() {
        let folder = SavedFolder(id: UUID(), name: "Project", bookmark: Data())
        let root = LibraryRoute.folder(FolderLocation(folder: folder, path: ""))
        let first = FileSelection(folder: folder, path: "first.md", fragment: "详情")
        let second = FileSelection(folder: folder, path: "second.md")
        var navigation = LibraryNavigation(routes: [root])
        navigation.open(first, compact: true)
        navigation.open(second, compact: true)
        navigation.routes.removeLast()
        navigation.adapt(toCompact: false)
        XCTAssertEqual(navigation.selected, first)
        XCTAssertEqual(navigation.routes, [root])
        navigation.adapt(toCompact: true)
        XCTAssertEqual(navigation.routes.last, .file(first))
        XCTAssertEqual(navigation.selected?.fragment, "详情")
    }

    func testReturningToTheFolderClearsTheCompactDocumentSelection() {
        let folder = SavedFolder(id: UUID(), name: "Project", bookmark: Data())
        var navigation = LibraryNavigation(routes: [.folder(FolderLocation(folder: folder, path: ""))])
        navigation.open(FileSelection(folder: folder, path: "note.md"), compact: true)
        navigation.routes.removeLast()
        navigation.synchronizeCompactSelection()
        XCTAssertNil(navigation.selected)
        navigation.adapt(toCompact: false)
        XCTAssertNil(navigation.selected)
        navigation.adapt(toCompact: true)
        XCTAssertEqual(navigation.routes.count, 1)
    }
}
