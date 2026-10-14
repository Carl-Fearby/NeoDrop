import Foundation
import XCTest
@testable import NeoDropCore

/// `XCTUnwrap` takes an autoclosure, which cannot contain `await`. This plain-parameter
/// version can, so async engine calls can be unwrapped inline.
func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        XCTFail("Expected a non-nil value", file: file, line: line)
        throw UnwrapFailure()
    }
    return value
}

struct UnwrapFailure: Error {}

/// A throwaway sandbox: one "local" folder and N fake NAS shares, all real directories so the
/// engine runs exactly the code path it would against a mounted SMB share.
///
/// Identifiers are minted once and reused. Manifests and the source index are keyed by UUID, so
/// handing out a fresh `Replica` on every call would silently point the engine at a different
/// manifest — which is exactly the bug this class exists to make impossible in tests.
final class Sandbox {
    let root: URL
    let source: URL
    let storePaths: StorePaths
    private(set) var replicaURLs: [URL] = []

    /// Fixed identities, created once in `init`.
    let sources: [SourceRoot]
    let replicaModels: [Replica]

    init(name: String = "sandbox", replicaCount: Int = 2) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("neodrop-tests-\(name)-\(UUID().uuidString)")
        source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        var urls: [URL] = []
        var models: [Replica] = []
        for index in 0..<replicaCount {
            let url = root.appendingPathComponent("NAS\(index + 1)/NeoDrop")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            urls.append(url)
            models.append(Replica(name: "NAS\(index + 1)", path: url.path, priority: index))
        }
        replicaURLs = urls
        replicaModels = models
        sources = [SourceRoot(name: "Source", path: source.path)]

        storePaths = StorePaths(base: root.appendingPathComponent("state"))
        try storePaths.ensureDirectories()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var sourceRoot: SourceRoot { sources[0] }

    func replicas(smbURLs: Bool = false) -> [Replica] {
        guard smbURLs else { return replicaModels }
        return replicaModels.enumerated().map { index, replica in
            var copy = replica
            copy.smbURL = "smb://nas\(index + 1).local/backup"
            return copy
        }
    }

    func config(replicaCount: Int? = nil) -> AppConfig {
        let chosen = replicaCount.map { Array(replicaModels.prefix($0)) } ?? replicaModels
        return AppConfig(sources: sources, replicas: chosen)
    }

    func engine() -> MirrorEngine { MirrorEngine(paths: storePaths) }

    // MARK: - File helpers

    @discardableResult
    func write(_ contents: String, to relativePath: String) throws -> URL {
        let url = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeRandomBytes(to relativePath: String, byteCount: Int) throws -> String {
        let data = Data((0..<byteCount).map { _ in UInt8.random(in: 0...255) })
        let url = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return try Hashing.sha256(ofFileAt: url)
    }

    func delete(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: source.appendingPathComponent(relativePath))
    }

    func fileExistsOnReplica(_ index: Int, _ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: replicaURLs[index].appendingPathComponent(relativePath).path)
    }

    func contentsOnReplica(_ index: Int, _ relativePath: String) throws -> String {
        try String(contentsOf: replicaURLs[index].appendingPathComponent(relativePath), encoding: .utf8)
    }

    func readOnReplica(_ index: Int, _ relativePath: String) throws -> Data {
        try Data(contentsOf: replicaURLs[index].appendingPathComponent(relativePath))
    }

    func corruptOnReplica(_ index: Int, _ relativePath: String, with replacement: String) throws {
        let url = replicaURLs[index].appendingPathComponent(relativePath)
        try replacement.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Digest of every file on every replica, for comparing replicas to one another.
    func mirrorContents() throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for (index, url) in replicaURLs.enumerated() {
            var files: [String: String] = [:]
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
            while let file = enumerator?.nextObject() as? URL {
                guard !FileMeta.isDirectory(file) else { continue }
                files[Scanner.relativePath(of: file, under: url)] = try Hashing.sha256(ofFileAt: file)
            }
            result["NAS\(index + 1)"] = files
        }
        return result
    }
}
