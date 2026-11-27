import Foundation
import UIKit
import XCTest
@testable import Folio

@MainActor
final class CloudObservationTests: XCTestCase {
    private func registered(_ observer: CloudFileObservation) -> Bool {
        NSFileCoordinator.filePresenters.contains { ($0 as AnyObject) === observer }
    }

    func testStopUnregistersAndInvalidatesQueuedCallbacks() async {
        var changes = 0
        let observer = CloudFileObservation(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)) { _ in changes += 1 }
        XCTAssertTrue(registered(observer))
        observer.presentedItemDidChange()
        observer.stop()
        observer.stop()
        await Task.yield()
        XCTAssertFalse(registered(observer))
        XCTAssertEqual(changes, 0)
    }

    func testBackgroundSuspendsAndForegroundRestoresAnOwnedPresenter() {
        let observer = CloudFileObservation(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)) { _ in }
        defer { observer.stop() }
        XCTAssertTrue(registered(observer))
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(registered(observer))
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertTrue(registered(observer))
    }

    func testClosedPresenterDoesNotRegisterAgainOnForeground() {
        let observer = CloudFileObservation(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)) { _ in }
        observer.stop()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertFalse(registered(observer))
    }
}
