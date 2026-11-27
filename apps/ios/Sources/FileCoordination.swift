import Foundation

protocol FileCoordinating: Sendable {
    func coordinate<T>(at url: URL, writing: Bool, _ operation: (URL) throws -> T) throws -> T
}

struct SystemFileCoordination: FileCoordinating {
    func coordinate<T>(at url: URL, writing: Bool, _ operation: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { coordinatedURL in result = Result { try operation(coordinatedURL) } }
        let coordinator = NSFileCoordinator()
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError,
                                   byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor)
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
