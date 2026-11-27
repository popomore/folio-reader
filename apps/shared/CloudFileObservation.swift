import Foundation
#if os(iOS)
import UIKit
#endif

final class CloudFileObservation: NSObject, NSFilePresenter, @unchecked Sendable {
    private let lock = NSLock()
    private let registrationLock = NSLock()
    private var url: URL
    private var registered = false
    private var stopped = false
    private var generation = UUID()
    private var notifications: [any NSObjectProtocol] = []
    private let changed: @MainActor @Sendable (URL?) -> Void
    let presentedItemOperationQueue: OperationQueue

    var presentedItemURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }

    @MainActor
    init(url: URL, changed: @escaping @MainActor @Sendable (URL?) -> Void) {
        self.url = url
        self.changed = changed
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        super.init()
        #if os(iOS)
        notifications = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main) { [weak self] _ in self?.setRegistered(false) },
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main) { [weak self] _ in self?.setRegistered(true) },
        ]
        setRegistered(UIApplication.shared.applicationState != .background)
        #else
        setRegistered(true)
        #endif
    }

    func stop() {
        setRegistered(false, permanently: true)
        lock.lock()
        let tokens = notifications
        notifications = []
        lock.unlock()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    private func setRegistered(_ enabled: Bool, permanently: Bool = false) {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        lock.lock()
        if permanently { stopped = true }
        let next = enabled && !stopped
        let previous = registered
        registered = next
        generation = UUID()
        lock.unlock()
        if previous == next { return }
        if next { NSFileCoordinator.addFilePresenter(self) }
        else {
            presentedItemOperationQueue.cancelAllOperations()
            NSFileCoordinator.removeFilePresenter(self)
        }
    }

    func presentedItemDidChange() { notify(nil) }
    func presentedItemDidMove(to newURL: URL) { notify(newURL) }

    private func notify(_ moved: URL?) {
        lock.lock()
        guard registered, !stopped else { lock.unlock(); return }
        if let moved { url = moved }
        let token = generation
        lock.unlock()
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.changed(moved)
        }
    }

    private func isCurrent(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registered && !stopped && generation == token
    }

    deinit { stop() }
}
