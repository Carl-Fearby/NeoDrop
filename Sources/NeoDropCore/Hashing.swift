import Foundation
import CryptoKit

/// Lowercase hex encoding of a byte sequence (used for every digest NeoDrop prints or stores).
public func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    let digits = Array("0123456789abcdef".utf8)
    var out = [UInt8]()
    out.reserveCapacity(64)
    for byte in bytes {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: out, as: UTF8.self)
}

public enum Hashing {
    /// Read the file in 1 MiB chunks so multi-gigabyte files never sit in memory.
    public static let chunkSize = 1 << 20

    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hexString(hasher.finalize())
    }

    public static func sha256(of string: String) -> String {
        hexString(SHA256.hash(data: Data(string.utf8)))
    }
}

/// Copies bytes into `destination` durably: write a sibling temp file, fsync it, then rename.
///
/// The rename is what makes a half-written file impossible to observe on the replica, which
/// matters a lot on SMB shares where a dropped connection otherwise leaves a truncated file
/// that looks complete to a size-only check.
public enum AtomicFile {
    public static func copy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let temp = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).neodrop-\(UUID().uuidString.prefix(8)).part"
        )
        var cleanup = true
        defer { if cleanup { try? fm.removeItem(at: temp) } }

        try fm.copyItem(at: source, to: temp)
        try flush(fileAt: temp)

        // Preserve the source modification date so a later scan of the replica looks like the
        // source (useful for humans browsing the share; correctness uses the digest).
        if let mtime = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: temp.path)
        }

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: temp, to: destination)
        cleanup = false

        try? flushDirectory(parent)
    }

    /// fsync a file's contents all the way to the device.
    public static func flush(fileAt url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    public static func flushDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fsync(fd)
    }
}

public enum FileMeta {
    public static func size(ofFileAt url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        guard let size = values.fileSize else { return nil }
        return Int64(size)
    }

    public static func modificationDate(ofFileAt url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
