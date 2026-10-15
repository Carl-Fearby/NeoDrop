import Foundation
import NeoDropCore

/// What the menu and Settings show for one two-way folder.
///
/// The link is kept alongside the result so a row can render itself without looking anything up,
/// and so a folder that has never synced still has somewhere to appear.
struct VaultStatus: Sendable {
    var link: VaultLink
    var status: ReplicaStatus = .unknown
    var lastSync: Date?
    var summary: VaultSyncSummary?

    var statusLine: String { status.menuDescription }

    var lastSyncLine: String {
        guard let lastSync else { return "never synced" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "synced \(formatter.localizedString(for: lastSync, relativeTo: Date()))"
    }

    /// The counts a person actually wants: what moved in each direction, and anything that needs
    /// their eyes — a conflict, a refusal, a share copy that had to be put back.
    var detailLine: String {
        var parts: [String] = []
        if let summary {
            parts.append("\(summary.uploaded) sent")
            parts.append("\(summary.downloaded) received")
            if summary.remoteDeletionsApplied > 0 { parts.append("\(summary.remoteDeletionsApplied) deleted here") }
            if summary.localDeletionsPublished > 0 { parts.append("\(summary.localDeletionsPublished) deleted everywhere") }
            if !summary.undeleted.isEmpty { parts.append("\(summary.undeleted.count) restored everywhere") }
            if !summary.conflicts.isEmpty { parts.append("\(summary.conflicts.count) conflict(s)") }
            if summary.versionsRetained > 0 { parts.append("\(summary.versionsRetained) version(s) kept") }
            if !summary.repairs.isEmpty { parts.append("\(summary.repairs.count) repaired") }
        }
        if let message = summary?.errors.first {
            parts.append(message)
        }
        return parts.isEmpty ? "waiting for the first sync" : parts.joined(separator: " · ")
    }
}
