import Foundation

actor FixtureMetadata: CloudMetadata {
    func snapshot() -> CloudSnapshot { CloudSnapshot() }
    func create(_ item: CloudItem) {}
    func record(_ reading: CloudReading) {}
    func beginDeletion(_ request: CloudDeletion) throws -> CloudItem { throw CloudFailure.stale }
    func finishDeletion(_ request: CloudDeletion) {}
}

@main struct Check {
    static func main() async throws {
        let directory = URL(fileURLWithPath: "/tmp/FolioCloudFileCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let original = Data("# Mac fixture\n".utf8)
        try original.write(to: source.appendingPathComponent("Notes.md"))
        let connection = CloudConnection(account: "fixture", root: base.appendingPathComponent("Cloud"),
            metadata: FixtureMetadata(), isCurrent: { true }, testOnly: true)
        let files = CloudFiles(connection: connection, local: base.appendingPathComponent("Cache"))
        let item = try await files.create(root: source, path: "Notes.md", folder: true, device: "Mac")
        let opened = try await files.open(item)
        guard try Data(contentsOf: opened.root.appendingPathComponent(item.path)) == original else {
            fatalError("The Mac reading copy did not open its original bytes.")
        }
        var deleting = item
        deleting.state = .deleting
        try await files.remove(deleting)
        guard try Data(contentsOf: source.appendingPathComponent(item.path)) == original else {
            fatalError("Cleanup changed the original fixture.")
        }
        print("Mac copy, open, and delete preserved original bytes.")
    }
}
