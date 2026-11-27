import Foundation

enum CloudReaderAccess {
    static func perform<T>(root: URL, path: String, writing: Bool, presenter: CloudFileObservation? = nil,
                           body: (String) throws -> T) throws -> T {
        let target = root.appendingPathComponent(path)
        guard FileManager.default.isUbiquitousItem(at: target) else { return try body(path) }
        var error: NSError?
        var result: Result<T, any Error>?
        let accessor: (URL) -> Void = { actual in
            result = Result {
                let file = try CloudPaths.contained(actual, in: root)
                if writing { try CloudVersions.ensureWritable(file) }
                let relative = file.pathComponents.dropFirst(root.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
                return try body(CloudPaths.relative(relative))
            }
        }
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        if writing { coordinator.coordinate(writingItemAt: target, options: .forReplacing, error: &error, byAccessor: accessor) }
        else { coordinator.coordinate(readingItemAt: target, options: .withoutChanges, error: &error, byAccessor: accessor) }
        if let error { throw error }
        guard let result else { throw CloudFailure.waitingForFile }
        return try result.get()
    }
}
