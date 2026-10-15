import Foundation

// MARK: - Configuration

/// One NAS destination. A replica is just a directory: a mounted SMB share under `/Volumes`,
/// an external disk, a local folder (what the tests use) or any other path. `smbURL` is only a
/// hint NeoDrop uses to ask Finder to mount the share when the path is not there.
public struct Replica: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Absolute path to the folder on the NAS that mirrors the source root(s).
    public var path: String
    /// Optional `smb://host/share` (or `afp://`) used to ask Finder to mount the share.
    public var smbURL: String?
    public var enabled: Bool
    /// Lower priority numbers are preferred as a read source when repairing.
    public var priority: Int

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        smbURL: String? = nil,
        enabled: Bool = true,
        priority: Int = 100
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.smbURL = smbURL
        self.enabled = enabled
        self.priority = priority
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// Display name, falling back to the last path component before the folder is renamed.
    public var displayName: String {
        name.isEmpty ? url.lastPathComponent : name
    }
}

/// A local folder that NeoDrop protects. Every replica mirrors every source under the same
/// relative layout, so `/Volumes/NAS1/NeoDrop/Photos/a.jpg` mirrors `~/Pictures/a.jpg`.
public struct SourceRoot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String

    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    public var url: URL { URL(fileURLWithPath: path) }

    public var displayName: String {
        name.isEmpty ? url.lastPathComponent : name
    }
}

public struct AppConfig: Codable, Sendable {
    public var version: Int
    public var sources: [SourceRoot]
    public var replicas: [Replica]
    /// Two-way folders: a local working copy paired with a vault on a share. A vault link is the
    /// Dropbox-shaped mode; a replica is the one-way mirror. Both can live in one configuration.
    public var vaults: [VaultLink]
    /// Watch the sources with FSEvents and sync shortly after anything changes.
    public var watchForChanges: Bool
    /// Run a sync on a timer even when nothing changed.
    public var scheduledSync: Bool
    public var syncIntervalMinutes: Int
    /// Verify every replica on a timer.
    public var scheduledVerify: Bool
    public var verifyIntervalHours: Int
    /// Re-hash every copied file right after writing it (catches bad media early, costs I/O).
    public var verifyAfterCopy: Bool
    /// Delete files on replicas that no longer exist in the source. Only files NeoDrop wrote
    /// (i.e. recorded in the manifest) are ever deleted.
    public var mirrorDeletions: Bool
    /// Opt out of the bulk-deletion guard, which refuses to remove more than a quarter of the
    /// mirror in a single run (or 25 files, whichever is larger).
    public var allowBulkDeletions: Bool
    /// Glob patterns matched against the file name and the relative path.
    public var excludes: [String]
    /// Whether the first-run setup wizard has already been offered. It is shown once on a pristine
    /// install, and afterwards only when asked for from the menu: a window that reappears every
    /// launch until someone configures something is a nag, not an invitation.
    public var didOfferSetup: Bool

    public init(
        version: Int = 1,
        sources: [SourceRoot] = [],
        replicas: [Replica] = [],
        vaults: [VaultLink] = [],
        watchForChanges: Bool = true,
        scheduledSync: Bool = true,
        syncIntervalMinutes: Int = 15,
        scheduledVerify: Bool = true,
        verifyIntervalHours: Int = 24,
        verifyAfterCopy: Bool = true,
        mirrorDeletions: Bool = true,
        allowBulkDeletions: Bool = false,
        excludes: [String] = AppConfig.defaultExcludes,
        didOfferSetup: Bool = false
    ) {
        self.version = version
        self.sources = sources
        self.replicas = replicas
        self.vaults = vaults
        self.watchForChanges = watchForChanges
        self.scheduledSync = scheduledSync
        self.syncIntervalMinutes = syncIntervalMinutes
        self.scheduledVerify = scheduledVerify
        self.verifyIntervalHours = verifyIntervalHours
        self.verifyAfterCopy = verifyAfterCopy
        self.mirrorDeletions = mirrorDeletions
        self.allowBulkDeletions = allowBulkDeletions
        self.excludes = excludes
        self.didOfferSetup = didOfferSetup
    }

    public static let defaultExcludes = [".DS_Store", "._*", ".Trash", "*.tmp", "*.part", ".neodrop-*"]

    /// Decoded by hand so a key this build does not know about cannot make the whole file
    /// unreadable. `JSONFile.load` turns a failed decode into "no configuration", and silently
    /// forgetting every source and destination because a newer build wrote one extra field is far
    /// worse than ignoring that field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sources = try container.decodeIfPresent([SourceRoot].self, forKey: .sources) ?? []
        replicas = try container.decodeIfPresent([Replica].self, forKey: .replicas) ?? []
        vaults = try container.decodeIfPresent([VaultLink].self, forKey: .vaults) ?? []
        watchForChanges = try container.decodeIfPresent(Bool.self, forKey: .watchForChanges) ?? true
        scheduledSync = try container.decodeIfPresent(Bool.self, forKey: .scheduledSync) ?? true
        syncIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .syncIntervalMinutes) ?? 15
        scheduledVerify = try container.decodeIfPresent(Bool.self, forKey: .scheduledVerify) ?? true
        verifyIntervalHours = try container.decodeIfPresent(Int.self, forKey: .verifyIntervalHours) ?? 24
        verifyAfterCopy = try container.decodeIfPresent(Bool.self, forKey: .verifyAfterCopy) ?? true
        mirrorDeletions = try container.decodeIfPresent(Bool.self, forKey: .mirrorDeletions) ?? true
        allowBulkDeletions = try container.decodeIfPresent(Bool.self, forKey: .allowBulkDeletions) ?? false
        excludes = try container.decodeIfPresent([String].self, forKey: .excludes) ?? AppConfig.defaultExcludes
        didOfferSetup = try container.decodeIfPresent(Bool.self, forKey: .didOfferSetup) ?? false
    }

    /// Nothing configured at all: a fresh install, or one whose state directory was just removed.
    /// This is what decides whether the setup wizard introduces itself on launch.
    public var isPristine: Bool { sources.isEmpty && replicas.isEmpty && vaults.isEmpty }

    public var enabledReplicas: [Replica] {
        replicas.filter(\.enabled).sorted { $0.priority < $1.priority }
    }

    public var enabledVaults: [VaultLink] { vaults.filter(\.enabled) }

    /// A configuration with at least one kind of destination set up. Either mode alone is enough:
    /// a vault-only setup is a complete Dropbox-shaped configuration and must not be told it is
    /// unconfigured because it has no mirror.
    public var isConfigured: Bool { hasMirrors || hasVaults }

    public var hasMirrors: Bool { !sources.isEmpty && !enabledReplicas.isEmpty }

    public var hasVaults: Bool { !enabledVaults.isEmpty }

    public func replica(id: UUID) -> Replica? { replicas.first { $0.id == id } }

    public func vault(id: UUID) -> VaultLink? { vaults.first { $0.id == id } }
}

// MARK: - Manifest

/// What NeoDrop believes is on a replica. The digest is what makes verification meaningful:
/// a size match alone cannot tell a complete file from a truncated one.
public struct ManifestEntry: Codable, Equatable, Sendable {
    public var size: Int64
    public var mtime: Date
    public var sha256: String
    public var writtenAt: Date
    public var verifiedAt: Date?
    public var sourceID: UUID?

    public init(
        size: Int64,
        mtime: Date,
        sha256: String,
        writtenAt: Date = Date(),
        verifiedAt: Date? = nil,
        sourceID: UUID? = nil
    ) {
        self.size = size
        self.mtime = mtime
        self.sha256 = sha256
        self.writtenAt = writtenAt
        self.verifiedAt = verifiedAt
        self.sourceID = sourceID
    }
}

public struct Manifest: Codable, Sendable {
    public var replicaID: UUID
    /// Keyed by the path relative to the replica root, using `/` separators.
    public var entries: [String: ManifestEntry]
    public var lastSync: Date?
    public var lastVerify: Date?
    /// Paths that failed verification, retained so the menu can warn about them.
    public var corruptPaths: [String]
    /// Paths where something sits that NeoDrop did not write and therefore will not replace,
    /// retained so the Finder badge and the report can name them. Emptied as soon as every such
    /// path is NeoDrop's again (usually because the user moved their file aside).
    public var foreignPaths: [String]

    public init(replicaID: UUID, entries: [String: ManifestEntry] = [:], lastSync: Date? = nil,
                lastVerify: Date? = nil, corruptPaths: [String] = [], foreignPaths: [String] = []) {
        self.replicaID = replicaID
        self.entries = entries
        self.lastSync = lastSync
        self.lastVerify = lastVerify
        self.corruptPaths = corruptPaths
        self.foreignPaths = foreignPaths
    }

    private enum CodingKeys: String, CodingKey {
        case replicaID, entries, lastSync, lastVerify, corruptPaths, foreignPaths
    }

    /// Decode with defaults for keys an older build never wrote.
    ///
    /// The synthesized decoder throws on a missing key, and `ManifestStore.load` cannot tell “this
    /// file came from an older version” from “this file is damaged”: both come back as an empty
    /// manifest, which on a share means uploading every file again. So keys added after the first
    /// release are optional on the way in — `corruptPaths`, and now `foreignPaths`. Encoding is
    /// unchanged, and a test holds the old-file case (`testAManifestFromAnOlderBuildKeepsItsEntries`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.replicaID = try container.decode(UUID.self, forKey: .replicaID)
        self.entries = try container.decodeIfPresent([String: ManifestEntry].self, forKey: .entries) ?? [:]
        self.lastSync = try container.decodeIfPresent(Date.self, forKey: .lastSync)
        self.lastVerify = try container.decodeIfPresent(Date.self, forKey: .lastVerify)
        self.corruptPaths = try container.decodeIfPresent([String].self, forKey: .corruptPaths) ?? []
        self.foreignPaths = try container.decodeIfPresent([String].self, forKey: .foreignPaths) ?? []
    }

    public var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.size } }
}

/// Cached source hashes, so a sync only re-reads files whose size or mtime moved.
public struct SourceIndex: Codable, Sendable {
    /// Keyed by "sourceID/relativePath".
    public var entries: [String: ManifestEntry]

    public init(entries: [String: ManifestEntry] = [:]) { self.entries = entries }

    public init() { self.entries = [:] }
}

// MARK: - Deleted-file retention

/// A file NeoDrop removed from the mirror but is still holding for recovery.
///
/// Deletions are recorded instead of destroyed: when a file is gone from every source, each
/// replica moves its copy into `.neodrop-trash/` at the same relative path and stores a record
/// here. The bytes are guaranteed until `expiresAt` (30 days after the deletion) — the
/// "Deleted Files…" web view restores from them — and the purge removes bytes and record
/// together after that. A record is only ever dropped once its bytes are gone or provably back
/// in the source, so a retained copy can never be orphaned by cleaning up the list.
public struct DeleteRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    /// The path the file occupied on the mirror (`Photos/a.jpg`) — also its path under `.neodrop-trash/`.
    public var relativePath: String
    /// Absolute path in the source folder: where a restore puts the file back. Empty when the
    /// originating source root was already gone from the configuration at deletion time.
    public var sourcePath: String
    public var size: Int64
    /// Digest of the retained bytes; a restore verifies this before writing anything.
    public var sha256: String
    public var deletedAt: Date
    public var expiresAt: Date

    public init(
        id: UUID = UUID(),
        relativePath: String,
        sourcePath: String,
        size: Int64,
        sha256: String,
        deletedAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.sourcePath = sourcePath
        self.size = size
        self.sha256 = sha256
        self.deletedAt = deletedAt
        self.expiresAt = expiresAt ?? deletedAt.addingTimeInterval(Self.retention)
    }

    /// How long a deletion stays recoverable.
    public static let retentionDays = 30
    public static let retention = TimeInterval(retentionDays) * 24 * 60 * 60

    public var isExpired: Bool { Date() >= expiresAt }

    /// The directory on a replica that holds retained copies, hidden and matched by the default
    /// `.neodrop-*` exclude so it can never be mistaken for mirrored data.
    public static let trashDirectoryName = ".neodrop-trash"

    /// Where the retained bytes live on a replica whose root is `replicaRoot`.
    public func trashURL(onReplicaRoot replicaRoot: URL) -> URL {
        replicaRoot
            .appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
            .appendingPathComponent(relativePath)
    }
}

/// One destination's stake in a deletion: whether that replica still holds retained bytes.
public struct DeletionCopy: Codable, Sendable, Equatable {
    public var replicaID: UUID
    public var replicaName: String
    /// False when the destination is unreachable or its retained copy is already gone.
    public var available: Bool

    public init(replicaID: UUID, replicaName: String, available: Bool) {
        self.replicaID = replicaID
        self.replicaName = replicaName
        self.available = available
    }
}

/// One deleted file as the web view sees it: the records of every destination that deleted it,
/// aggregated. `relativePath` is the identity — each replica records the same logical deletion
/// independently, moments apart.
public struct DeletionEntry: Codable, Identifiable, Sendable {
    public var relativePath: String
    public var sourcePath: String
    public var size: Int64
    public var sha256: String
    public var deletedAt: Date
    /// The earliest expiry across copies: once any copy's window closes it may vanish from that replica.
    public var expiresAt: Date
    public var copies: [DeletionCopy]
    /// At least one reachable replica still holds verified-recoverable bytes.
    ///
    /// Stored rather than computed: this crosses the wire as JSON to the deleted-files page, and a
    /// computed property is not encoded — the page would then see `undefined` and leave every
    /// Restore button disabled. It is derived in `init`, so it cannot disagree with `copies`.
    public var restorable: Bool

    public var id: String { relativePath }

    public init(relativePath: String, sourcePath: String, size: Int64, sha256: String,
                deletedAt: Date, expiresAt: Date, copies: [DeletionCopy]) {
        self.relativePath = relativePath
        self.sourcePath = sourcePath
        self.size = size
        self.sha256 = sha256
        self.deletedAt = deletedAt
        self.expiresAt = expiresAt
        self.copies = copies
        self.restorable = copies.contains(where: \.available)
    }
}

// MARK: - Runtime state

public enum ReplicaStatus: String, Codable, Sendable {
    // The raw-value Codable conformance is synthesised: decoding maps the stored string through
    // `init(rawValue:)` and fails loudly on an unknown one, which is exactly the hand-rolled
    // decoder this file used to carry — twice, which would not compile.
    case unknown
    case online
    case syncing
    case degraded
    case offline
    case disabled

    public var symbol: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .online: return "checkmark.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .degraded: return "exclamationmark.triangle.fill"
        case .offline: return "xmark.octagon.fill"
        case .disabled: return "minus.circle"
        }
    }
}

public struct ReplicaRuntime: Codable, Sendable {
    public var status: ReplicaStatus = .unknown
    public var lastSync: Date?
    public var lastVerify: Date?
    public var files: Int = 0
    public var bytes: Int64 = 0
    public var corrupt: Int = 0
    public var lastError: String?

    public init() {}
}

public struct RuntimeState: Codable, Sendable {
    public var replicas: [String: ReplicaRuntime] = [:]
    public var lastSync: Date?
    public var lastVerify: Date?
    public var lastError: String?

    public init() {}

    public func runtime(for id: UUID) -> ReplicaRuntime {
        replicas[id.uuidString] ?? ReplicaRuntime()
    }

    public mutating func update(_ id: UUID, _ body: (inout ReplicaRuntime) -> Void) {
        var runtime = replicas[id.uuidString] ?? ReplicaRuntime()
        body(&runtime)
        replicas[id.uuidString] = runtime
    }
}

// MARK: - Progress and summaries

public enum SyncPhase: Equatable, Sendable {
    case idle
    case scanning
    case syncing
    case verifying
    case repairing
    case finished
    case failed(String)

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .scanning: return "Scanning source"
        case .syncing: return "Mirroring"
        case .verifying: return "Verifying"
        case .repairing: return "Repairing"
        case .finished: return "Up to date"
        case .failed(let message): return "Error: \(message)"
        }
    }
}

public struct SyncProgress: Sendable {
    public var phase: SyncPhase
    public var replicaName: String?
    public var currentFile: String?
    public var filesTotal: Int
    public var filesDone: Int
    public var bytesTotal: Int64
    public var bytesDone: Int64

    public init(
        phase: SyncPhase,
        replicaName: String? = nil,
        currentFile: String? = nil,
        filesTotal: Int = 0,
        filesDone: Int = 0,
        bytesTotal: Int64 = 0,
        bytesDone: Int64 = 0
    ) {
        self.phase = phase
        self.replicaName = replicaName
        self.currentFile = currentFile
        self.filesTotal = filesTotal
        self.filesDone = filesDone
        self.bytesTotal = bytesTotal
        self.bytesDone = bytesDone
    }

    public var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }
}

public struct ReplicaReport: Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var status: ReplicaStatus
    public var copied: Int
    public var updated: Int
    public var deleted: Int
    public var upToDate: Int
    public var repaired: Int
    public var corrupt: Int
    public var failed: Int
    /// Files that were already on the replica with the source's exact bytes, so they were recorded
    /// rather than uploaded again. This is the manifest having been lost (a reset, a new Mac), not a
    /// normal sync.
    public var adopted: Int
    /// Files NeoDrop did not write and will not replace. Something else is at a path the mirror
    /// wants, and it is left exactly as it is.
    public var foreign: Int
    public var bytesWritten: Int64
    public var errors: [String]

    public init(
        id: UUID,
        name: String,
        status: ReplicaStatus,
        copied: Int = 0,
        updated: Int = 0,
        deleted: Int = 0,
        upToDate: Int = 0,
        repaired: Int = 0,
        corrupt: Int = 0,
        failed: Int = 0,
        adopted: Int = 0,
        foreign: Int = 0,
        bytesWritten: Int64 = 0,
        errors: [String] = []
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.copied = copied
        self.updated = updated
        self.deleted = deleted
        self.upToDate = upToDate
        self.repaired = repaired
        self.corrupt = corrupt
        self.failed = failed
        self.adopted = adopted
        self.foreign = foreign
        self.bytesWritten = bytesWritten
        self.errors = errors
    }

    public var changed: Int { copied + updated + deleted + repaired }
}

public struct SyncSummary: Sendable {
    public var phase: SyncPhase
    public var startedAt: Date
    public var finishedAt: Date
    public var replicas: [ReplicaReport]

    public init(phase: SyncPhase, startedAt: Date, finishedAt: Date = Date(), replicas: [ReplicaReport] = []) {
        self.phase = phase
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.replicas = replicas
    }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    public var filesChanged: Int { replicas.reduce(0) { $0 + $1.changed } }
    public var filesCopied: Int { replicas.reduce(0) { $0 + $1.copied + $1.updated } }
    public var filesRepaired: Int { replicas.reduce(0) { $0 + $1.repaired } }
    public var filesDeleted: Int { replicas.reduce(0) { $0 + $1.deleted } }
    /// Files that were already on a replica with the source's exact bytes and were recorded rather
    /// than uploaded — the manifest having been lost, not a normal sync.
    public var filesAdopted: Int { replicas.reduce(0) { $0 + $1.adopted } }
    /// Files left alone because they are not NeoDrop's to replace.
    public var foreignFiles: Int { replicas.reduce(0) { $0 + $1.foreign } }
    public var bytesWritten: Int64 { replicas.reduce(0) { $0 + $1.bytesWritten } }
    public var failures: Int { replicas.reduce(0) { $0 + $1.failed } }

    /// True when at least one replica is unreachable or holds a bad copy.
    public var isDegraded: Bool {
        replicas.contains { $0.status == .offline || $0.status == .degraded || $0.failed > 0 }
    }

    public var healthyReplicaCount: Int { replicas.filter { $0.status == .online || $0.status == .syncing }.count }
}
