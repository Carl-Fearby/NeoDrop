import Foundation

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

    public func manifestURL(for replicaID: UUID) -> URL {
        manifestsDirectory.appendingPathComponent("\(replicaID.uuidString).json")
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for directory in [base, manifestsDirectory, locksDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

enum JSONFile {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
