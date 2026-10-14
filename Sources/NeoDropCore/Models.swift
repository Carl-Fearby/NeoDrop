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

    public init(
        version: Int = 1,
        sources: [SourceRoot] = [],
        replicas: [Replica] = [],
        watchForChanges: Bool = true,
        scheduledSync: Bool = true,
        syncIntervalMinutes: Int = 15,
        scheduledVerify: Bool = true,
        verifyIntervalHours: Int = 24,
        verifyAfterCopy: Bool = true,
        mirrorDeletions: Bool = true,
        allowBulkDeletions: Bool = false,
        excludes: [String] = AppConfig.defaultExcludes
    ) {
        self.version = version
        self.sources = sources
        self.replicas = replicas
        self.watchForChanges = watchForChanges
        self.scheduledSync = scheduledSync
        self.syncIntervalMinutes = syncIntervalMinutes
        self.scheduledVerify = scheduledVerify
        self.verifyIntervalHours = verifyIntervalHours
        self.verifyAfterCopy = verifyAfterCopy
        self.mirrorDeletions = mirrorDeletions
        self.allowBulkDeletions = allowBulkDeletions
        self.excludes = excludes
    }

    public static let defaultExcludes = [".DS_Store", "._*", ".Trash", "*.tmp", "*.part", ".neodrop-*"]

    public var enabledReplicas: [Replica] {
        replicas.filter(\.enabled).sorted { $0.priority < $1.priority }
    }

    public var isConfigured: Bool { !sources.isEmpty && !enabledReplicas.isEmpty }

    public func replica(id: UUID) -> Replica? { replicas.first { $0.id == id } }
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

    public init(replicaID: UUID, entries: [String: ManifestEntry] = [:], lastSync: Date? = nil,
                lastVerify: Date? = nil, corruptPaths: [String] = []) {
        self.replicaID = replicaID
        self.entries = entries
        self.lastSync = lastSync
        self.lastVerify = lastVerify
        self.corruptPaths = corruptPaths
    }

    public var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.size } }
}

/// Cached source hashes, so a sync only re-reads files whose size or mtime moved.
public struct SourceIndex: Codable, Sendable {
    /// Keyed by "sourceID/relativePath".
    public var entries: [String: ManifestEntry]

    public init(entries: [String: ManifestEntry] = [:]) { self.entries = entries }
}

// MARK: - Runtime state

public enum ReplicaStatus: String, Codable, Sendable {
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
    public var bytesWritten: Int64 { replicas.reduce(0) { $0 + $1.bytesWritten } }
    public var failures: Int { replicas.reduce(0) { $0 + $1.failed } }

    /// True when at least one replica is unreachable or holds a bad copy.
    public var isDegraded: Bool {
        replicas.contains { $0.status == .offline || $0.status == .degraded || $0.failed > 0 }
    }

    public var healthyReplicaCount: Int { replicas.filter { $0.status == .online || $0.status == .syncing }.count }
}
