import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Glob excludes, matched with `fnmatch` semantics.
///
/// A pattern containing `/` is matched against the whole relative path; otherwise it is matched
/// against the file name, which is what people mean by "ignore `.DS_Store`" or "*.tmp".
public struct ExcludeMatcher: Sendable {
    public let patterns: [String]

    public init(patterns: [String] = AppConfig.defaultExcludes) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func matches(fileName: String, relativePath: String) -> Bool {
        for pattern in patterns {
            if pattern.contains("/") {
                if fnmatch(pattern, relativePath, 0) == 0 { return true }
            } else if fnmatch(pattern, fileName, 0) == 0 {
                return true
            }
        }
        return false
    }

    public func matchesDirectory(named name: String) -> Bool {
        matches(fileName: name, relativePath: name)
    }
}

/// One file found in a source root.
public struct ScannedFile: Equatable, Sendable {
    public var sourceID: UUID
    public var relativePath: String
    public var url: URL
    public var size: Int64
    public var mtime: Date

    public init(sourceID: UUID, relativePath: String, url: URL, size: Int64, mtime: Date) {
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.url = url
        self.size = size
        self.mtime = mtime
    }
}

public enum ScannerError: Error, CustomStringConvertible {
    case sourceMissing(String)

    public var description: String {
        switch self {
        case .sourceMissing(let path): return "Source folder is not available: \(path)"
        }
    }
}

public enum Scanner {
    /// Enumerate every regular file below `root`, skipping excluded names and packages.
    ///
    /// Symbolic links are skipped: mirroring a symlink either duplicates data or creates a loop,
    /// and neither is what "the NAS has a copy of my files" should mean.
    public static func scan(source: SourceRoot, excludes: ExcludeMatcher) throws -> [ScannedFile] {
        try scan(folder: source, excludes: excludes, includeHidden: false)
    }

    /// The same walk, with two knobs vault mode needs.
    ///
    /// `includeHidden` is off for a mirror and on for a vault: mirroring deliberately skips hidden
    /// files, but a two-way tool that silently dropped `.env` or `.ssh` would be a trap, so those
    /// sync. `hardSkips` names directories that must never be published or applied whatever the
    /// user's exclude list says — the vault's own `.neodrop/` metadata and this machine's
    /// `.neodrop-trash/`. Anything else would mean a tool that syncs its own bookkeeping.
    public static func scan(
        folder: SourceRoot,
        excludes: ExcludeMatcher,
        includeHidden: Bool,
        hardSkips: Set<String> = []
    ) throws -> [ScannedFile] {
        let fm = FileManager.default
        let root = folder.url
        guard fm.fileExists(atPath: root.path) else {
            throw ScannerError.sourceMissing(root.path)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var results: [ScannedFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = url.lastPathComponent

            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if hardSkips.contains(name) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true {
                if excludes.matchesDirectory(named: name) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }

            let relative = relativePath(of: url, under: root)
            if excludes.matches(fileName: name, relativePath: relative) { continue }

            results.append(ScannedFile(
                sourceID: folder.id,
                relativePath: relative,
                url: url,
                size: Int64(values.fileSize ?? 0),
                mtime: values.contentModificationDate ?? .distantPast
            ))
        }
        return results
    }

    /// `URL.path(percentEncoded:)` style relative path with `/` separators and no leading slash.
    public static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    /// Resolve a possibly-colliding destination path (`a.jpg`, `a 2.jpg`, ...) inside the source
    /// dimension, so mirroring two sources never silently overwrites one with the other.
    public static func namespaced(relativePath: String, source: SourceRoot, sourceCount: Int) -> String {
        sourceCount <= 1 ? relativePath : "\(source.displayName)/\(relativePath)"
    }
}

/// Hashes the source once and reuses the digest until the file's size or mtime changes.
public struct SourceIndexer: Sendable {
    public init() {}

    /// Returns the refreshed index. `onProgress` is called with (filesHashed, filesReused).
    public func refresh(
        files: [ScannedFile],
        previous: SourceIndex,
        onProgress: ((Int, Int) -> Void)? = nil
    ) -> (index: SourceIndex, hashed: Int, reused: Int, errors: [String]) {
        var index = SourceIndex()
        var hashed = 0
        var reused = 0
        var errors: [String] = []

        for file in files {
            let key = "\(file.sourceID.uuidString)/\(file.relativePath)"
            if let cached = previous.entries[key],
               cached.size == file.size,
               abs(cached.mtime.timeIntervalSince(file.mtime)) < 0.0001,
               !cached.sha256.isEmpty {
                index.entries[key] = cached
                reused += 1
                continue
            }
            do {
                let digest = try Hashing.sha256(ofFileAt: file.url)
                index.entries[key] = ManifestEntry(
                    size: file.size,
                    mtime: file.mtime,
                    sha256: digest,
                    sourceID: file.sourceID
                )
                hashed += 1
            } catch {
                errors.append("\(file.relativePath): \(error.localizedDescription)")
            }
        }
        onProgress?(hashed, reused)
        return (index, hashed, reused, errors)
    }
}
