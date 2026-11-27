import Foundation
import Observation

@MainActor @Observable
final class DocumentSession {
    let folder: SavedFolder
    let path: String
    private let drafts: DraftStore
    private var draftTask: Task<Void, Never>?
    private var original = ""
    private(set) var revision: String?
    private(set) var opened: OpenedFile?
    private(set) var loading = true
    private(set) var saving = false
    var error: String?
    var draft = ""
    var recovered = false
    var editing = false
    var hasChanges: Bool { draft != original }
    var canEdit: Bool { revision != nil }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    private var key: String { "\(folder.id)/\(path)" }

    init(folder: SavedFolder, path: String, storage: URL) {
        self.folder = folder
        self.path = path
        drafts = DraftStore(directory: storage.appendingPathComponent("Drafts"))
    }

    func load() async {
        loading = true
        error = nil
        do {
            let opened = try await WorkspaceIO.open(folder, path: path)
            self.opened = opened
            revision = opened.document.revision
            original = opened.document.source ?? ""
            draft = original
            if let saved = try await drafts.read(key), opened.document.revision != nil {
                if saved.source == original {
                    try await drafts.remove(key)
                } else {
                    draft = saved.source
                    revision = saved.revision
                    recovered = true
                }
            }
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    func draftChanged() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await self?.persistDraft()
        }
    }

    func persistDraft() async {
        guard hasChanges, let revision else { return }
        do { try await drafts.write(DraftRecord(source: draft, revision: revision), key: key) }
        catch { self.error = "Your recovery draft could not be saved: \(error.localizedDescription)" }
    }

    func save() async -> Bool {
        guard let revision, !saving else { return false }
        saving = true
        error = nil
        draftTask?.cancel()
        await draftTask?.value
        let source = draft
        do {
            self.revision = try await WorkspaceIO.save(folder, path: path, revision: revision, source: source)
            original = source
            recovered = false
        } catch {
            self.error = error.localizedDescription
            await persistDraft()
            saving = false
            return false
        }
        do { try await drafts.remove(key) }
        catch { self.error = "The file was saved, but its recovery copy could not be removed: \(error.localizedDescription)" }
        do { opened = try await WorkspaceIO.open(folder, path: path) }
        catch { self.error = "The file was saved, but its preview could not be reloaded: \(error.localizedDescription)" }
        saving = false
        return true
    }

    func discard() async {
        draftTask?.cancel()
        await draftTask?.value
        do {
            try await drafts.remove(key)
            recovered = false
            draft = original
            editing = false
            await load()
        } catch { self.error = error.localizedDescription }
    }
}
