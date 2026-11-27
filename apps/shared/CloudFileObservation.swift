import Foundation

final class CloudFileObservation: NSObject, NSFilePresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL
    private let changed: @MainActor @Sendable (URL?) -> Void
    let presentedItemOperationQueue: OperationQueue

    var presentedItemURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }

    init(url: URL, changed: @escaping @MainActor @Sendable (URL?) -> Void) {
        self.url = url
        self.changed = changed
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func presentedItemDidChange() {
        Task { @MainActor [changed] in changed(nil) }
    }

    func presentedItemDidMove(to newURL: URL) {
        lock.lock()
        url = newURL
        lock.unlock()
        Task { @MainActor [changed] in changed(newURL) }
    }

    deinit { NSFileCoordinator.removeFilePresenter(self) }
}
