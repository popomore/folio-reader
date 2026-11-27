import XCTest
import UIKit

@MainActor
final class ReaderTests: XCTestCase {
    private var app: XCUIApplication!
    private let documentTimeout: TimeInterval = 60

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["FOLIO_UI_TEST_LIBRARY"] = UUID().uuidString
    }

    func testBrowseMarkdownOutlineAndRelativeLink() {
        sample()
        tapFile("Welcome.md")
        let heading = app.webViews.staticTexts["A place for your project files"]
        XCTAssertTrue(heading.waitForExistence(timeout: documentTimeout))
        screenshot("Markdown reader")
        app.buttons["Document Outline"].tap()
        XCTAssertTrue(app.navigationBars["Contents"].waitForExistence(timeout: 5))
        app.buttons["Your next thought"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Your next thought"].waitForExistence(timeout: documentTimeout))
        screenshot("Document outline navigation")
        relaunchSample()
        tapFile("Welcome.md")
        let link = app.webViews.links["Field Notes"]
        XCTAssertTrue(link.waitForExistence(timeout: documentTimeout))
        link.tap()
        XCTAssertTrue(app.webViews.staticTexts["Field Notes"].waitForExistence(timeout: documentTimeout))
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
            XCTAssertTrue(app.webViews.staticTexts["A place for your project files"].waitForExistence(timeout: documentTimeout))
        }
    }

    func testEditSaveAndReopen() {
        sample()
        notes()
        XCTAssertTrue(app.buttons["Edit Document"].waitForExistence(timeout: 10))
        app.buttons["Edit Document"].tap()
        let editor = app.textViews["document-source"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("\nSaved from the iOS UI test.\n")
        app.buttons["Save"].tap()
        XCTAssertTrue(preview(containing: "Saved from the iOS UI test.").waitForExistence(timeout: documentTimeout))
        relaunchSample()
        notes()
        XCTAssertTrue(preview(containing: "Saved from the iOS UI test.").waitForExistence(timeout: documentTimeout))
        screenshot("Saved document after relaunch")
    }

    func testCancelProtectsAnUnsavedDraft() {
        sample()
        notes()
        app.buttons["Edit Document"].tap()
        let editor = app.textViews["document-source"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("\nDo not save this draft.\n")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 5))
        app.buttons["Keep Editing"].tap()
        XCTAssertTrue((editor.value as? String)?.contains("Do not save this draft.") == true)
        app.buttons["Cancel"].tap()
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["Edit Document"].waitForExistence(timeout: 10))
        app.buttons["Edit Document"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String)?.contains("Do not save this draft.") == true)
    }

    func testTablePDFAndImagePreviews() {
        sample()
        tapFile("Data")
        tapFile("Data/reading-list.csv")
        XCTAssertTrue(app.webViews.staticTexts["In progress"].waitForExistence(timeout: documentTimeout))
        screenshot("CSV table")
        relaunchSample()
        tapFile("Reference.pdf")
        XCTAssertTrue(app.descendants(matching: .any)["pdf-preview"].waitForExistence(timeout: 15))
        screenshot("PDF reader")
        relaunchSample()
        tapFile("Images")
        tapFile("Images/folio.png")
        XCTAssertTrue(app.images["folio.png"].waitForExistence(timeout: 15))
        screenshot("Image reader")
    }

    func testFolderSearchAndSystemPickerCancellation() {
        sample()
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Welcome")
        XCTAssertTrue(file("Welcome.md").waitForExistence(timeout: 5))
        XCTAssertFalse(file("Reference.pdf").exists)
        app.terminate()
        app.launch()
        app.buttons["Add"].tap()
        app.buttons["Add Folder"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        screenshot("System folder picker")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Explore Sample Folder"].waitForExistence(timeout: 5))
    }

    func testReadingSettingsAndDarkAppearance() {
        app.launch()
        app.buttons["Reading Settings"].tap()
        XCTAssertTrue(app.navigationBars["Reading Settings"].waitForExistence(timeout: 5))
        app.buttons["appearance-picker"].tap()
        app.buttons["Dark"].tap()
        let serif = app.switches["Serif Font"]
        reveal(serif)
        XCTAssertEqual(serif.value as? String, "0")
        serif.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(serif.value as? String, "1")
        screenshot("Dark reading settings")
        app.buttons["Done"].tap()
        tap(app.buttons["Explore Sample Folder"])
        tapFile("Welcome.md")
        XCTAssertTrue(app.webViews.staticTexts["A place for your project files"].waitForExistence(timeout: documentTimeout))
        screenshot("Dark reader")
    }

    private func sample() {
        app.launch()
        tap(app.buttons["Explore Sample Folder"])
        XCTAssertTrue(app.navigationBars["Sample Project"].waitForExistence(timeout: 10))
    }

    private func relaunchSample() { app.terminate(); sample() }

    private func file(_ path: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "file:\(path)").firstMatch
    }

    private func tap(_ element: XCUIElement) {
        reveal(element)
        element.tap()
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 {
            let list = app.collectionViews.firstMatch
            let viewport = list.exists ? list.frame.intersection(app.frame) : app.frame
            // A partially visible row can be hittable while its tap point is offscreen.
            if element.exists && element.isHittable && viewport.contains(element.frame) { break }
            if element.exists && element.frame.minY < viewport.minY { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    private func tapFile(_ path: String) { tap(file(path)) }

    private func notes() {
        tapFile("Notes")
        tapFile("Notes/Field Notes.md")
    }

    private func preview(containing text: String) -> XCUIElement {
        app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
