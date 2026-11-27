import Foundation

final class CloudDocumentsObserver: @unchecked Sendable {
    private let query = NSMetadataQuery()
    private var observers: [any NSObjectProtocol] = []

    @MainActor
    init(root: URL, changed: @escaping @MainActor @Sendable () -> Void) {
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(value: true)
        query.notificationBatchingInterval = 1
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { _ in
                MainActor.assumeIsolated { changed() }
            })
        }
        query.start()
    }

    @MainActor
    func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    deinit {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
