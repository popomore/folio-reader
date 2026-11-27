import Foundation

enum CloudFixture {
    @MainActor
    static func library(storage storageURL: URL, device: String) throws -> CloudLibrary {
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let storage = storageURL.resolvingSymlinksInPath()
        let root = storage.appendingPathComponent("FixtureCloud").resolvingSymlinksInPath()
        let remote = try LocalCloudMetadata(file: root.appendingPathComponent("metadata.json"))
        let connection = CloudConnection(account: "isolated-local-fixture", root: root,
                                         metadata: remote, isCurrent: { true }, testOnly: true)
        return CloudLibrary(storage: storage.appendingPathComponent("Device"), deviceName: device) {
            if try await remote.snapshot().items.isEmpty {
                let source = storage.appendingPathComponent("Originals")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                let text = "# Field Notes\n\nA document continued from another device.\n\n[Reading Plan](Reading%20Plan.md)\n\n" +
                    (1...30).map { "## Section \($0)\n\nReading across devices keeps the document and your place together.\n\n" }.joined()
                try Data(text.utf8).write(to: source.appendingPathComponent("Field Notes.md"))
                try Data("# Reading Plan\n\nKeep the original file on the Mac.\n".utf8).write(to: source.appendingPathComponent("Reading Plan.md"))
                let files = CloudFiles(connection: connection, local: storage.appendingPathComponent("Sender"))
                let first = try await files.create(root: source, path: "Field Notes.md", folder: true, device: "Fixture Mac")
                let second = try await files.create(root: source, path: "Reading Plan.md", folder: false, device: "Fixture Mac")
                try await remote.create(first)
                try await remote.create(second)
                try await remote.record(CloudReading(item: first.identity, deviceID: UUID(), deviceName: "Fixture Mac",
                    modified: Date(), position: CloudPosition(heading: "section-12", progress: 0.4)))
            }
            return connection
        }
    }
}
