import Foundation
import NeoDropShared

/// Where NeoDrop keeps everything that is not the user's data.
public struct StorePaths: Sendable {
    public let base: URL

    public init(base: URL) { self.base = base }

    /// `NEODROP_HOME` redirects every piece of state (config, manifests, index, log). It exists so
    /// the app can be exercised end to end against throwaway folders — scripts/e2e.sh uses it —
    /// and so a second instance can run side by side without touching the real state.
    public static var standard: StorePaths {
        if let override = ProcessInfo.processInfo.environment["NEODROP_HOME"], !override.isEmpty {
            return StorePaths(base: URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return StorePaths(base: support.appendingPathComponent("NeoDrop", isDirectory: true))
    }

    public var configURL: URL { base.appendingPathComponent("config.json") }
    public var runtimeStateURL: URL { base.appendingPathComponent("runtime-state.json") }
    public var sourceIndexURL: URL { base.appendingPathComponent("source-index.json") }
    public var logURL: URL { base.appendingPathComponent("neodrop.log") }
    public var manifestsDirectory: URL { base.appendingPathComponent("manifests", isDirectory: true) }
    public var locksDirectory: URL { base.appendingPathComponent("locks", isDirectory: true) }
    public var deletesDirectory: URL { base.appendingPathComponent("deletes", isDirectory: true) }
    /// Per-vault, per-machine sync state (what this machine and the vault last agreed on).
    public var vaultsDirectory: URL { base.appendingPathComponent("vaults", isDirectory: true) }
    /// This machine's identity: the name it puts on the journal it writes and on conflicted copies.
    public var machineURL: URL { base.appendingPathComponent("machine.json") }
    /// What the Finder extension reads to badge files. Written by the app, read by another process
    /// (Finder's), which is why it has to be a file and cannot be the app's memory.
    public var finderStatusURL: URL { base.appendingPathComponent(FinderStatusIndex.fileName) }

    public func vaultCursorURL(vaultID: UUID) -> URL {
        vaultsDirectory.appendingPathComponent("\(vaultID.uuidString).json")
    }

    /// Files this machine has deliberately restored after another machine deleted them, which the
    /// next reconcile must publish as new content rather than treat as a stale copy. Keyed by the
    /// link id, like the deletion records it belongs beside.
    public func vaultUndeleteURL(linkID: UUID) -> URL {
        vaultsDirectory.appendingPathComponent("\(linkID.uuidString)-undeletes.json")
    }

    public func manifestURL(for replicaID: UUID) -> URL {
        manifestsDirectory.appendingPathComponent("\(replicaID.uuidString).json")
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for directory in [base, manifestsDirectory, locksDirectory, deletesDirectory, vaultsDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

enum JSONFile {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Slashes stay as slashes. Record and manifest paths are file paths, and `Documents\/a.txt`
        // is the same JSON but nobody can read it — including whoever opens a record to see what
        // NeoDrop is holding. Decoding is unaffected either way.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(type, from: data)
    }

    /// Write via a temp file so a crash mid-write cannot leave a truncated config behind.
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder().encode(value)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(6))")
        try data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}

/// Reads and writes `config.json`, keeping a `.bak` of the previous value.
public struct ConfigStore: Sendable {
    public let paths: StorePaths

    public init(paths: StorePaths = .standard) { self.paths = paths }

    public func load() -> AppConfig {
        guard let config = JSONFile.load(AppConfig.self, from: paths.configURL) else {
            return AppConfig()
        }
        return config
    }

    public func save(_ config: AppConfig) throws {
        try paths.ensureDirectories()
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.configURL.path) {
            let backup = paths.configURL.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: paths.configURL, to: backup)
        }
        try JSONFile.save(config, to: paths.configURL)
    }
}

/// Reads and writes the per-replica manifests.
public struct ManifestStore: Sendable {
    public let paths: StorePaths

    public init(paths: StorePaths = .standard) { self.paths = paths }

    public func load(replicaID: UUID) -> Manifest {
        JSONFile.load(Manifest.self, from: paths.manifestURL(for: replicaID)) ?? Manifest(replicaID: replicaID)
    }

    public func save(_ manifest: Manifest) throws {
        try paths.ensureDirectories()
        try JSONFile.save(manifest, to: paths.manifestURL(for: manifest.replicaID))
    }

    public func remove(replicaID: UUID) throws {
        try? FileManager.default.removeItem(at: paths.manifestURL(for: replicaID))
    }
}

/// Reads and writes the per-replica deletion manifests. Each replica keeps its own file under
/// the deletes directory, exactly the same shape as `manifests/` — one JSON object per replica,
/// atomic writes via a temp file, so a crash mid-write cannot leave a half-written record.
public struct DeleteStore: Sendable {
    public let paths: StorePaths

    public init(paths: StorePaths = .standard) { self.paths = paths }

    /// Where a single replica's records live. The file name is the replica UUID so a profile with
    /// many replicas never collides with another, and the file is small enough that reading the
    /// whole thing is cheap for a web UI listing one replica at a time.
    public func URL(for replicaID: UUID) -> URL { paths.deletesDirectory.appendingPathComponent(replicaID.uuidString + ".json") }

    public func ensureDirectories() throws {
        try paths.ensureDirectories()
    }

    /// Load the record for one replica. Missing is not an error: a new replica has no records.
    public func load(replicaID: UUID) -> [DeleteRecord] {
        JSONFile.load([DeleteRecord].self, from: URL(for: replicaID)) ?? []
    }

    /// Persist in place so a partial write cannot touch the previous value: `JSONFile.save`
    /// writes a temp file and renames it over the old one, and uses the same ISO-8601 date
    /// strategy `JSONFile.load` decodes with — encoding dates a different way here would write
    /// records that silently fail to load again.
    public func save(_ records: [DeleteRecord], for replicaID: UUID) throws {
        try paths.ensureDirectories()
        try JSONFile.save(records, to: URL(for: replicaID))
    }

    /// Remove the record for a recovered file so it stops appearing in the web UI as recoverable.
    public func remove(_ id: UUID, for replicaID: UUID) throws {
        var records = load(replicaID: replicaID)
        records.removeAll { $0.id == id }
        try save(records, for: replicaID)
    }

    /// Purge is deliberately not here. Expiring a record must free its retained bytes on the
    /// replica at the same time, which needs the configuration's replica roots — the engine owns
    /// that (`purgeExpiredDeletions`), and a store that could drop records alone would be able to
    /// orphan copies nothing would ever find again.
}

/// Reads and writes the per-replica runtime state.
public struct RuntimeStateStore: Sendable {
    public let paths: StorePaths

    public init(paths: StorePaths = .standard) { self.paths = paths }

    public func load() -> RuntimeState {
        JSONFile.load(RuntimeState.self, from: paths.runtimeStateURL) ?? RuntimeState()
    }

    public func save(_ state: RuntimeState) throws {
        try paths.ensureDirectories()
        try JSONFile.save(state, to: paths.runtimeStateURL)
    }
}

/// Reads and writes the per-source hash index.
public struct SourceIndexStore: Sendable {
    public let paths: StorePaths

    public init(paths: StorePaths = .standard) { self.paths = paths }

    public func load() -> SourceIndex {
        JSONFile.load(SourceIndex.self, from: paths.sourceIndexURL) ?? SourceIndex()
    }

    public func save(_ index: SourceIndex) throws {
        try paths.ensureDirectories()
        try JSONFile.save(index, to: paths.sourceIndexURL)
    }
}
