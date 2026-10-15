import Foundation

/// What NeoDrop knows about one file, asked from Finder.
///
/// The question a person actually has about a file in a synced folder is "is this safe?", and the
/// only honest answer names every place the file exists and what each copy is held against. That is
/// what this produces: one row per place the file lives (this Mac, each NAS, the vault on the share,
/// a retained copy in the trash), the record NeoDrop has for it there, and the vault's history for
/// the path.
///
/// Deliberate limitation: **nothing here hashes the file.** This runs when somebody clicks a menu
/// item on a 4 GB video, so it compares the size and date that NeoDrop recorded against what is on
/// disk. That distinguishes "matches the record" from "changed since NeoDrop wrote it", which is
/// what the question needs; it cannot distinguish corruption that preserved both size and date —
/// `Verify & Repair` is the tool for that, and the report says so rather than implying more.
public enum FileStatusRole: String, Codable, Sendable {
    /// A protected local folder (the one-way mirror's source).
    case source
    /// The local half of a two-way folder.
    case workingCopy
    /// A one-way destination on the NAS.
    case replica
    /// The shared copy of a two-way folder, on the share.
    case vault
    /// Bytes NeoDrop is deliberately holding after a deletion.
    case retainedCopy

    public var label: String {
        switch self {
        case .source: return "This Mac"
        case .workingCopy: return "This Mac (two-way)"
        case .replica: return "NAS copy"
        case .vault: return "Shared copy"
        case .retainedCopy: return "Retained copy"
        }
    }
}

/// What NeoDrop's own records say about one copy: a manifest entry, a source-index entry, a journal
/// entry, or a deletion record.
public struct RecordedCopy: Codable, Sendable {
    /// `manifest`, `source index`, `journal` or `deletion` — where the record came from.
    public var kind: String
    public var sha256: String
    public var size: Int64
    /// When the record was written (not when the file was).
    public var at: Date
    public var verifiedAt: Date?
    /// The machine that published this version, in the vault's journal.
    public var machineName: String?
    /// Size and date on disk agree with the record. Not a digest check — see the type's note.
    public var matches: Bool
    /// When a retained copy stops being recoverable.
    public var expiresAt: Date?

    public init(kind: String, sha256: String, size: Int64, at: Date,
                verifiedAt: Date? = nil, machineName: String? = nil,
                matches: Bool = false, expiresAt: Date? = nil) {
        self.kind = kind
        self.sha256 = sha256
        self.size = size
        self.at = at
        self.verifiedAt = verifiedAt
        self.machineName = machineName
        self.matches = matches
        self.expiresAt = expiresAt
    }
}

/// One place the file exists (or should). `present` is what is on disk right now; `recorded` is
/// what NeoDrop believes should be there — the two disagreeing is the interesting case.
public struct FileLocation: Codable, Sendable, Identifiable {
    public var role: FileStatusRole
    /// The name of the root as the user sees it in Settings: "Source", "NAS1", the vault's name.
    public var name: String
    public var rootPath: String
    /// Where the file is (or would be) inside that root.
    public var absolutePath: String
    public var present: Bool
    public var size: Int64?
    public var modified: Date?
    public var recorded: RecordedCopy?
    /// One sentence about this location, already phrased for a person.
    public var note: String

    public var id: String { "\(role.rawValue):\(absolutePath)" }

    public init(role: FileStatusRole, name: String, rootPath: String, absolutePath: String,
                present: Bool, size: Int64? = nil, modified: Date? = nil,
                recorded: RecordedCopy? = nil, note: String) {
        self.role = role
        self.name = name
        self.rootPath = rootPath
        self.absolutePath = absolutePath
        self.present = present
        self.size = size
        self.modified = modified
        self.recorded = recorded
        self.note = note
    }
}

/// One thing that happened to the path, from a vault's journal.
public struct FileHistoryEntry: Codable, Sendable, Identifiable {
    public var at: Date
    /// `create`, `update` or `delete`.
    public var kind: String
    public var machineName: String
    public var size: Int64
    public var sha256: String

    public var id: String { "\(at.timeIntervalSince1970)-\(sha256)" }

    public init(at: Date, kind: String, machineName: String, size: Int64, sha256: String) {
        self.at = at
        self.kind = kind
        self.machineName = machineName
        self.size = size
        self.sha256 = sha256
    }
}

public struct FileStatusReport: Codable, Sendable {
    public var path: String
    /// The path relative to the first NeoDrop folder that contains it, for display and matching.
    public var relativePath: String
    /// `file`, `folder` or `missing`.
    public var kind: String
    /// The verdict, in one sentence.
    public var summary: String
    public var locations: [FileLocation]
    public var history: [FileHistoryEntry]
    public var generatedAt: Date
    /// Whether any configured NeoDrop folder contains this path at all.
    public var covered: Bool

    public init(path: String, relativePath: String, kind: String, summary: String,
                locations: [FileLocation], history: [FileHistoryEntry],
                generatedAt: Date, covered: Bool) {
        self.path = path
        self.relativePath = relativePath
        self.kind = kind
        self.summary = summary
        self.locations = locations
        self.history = history
        self.generatedAt = generatedAt
        self.covered = covered
    }

    /// Every copy NeoDrop would count as a place the bytes actually are.
    public var protectedCopies: Int {
        locations.filter { $0.present && $0.role != .retainedCopy }.count
    }

    public var hasRetainedCopy: Bool {
        locations.contains { $0.role == .retainedCopy && $0.present }
    }
}

/// Builds a `FileStatusReport` from the configuration and the state on disk.
///
/// Pure reading: it opens manifests, the source index, the delete records and the vault journals,
/// and it touches the file system only with `fileExists` and a stat. Nothing is written and nothing
/// is synced, so it is safe to run against a share that is slow or half-mounted.
public struct FileStatusQuery: Sendable {
    public let paths: StorePaths
    public let config: AppConfig

    public init(paths: StorePaths, config: AppConfig) {
        self.paths = paths
        self.config = config
    }

    /// Longest history shown; the journal is append-only and a file can have hundreds of entries.
    public static let historyLimit = 25

    public func report(for url: URL, now: Date = Date()) -> FileStatusReport {
        let target = url.standardizedFileURL
        let targetPath = PathIdentity.canonical(target)

        var locations: [FileLocation] = []
        // Every spelling of this file's relative path, so a record written for the same logical file
        // matches no matter which root the question was asked from.
        var candidateRels: Set<String> = []

        let sourceIndex = SourceIndexStore(paths: paths).load()
        let isDirectory = FileMeta.isDirectory(target)
        let exists = FileManager.default.fileExists(atPath: target.path)
        let onDiskSize = isDirectory ? nil : FileMeta.size(ofFileAt: target)
        let onDiskMtime = isDirectory ? nil : FileMeta.modificationDate(ofFileAt: target)

        // MARK: Sources (and the local half of each two-way folder — same shape, different name)

        for source in config.sources {
            guard let rel = relativeOrRoot(targetPath, under: source.path) else { continue }
            if !rel.isEmpty { candidateRels.insert(rel) }
            let entry = rel.isEmpty ? nil : sourceIndex.entries["\(source.id.uuidString)/\(rel)"]
            locations.append(FileLocation(
                role: .source,
                name: source.displayName,
                rootPath: source.path,
                absolutePath: target.path,
                present: exists,
                size: onDiskSize,
                modified: onDiskMtime,
                recorded: entry.map {
                    RecordedCopy(kind: "source index", sha256: $0.sha256, size: $0.size, at: $0.writtenAt,
                                 verifiedAt: $0.verifiedAt,
                                 matches: Self.matches(recordedSize: $0.size, recordedMtime: $0.mtime,
                                                       onDiskSize: onDiskSize, onDiskMtime: onDiskMtime))
                },
                note: rel.isEmpty
                    ? "This is the protected folder itself; every file below it is mirrored."
                    : (entry == nil
                       ? "In “\(source.displayName)”; NeoDrop has no digest recorded for it yet."
                       : "In “\(source.displayName)”; NeoDrop has this file's digest recorded.")
            ))
        }

        // MARK: Destinations

        // A destination stores the file under the source's namespace when more than one source is
        // configured, so the relative path to look up is not simply the one from this Mac.
        let namespacedRels = config.sources.compactMap { source -> String? in
            guard let rel = relative(targetPath, under: source.path) else { return nil }
            return Scanner.namespaced(relativePath: rel, source: source, sourceCount: config.sources.count)
        }

        for replica in config.replicas {
            // The destination folder itself: there is no single relative path to look up, and the
            // useful answer is whether the folder is a destination at all.
            if relativeOrRoot(targetPath, under: replica.path) == "" {
                locations.append(FileLocation(
                    role: .replica,
                    name: replica.displayName,
                    rootPath: replica.path,
                    absolutePath: target.path,
                    present: true,
                    note: "This is the destination folder itself; everything below it mirrors this Mac."
                ))
                continue
            }
            var rels = Set(namespacedRels)
            if let own = relative(targetPath, under: replica.path) { rels.insert(own) }
            guard !rels.isEmpty else { continue }

            let manifest = ManifestStore(paths: paths).load(replicaID: replica.id)
            for rel in rels.sorted() {
                candidateRels.insert(rel)
                let destination = replica.url.appendingPathComponent(rel)
                let present = FileManager.default.fileExists(atPath: destination.path)
                let entry = manifest.entries[rel]
                let size = FileMeta.size(ofFileAt: destination)
                let modified = FileMeta.modificationDate(ofFileAt: destination)
                let corrupt = manifest.corruptPaths.contains(rel)

                let verdict: String
                if corrupt {
                    verdict = "⚠︎ NeoDrop recorded this copy as damaged on the last verify."
                } else if !present {
                    verdict = entry == nil
                        ? "Not here, and NeoDrop never wrote it here."
                        : "NeoDrop wrote it here but it is gone from the share now."
                } else if let entry, !Self.matches(recordedSize: entry.size, recordedMtime: entry.mtime,
                                                   onDiskSize: size, onDiskMtime: modified) {
                    verdict = "⚠︎ This copy no longer matches what NeoDrop recorded (changed on the share, or partial)."
                } else if entry == nil {
                    // Two ways to have no record of a file that is sitting there: a sync found it and
                    // refused to replace it (recorded, so this is the answer that says what to do next),
                    // or nothing has been synced to this path yet.
                    verdict = manifest.foreignPaths.contains(rel)
                        ? "Not NeoDrop's file: something else is at this path, so the mirror left it alone rather than replace it. Move or delete it on the share and the next sync will mirror here."
                        : "Present, but NeoDrop has no record of writing it — it did not come from this Mac."
                } else {
                    verdict = "A complete copy of what NeoDrop wrote."
                }

                locations.append(FileLocation(
                    role: .replica,
                    name: replica.displayName,
                    rootPath: replica.path,
                    absolutePath: destination.path,
                    present: present,
                    size: size,
                    modified: modified,
                    recorded: entry.map {
                        RecordedCopy(kind: "manifest", sha256: $0.sha256, size: $0.size, at: $0.writtenAt,
                                     verifiedAt: $0.verifiedAt,
                                     matches: Self.matches(recordedSize: $0.size, recordedMtime: $0.mtime,
                                                           onDiskSize: size, onDiskMtime: modified))
                    },
                    note: verdict
                ))
            }
        }

        // MARK: The vault on the share, and what it is holding

        for link in config.vaults {
            let shareRoot = URL(fileURLWithPath: link.vaultPath)
            let localRoot = URL(fileURLWithPath: link.localPath)
            let shareRel = relativeOrRoot(targetPath, under: link.vaultPath)
            let localRel = relativeOrRoot(targetPath, under: link.localPath)
            guard shareRel != nil || localRel != nil else { continue }

            let store = VaultStore(root: link.vaultURL)
            let entries = store.loadEntries().entries
            let state = store.state(from: entries)
            // Whichever half was asked about, the same relative path names the file in the other,
            // which is what lets one row point at the share and one at this Mac's copy.
            let rel = [shareRel, localRel].compactMap { $0 }.first { !$0.isEmpty }
            if let rel { candidateRels.insert(rel) }

            // The two halves of a pair hold the same tree, so a question about one is a question
            // about both: the path is mapped across and each half is described on its own terms.
            if let shareRel = shareRel ?? localRel {
                let destination = shareRel.isEmpty ? shareRoot : store.fileURL(for: shareRel)
                let present = FileManager.default.fileExists(atPath: destination.path)
                let size = FileMeta.size(ofFileAt: destination)
                let modified = FileMeta.modificationDate(ofFileAt: destination)
                let live = rel.flatMap { state.files[VaultPath.key($0)] }
                let tombstone = rel.flatMap { state.tombstones[VaultPath.key($0)] }
                let newest = live ?? tombstone

                let note: String
                if shareRel.isEmpty {
                    note = "This is the shared copy of the two-way folder, on the share."
                } else if let tombstone {
                    note = present
                        ? "The vault's journal says \(tombstone.machineName) deleted this on \(Self.day(tombstone.at)), but a file is still here."
                        : "Deleted by \(tombstone.machineName) on \(Self.day(tombstone.at)); every machine that syncs will remove it too."
                } else if let live {
                    note = "Published by \(live.machineName) on \(Self.day(live.at))."
                } else {
                    note = present
                        ? "Here on the share, but no machine has published it — it was put there by hand."
                        : "No machine has published this path to the vault."
                }

                locations.append(FileLocation(
                    role: .vault,
                    name: link.displayName,
                    rootPath: link.vaultPath,
                    absolutePath: destination.path,
                    present: present,
                    size: size,
                    modified: modified,
                    recorded: newest.map {
                        RecordedCopy(kind: "journal",
                                     sha256: live?.sha256 ?? $0.sha256,
                                     size: live?.size ?? $0.size,
                                     at: $0.at,
                                     machineName: $0.machineName,
                                     matches: Self.matches(recordedSize: live?.size ?? 0,
                                                           recordedMtime: $0.at,
                                                           onDiskSize: live == nil ? nil : size,
                                                           onDiskMtime: live == nil ? nil : modified))
                    },
                    note: note
                ))

                // The vault keeps the previous content of everything it replaces, content-addressed.
                if let sha = newest?.sha256, !sha.isEmpty, store.hasVersion(sha256: sha) {
                    let version = store.versionURL(sha256: sha)
                    locations.append(FileLocation(
                        role: .retainedCopy,
                        name: "\(link.displayName) — retained version",
                        rootPath: store.versionsURL.path,
                        absolutePath: version.path,
                        present: true,
                        size: FileMeta.size(ofFileAt: version),
                        recorded: RecordedCopy(kind: "journal", sha256: sha, size: newest?.size ?? 0,
                                               at: newest?.at ?? now,
                                               machineName: newest?.machineName),
                        note: "The vault is holding these bytes for a machine that still needs them."
                    ))
                }
            }

            // This Mac's half. Asking about the share path still names the local copy when there is
            // one — that is the answer to "which of my Macs has this?" — but a local row for a file
            // that is not here is only added when that is where the question came from.
            let askedAboutThisMac = localRel != nil
            if let localRel = localRel ?? shareRel {
                let localURL = localRel.isEmpty ? localRoot : localRoot.appendingPathComponent(localRel)
                let present = FileManager.default.fileExists(atPath: localURL.path)
                if present || askedAboutThisMac {
                    locations.append(FileLocation(
                        role: .workingCopy,
                        name: link.displayName,
                        rootPath: link.localPath,
                        absolutePath: localURL.path,
                        present: present,
                        size: FileMeta.size(ofFileAt: localURL),
                        modified: FileMeta.modificationDate(ofFileAt: localURL),
                        note: present
                            ? "The copy this Mac edits in “\(link.displayName)”; changes here are published to the vault."
                            : "Not on this Mac right now; the vault is where the file lives until it syncs back."
                    ))
                }
            }
        }

        // MARK: Retained copies in each destination's trash

        for replica in config.replicas {
            let records = DeleteStore(paths: paths).load(replicaID: replica.id)
            for record in records where candidateRels.contains(record.relativePath)
                || candidateRels.contains(VaultPath.key(record.relativePath)) {
                let trash = record.trashURL(onReplicaRoot: replica.url)
                let present = FileManager.default.fileExists(atPath: trash.path)
                locations.append(FileLocation(
                    role: .retainedCopy,
                    name: replica.displayName,
                    rootPath: trash.deletingLastPathComponent().path,
                    absolutePath: trash.path,
                    present: present,
                    size: record.size,
                    recorded: RecordedCopy(kind: "deletion", sha256: record.sha256, size: record.size,
                                           at: record.deletedAt, expiresAt: record.expiresAt),
                    note: present
                        ? "Deleted on \(Self.day(record.deletedAt)); recoverable until \(Self.day(record.expiresAt))."
                        : "Deletion recorded on \(Self.day(record.deletedAt)), but the retained copy is gone."
                ))
            }
        }

        // MARK: History

        var history: [FileHistoryEntry] = []
        for link in config.vaults {
            let store = VaultStore(root: link.vaultURL)
            let keys = candidateRels.map(VaultPath.key)
            for entry in store.loadEntries().entries where keys.contains(VaultPath.key(entry.path)) {
                history.append(FileHistoryEntry(at: entry.at, kind: entry.kind.rawValue,
                                                machineName: entry.machineName,
                                                size: entry.size, sha256: entry.sha256))
            }
        }
        history.sort { $0.at > $1.at }

        let relative = candidateRels.min { $0.count < $1.count } ?? target.lastPathComponent
        return FileStatusReport(
            path: target.path,
            relativePath: relative,
            kind: isDirectory ? "folder" : (exists ? "file" : "missing"),
            summary: Self.summary(kind: isDirectory ? "folder" : (exists ? "file" : "missing"),
                                 locations: locations,
                                 covered: !locations.isEmpty),
            locations: locations,
            history: Array(history.prefix(Self.historyLimit)),
            generatedAt: now,
            covered: !locations.isEmpty
        )
    }

    // MARK: - Helpers

    /// The path of `file` relative to `root`, or nil when it is not inside it. `""` means the path
    /// *is* the root, which is a real question — "is this folder protected?" — and is answered
    /// rather than dropped.
    private func relativeOrRoot(_ filePath: String, under rootPath: String) -> String? {
        let root = PathIdentity.canonical(URL(fileURLWithPath: rootPath))
        if filePath == root { return "" }
        guard filePath.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return String(filePath.dropFirst(root.count + 1))
    }

    /// The same question for callers that need a path *inside* the root: nil for the root itself.
    private func relative(_ filePath: String, under rootPath: String) -> String? {
        guard let rel = relativeOrRoot(filePath, under: rootPath), !rel.isEmpty else { return nil }
        return rel
    }

    /// Size and date agree with the record. See the note on this file: not a digest check, and
    /// deliberately so, because this runs for a whole folder at a click.
    static func matches(recordedSize: Int64, recordedMtime: Date, onDiskSize: Int64?, onDiskMtime: Date?) -> Bool {
        guard let onDiskSize, let onDiskMtime else { return false }
        guard onDiskSize == recordedSize else { return false }
        return abs(onDiskMtime.timeIntervalSince(recordedMtime)) < 1
    }

    /// The one-sentence verdict. Written as prose rather than as a status word because the useful
    /// answer is "where does it actually exist", and every failure mode here is a location, not a
    /// colour: missing from the NAS, differing from the record, or held in the trash after a delete.
    static func summary(kind: String, locations: [FileLocation], covered: Bool) -> String {
        guard covered else {
            return "Not in any NeoDrop folder: this Mac is not protecting this path."
        }
        if kind == "folder" {
            return "This is a folder. NeoDrop protects the files inside it one at a time, so ask for File Status on a file to see where that copy lives."
        }

        let local = locations.filter { ($0.role == .source || $0.role == .workingCopy) && $0.present }
        let destinations = locations.filter { ($0.role == .replica || $0.role == .vault) && $0.present }
        let written = locations.filter { $0.role == .replica || $0.role == .vault }
        let retained = locations.first { $0.role == .retainedCopy && $0.present }
        let mismatched = locations.filter { $0.recorded?.matches == false && $0.present }

        var parts: [String] = []
        if let retained, let record = retained.recorded {
            let expiry = record.expiresAt.map { Self.day($0) } ?? "soon"
            parts.append("NeoDrop was told this was deleted on \(Self.day(record.at)) and is holding a copy until \(expiry).")
        }
        if !local.isEmpty {
            parts.append("It is on this Mac")
            // "On this Mac and copied to X" reads as one sentence; "On this Mac. Copied to X." does not.
            parts[parts.count - 1] += destinations.isEmpty ? "." : " and copied to \(destinations.map(\.name).joined(separator: ", "))."
            if destinations.isEmpty {
                parts.append(written.isEmpty
                             ? "No destination has a copy yet — the next sync will make one."
                             : "No destination is reachable right now, so nothing else holds it at this moment.")
            }
        } else {
            // Nothing on this Mac holds it: either the path is not in a local folder at all (a
            // question asked about the share) or it has been deleted here.
            parts.append("It is not on this Mac.")
            if !destinations.isEmpty {
                parts.append("The bytes are still in \(destinations.map(\.name).joined(separator: ", ")).")
            } else if retained == nil {
                // A retained copy already explains where the bytes are, so this is only the case
                // where nothing holds them: either no destination is configured, or none of them
                // has a record of this path and none is answering.
                parts.append(written.isEmpty
                             ? "No destination has a copy yet — the next sync will make one."
                             : "No destination is reachable right now, so nothing else holds it at this moment.")
            }
        }
        if !mismatched.isEmpty {
            parts.append("⚠︎ \(mismatched.map(\.name).joined(separator: ", ")) no longer match what NeoDrop recorded. Verify & Repair can confirm whether the bytes are intact.")
        }
        if locations.contains(where: { $0.recorded?.matches == true }) {
            parts.append("Sizes and dates agree with NeoDrop's records; run Verify & Repair to check the bytes themselves.")
        }
        return parts.joined(separator: " ")
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func day(_ date: Date) -> String { day.string(from: date) }
}
