import Foundation
import Observation

@MainActor @Observable
final class FolderListing {
    private var generation = 0
    private(set) var entries: [Entry] = []
    private(set) var loading = true
    private(set) var failure: String?
    private let read: @Sendable (SavedFolder, String) async throws -> [Entry]

    init(read: @escaping @Sendable (SavedFolder, String) async throws -> [Entry] = {
        try await WorkspaceIO.list($0, path: $1)
    }) {
        self.read = read
    }

    func reload(_ folder: SavedFolder, path: String) async {
        generation &+= 1
        let request = generation
        loading = entries.isEmpty
        failure = nil
        do {
            let entries = try await read(folder, path)
            guard request == generation else { return }
            self.entries = entries
        } catch {
            guard request == generation else { return }
            failure = error.localizedDescription
        }
        loading = false
    }
}
