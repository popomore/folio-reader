import XCTest
import UIKit

@MainActor
final class CloudReaderTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["FOLIO_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["FOLIO_CLOUD_TEST_LIBRARY"] = "1"
    }

    func testContinueReadingOpensTheSnapshotAtTheSavedHeading() {
        app.launch()
        openNotes()
        XCTAssertTrue(app.webViews.staticTexts["Section 12"].waitForExistence(timeout: 30))
        let web = app.webViews.firstMatch
        let heading = web.staticTexts["Section 12"]
        let visible = web.frame.insetBy(dx: 0, dy: 2)
        XCTAssertTrue(visible.intersects(heading.frame), "The saved heading must be visible after continuing.")
        XCTAssertFalse(app.buttons["Edit Document"].exists)
        XCTAssertTrue(app.staticTexts["iCloud reading copy. Edit the original file to make changes."].exists)
        screenshot("Continue Reading from local cloud fixture")
    }

    func testCancelThenDeleteCopiesAndKeepDeletionAfterRelaunch() {
        app.launch()
        manager()
        let first = app.buttons["select-copy-Field Notes.md"]
        let second = app.buttons["select-copy-Reading Plan.md"]
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        tapVisible(first)
        tapVisible(second)
        tapVisible(app.buttons["delete-selected-copies"])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Original files will be kept")).firstMatch.exists)
        screenshot("Cloud copy deletion confirmation")
        app.alerts.buttons["Cancel"].tap()
        reveal(first, searchAbove: true)
        XCTAssertTrue(first.exists)
        reveal(second)
        XCTAssertTrue(second.exists)
        tapVisible(second)
        tapVisible(app.buttons["delete-selected-copies"])
        app.alerts.buttons["Delete Copies"].tap()
        disappears(first)
        reveal(second, searchAbove: true)
        XCTAssertTrue(second.exists)
        screenshot("Reading copy manager after deletion")
        app.terminate()
        app.launch()
        manager()
        reveal(second)
        XCTAssertTrue(second.waitForExistence(timeout: 30))
        XCTAssertFalse(first.exists)
    }

    func testRemovingDownloadKeepsTheCloudCopyReadable() {
        app.launch()
        openNotes()
        XCTAssertTrue(app.webViews.staticTexts["Section 12"].waitForExistence(timeout: 30))
        app.terminate()
        app.launch()
        manager()
        let actions = app.buttons["Actions for Field Notes.md"]
        XCTAssertTrue(actions.waitForExistence(timeout: 30))
        tapVisible(actions)
        app.buttons["Remove Download"].tap()
        let notice = app.staticTexts["Local download removed. The iCloud reading copy is kept."]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        reveal(app.buttons["select-copy-Field Notes.md"])
        XCTAssertTrue(app.buttons["select-copy-Field Notes.md"].exists)
        screenshot("Local download removed, cloud copy kept")
        app.terminate()
        app.launch()
        openNotes()
        XCTAssertTrue(app.webViews.staticTexts["Section 12"].waitForExistence(timeout: 30))
    }

    func testRelativeLinkKeepsReadOnlyAccessAndResumesTheLinkedFile() {
        app.launch()
        openNotes()
        XCTAssertTrue(app.webViews.staticTexts["Section 12"].waitForExistence(timeout: 30))
        app.buttons["Document Outline"].tap()
        app.buttons["Field Notes"].tap()
        let link = app.webViews.links["Reading Plan"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        let text = app.webViews.staticTexts["Keep the original file on the Mac."]
        XCTAssertTrue(text.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Edit Document"].exists)
        app.terminate()
        app.launch()
        openNotes()
        XCTAssertTrue(text.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Edit Document"].exists)
        screenshot("Linked document resumed inside the reading copy")
    }

    func testSendingALocalFolderKeepsTheOriginalEditableAndCreatesAReadingCopy() {
        app.launch()
        tapVisible(app.buttons["Explore Sample Folder"])
        let file = app.descendants(matching: .any)["file:Welcome.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        tapVisible(file)
        XCTAssertTrue(app.webViews.staticTexts["A place for your project files"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Edit Document"].exists)
        app.buttons["Document Actions"].tap()
        app.buttons["Send Folder with Assets"].tap()
        XCTAssertTrue(app.staticTexts["Send this folder to iCloud?"].waitForExistence(timeout: 5))
        app.buttons["Send Folder with Assets"].tap()
        let notice = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Available in Continue Reading")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Edit Document"].exists)
        let linked = app.webViews.links["Field Notes"]
        XCTAssertTrue(linked.waitForExistence(timeout: 10))
        linked.tap()
        XCTAssertTrue(app.webViews.staticTexts["Field Notes"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Edit Document"].exists)
        app.terminate()
        app.launch()
        let copy = app.buttons["continue-Welcome.md"]
        XCTAssertTrue(copy.waitForExistence(timeout: 30))
        copy.tap()
        XCTAssertTrue(app.webViews.staticTexts["Field Notes"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Edit Document"].exists)
        screenshot("Local project folder sent as a read-only iCloud copy")
    }

    private func openNotes() {
        let row = app.buttons["continue-Field Notes.md"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
    }

    private func manager() {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let cloud = app.buttons["icloud-settings"]
        tapVisible(cloud)
        let copies = app.buttons["manage-reading-copies"]
        tapVisible(copies)
        XCTAssertTrue(app.navigationBars["Reading Copies"].waitForExistence(timeout: 10))
    }

    private func disappears(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }

    private func tapVisible(_ element: XCUIElement) {
        reveal(element)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, searchAbove: Bool = false) {
        _ = element.waitForExistence(timeout: 2)
        let list = app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable }) ?? app.collectionViews.firstMatch
        for _ in 0..<16 {
            var frame = list.exists ? list.frame : app.windows.firstMatch.frame
            if let bar = app.navigationBars.allElementsBoundByIndex.last(where: { $0.isHittable }) {
                let top = max(frame.minY, bar.frame.maxY)
                frame = CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top))
            }
            if element.exists && element.isHittable {
                let fixedControl = !list.frame.intersects(element.frame) && app.windows.firstMatch.frame.contains(element.frame)
                if frame.contains(element.frame) || fixedControl { return }
            }
            let above = element.exists ? element.frame.minY < frame.minY : searchAbove
            if above {
                if list.exists { list.swipeDown() } else { app.swipeDown() }
            } else {
                if list.exists { list.swipeUp() } else { app.swipeUp() }
            }
        }
        screenshot("Control outside the visible scroll area")
        XCTFail("The requested control could not be scrolled fully into view.")
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
