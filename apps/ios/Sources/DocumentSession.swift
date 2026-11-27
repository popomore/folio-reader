import Foundation
import Observation

@MainActor @Observable
final class DocumentSession {
    let folder: SavedFolder
    let path: String
    let readOnly: Bool
    var readingPosition = CloudPosition()
    var sharedItem: CloudItem?
    let protectionOwner = UUID()
    private let drafts: DraftStore
    private let draftOwner = UUID()
    private let readFile: @Sendable (SavedFolder, String) async throws -> OpenedFile
    private var draftTask: Task<Void, Never>?
    private var loadInFlight = false
    @ObservationIgnored private var documentObserver: CloudFileObservation?
    private var observationWanted = false
    private var observationChangedDuringLoad = false
    private var original = ""
    private var lastRecoverySource = ""
    private var draftVersion = 0
    private(set) var revision: String?
    private(set) var opened: OpenedFile?
    private(set) var loading = true
    private(set) var saving = false
    var error: String?
    var draft = "" {
        didSet { if draft != oldValue { draftVersion &+= 1 } }
    }
    var recovered = false
    var editing = false
    var hasChanges: Bool { draft != original }
    var canEdit: Bool { !readOnly && revision != nil && !loading && !saving }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    private var key: String { "\(folder.id)/\(path)" }

    init(folder: SavedFolder, path: String, storage: URL, readOnly: Bool = false,
         readFile: @escaping @Sendable (SavedFolder, String) async throws -> OpenedFile = {
             try await WorkspaceIO.open($0, path: $1)
         }) {
        self.folder = folder
        self.path = path
        self.readOnly = readOnly
        self.readFile = readFile
        drafts = DraftStore.shared(directory: storage.appendingPathComponent("Drafts"))
    }

    func load() async {
        guard !loadInFlight, !editing, !saving else { return }
        documentObserver?.stop()
        documentObserver = nil
        loadInFlight = true
        loading = true
        defer {
            loadInFlight = false
            loading = false
            reconcilePendingObservation()
        }
        error = nil
        do {
            var opened = try await readFile(folder, path)
            self.opened = opened
            installObservation()
            if documentObserver != nil {
                // Read again while registered so a write before registration cannot be missed.
                opened = try await readFile(folder, path)
                self.opened = opened
            }
            revision = opened.document.revision
            original = opened.document.source ?? ""
            draft = original
            lastRecoverySource = original
            recovered = false
            if opened.document.revision != nil, let saved = try await drafts.recover(key, owner: draftOwner) {
                if saved.source == original {
                    try await drafts.remove(key, owner: draftOwner)
                } else {
                    draft = saved.source
                    lastRecoverySource = saved.source
                    revision = saved.revision
                    recovered = true
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func beginEditing() {
        if canEdit { editing = true }
    }

    func loadIfNeeded() async {
        if opened == nil { await load() }
    }

    func draftChanged() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await self?.persistDraft()
        }
    }

    func persistDraft() async {
        guard let revision, !loading else { return }
        let record = DraftRecord(source: draft, revision: revision, owner: draftOwner)
        let version = draftVersion
        do {
            if hasChanges {
                let owner = record.source == lastRecoverySource ? draftOwner : nil
                try await drafts.write(record, key: key, onlyIfOwnedBy: owner)
            } else { try await drafts.remove(key, owner: draftOwner) }
            if version == draftVersion { lastRecoverySource = record.source }
        } catch { self.error = "Your recovery draft could not be updated: \(error.localizedDescription)" }
    }

    func stopObservation() {
        observationWanted = false
        documentObserver?.stop()
        documentObserver = nil
    }

    func resumeObservation() async {
        let resumed = !observationWanted && opened != nil
        observationWanted = true
        installObservation()
        if resumed { await revalidateObservedFile() }
    }

    func revalidateObservedFile() async {
        guard observationWanted, let opened else { return }
        guard !loadInFlight, !saving else { observationChangedDuringLoad = true; return }
        if editing || hasChanges || recovered {
            do {
                let current = try await readFile(folder, path)
                if current.document.revision != opened.document.revision {
                    error = "This document changed elsewhere. Your unsaved draft is kept."
                }
            } catch { self.error = error.localizedDescription }
        } else { await load() }
    }

    private func reconcilePendingObservation() {
        guard observationChangedDuringLoad else { return }
        observationChangedDuringLoad = false
        if observationWanted { Task { await self.revalidateObservedFile() } }
    }

    private func installObservation() {
        guard observationWanted, documentObserver == nil, let opened else { return }
        let file = opened.access.root.appendingPathComponent(path)
        guard FileManager.default.isUbiquitousItem(at: file) else { return }
        documentObserver = CloudFileObservation(url: file) { [weak self] moved in
            guard let self else { return }
            if self.loading || self.saving { self.observationChangedDuringLoad = true; return }
            if moved != nil { self.error = "This document moved. Open it again from its folder." }
            else { Task { await self.revalidateObservedFile() } }
        }
    }

    deinit { documentObserver?.stop() }

    func save() async -> Bool {
        guard !readOnly else { return false }
        guard let revision, !loading, !saving else { return false }
        saving = true
        defer { saving = false; reconcilePendingObservation() }
        error = nil
        draftTask?.cancel()
        await draftTask?.value
        let source = draft
        do {
            self.revision = try await WorkspaceIO.save(folder, path: path, revision: revision, source: source)
            original = source
            lastRecoverySource = source
            recovered = false
        } catch {
            self.error = error.localizedDescription
            await persistDraft()
            return false
        }
        do { try await drafts.remove(key, owner: draftOwner) }
        catch { self.error = "The file was saved, but its recovery copy could not be removed: \(error.localizedDescription)" }
        do { opened = try await WorkspaceIO.open(folder, path: path) }
        catch { self.error = "The file was saved, but its preview could not be reloaded: \(error.localizedDescription)" }
        return true
    }

    func discard() async {
        draftTask?.cancel()
        await draftTask?.value
        do {
            try await drafts.remove(key, owner: draftOwner)
            recovered = false
            draft = original
            editing = false
            await load()
        } catch { self.error = error.localizedDescription }
    }
}
