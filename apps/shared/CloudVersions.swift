import Foundation

enum CloudVersions {
    static func ensureWritable(_ file: URL) throws {
        let flagged = (try? file.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey]).ubiquitousItemHasUnresolvedConflicts) == true
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []
        guard !flagged, conflicts.isEmpty else {
            throw CloudFailure.message("This document has conflicting iCloud versions. Resolve them in Files or Finder before saving. Your draft is kept.")
        }
    }
}
