import Foundation

enum CloudFixture {
    private struct Seed: Codable {
        let items: [CloudItem]
        let reading: CloudReading
    }
    @MainActor
    static func library(storage storageURL: URL, device: String) throws -> CloudLibrary {
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let storage = storageURL.resolvingSymlinksInPath()
        let root = storage.appendingPathComponent("FixtureCloud").resolvingSymlinksInPath()
        let remote = try LocalCloudMetadata(file: root.appendingPathComponent("metadata.json"))
        let connection = CloudConnection(account: "isolated-local-fixture", root: root,
                                         metadata: remote, isCurrent: { true }, testOnly: true)
        let seedFile = storage.appendingPathComponent("fixture-seed.json")
        return CloudLibrary(storage: storage.appendingPathComponent("Device"), deviceName: device) {
            let snapshot = try await remote.snapshot()
            let seed: Seed
            if FileManager.default.fileExists(atPath: seedFile.path) {
                seed = try JSONDecoder().decode(Seed.self, from: Data(contentsOf: seedFile))
            } else if snapshot.items.isEmpty {
                let source = storage.appendingPathComponent("Originals")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                let text = "# Field Notes\n\nA document continued from another device.\n\n[Reading Plan](Reading%20Plan.md)\n\n" +
                    (1...30).map { "## Section \($0)\n\nReading across devices keeps the document and your place together.\n\n" }.joined()
                try Data(text.utf8).write(to: source.appendingPathComponent("Field Notes.md"))
                try Data("# Reading Plan\n\nKeep the original file on the Mac.\n".utf8).write(to: source.appendingPathComponent("Reading Plan.md"))
                let files = CloudFiles(connection: connection, local: storage.appendingPathComponent("Sender"))
                let first = try await files.create(root: source, path: "Field Notes.md", folder: true, device: "Fixture Mac")
                let second = try await files.create(root: source, path: "Reading Plan.md", folder: false, device: "Fixture Mac")
                seed = Seed(items: [first, second], reading: CloudReading(item: first.identity,
                    deviceID: UUID(), deviceName: "Fixture Mac", modified: Date(),
                    position: CloudPosition(heading: "section-12", progress: 0.4)))
                try JSONEncoder().encode(seed).write(to: seedFile, options: .atomic)
            } else { return connection }
            for item in seed.items where !snapshot.items.contains(where: { $0.id == item.id }) {
                try await remote.create(item)
            }
            let firstState = snapshot.items.first(where: { $0.identity == seed.reading.item })?.state
            if !snapshot.readings.contains(where: { $0.id == seed.reading.id }),
               firstState == nil || firstState == .active {
                try await remote.record(seed.reading)
            }
            return connection
        }
    }
}
