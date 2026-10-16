import Foundation
import os

public enum LogLevel: String, Sendable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    case success = "OK"
}

/// Which part of the setup a log line is about.
///
/// The Activity window's two tabs are decided by this, and by nothing else. They used to be decided
/// by searching the message for the words "vault" and "two-way", which made the Shared tab a guess
/// about English: the line a two-way folder writes — "Shared: 2 sent, 1 received" — contains
/// neither word, so the tab that exists to show that work showed none of it. Whoever writes a line
/// knows what it is about; this is where they say so.
public enum LogScope: String, Sendable {
    /// The folders on this Mac, the one-way mirrors, and the app itself.
    case local
    /// Work that involves a two-way folder: the vault on the share, and what it did.
    case shared
}

/// Append-only log: a ring buffer for the menu, a file for after-the-fact debugging.
public final class NeoDropLog: @unchecked Sendable {
    public static let shared = NeoDropLog()

    private let queue = DispatchQueue(label: "ai.storyteller.neodrop.log")
    private let logger = Logger(subsystem: "ai.storyteller.neodrop", category: "engine")
    private var buffer: [LogEntry] = []
    private let capacity = 400
    private let fileURL: URL

    public init(fileURL: URL = StorePaths.standard.logURL) {
        self.fileURL = fileURL
    }

    public struct LogEntry: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let level: LogLevel
        public let scope: LogScope
        public let message: String

        public var line: String {
            "\(Self.formatter.string(from: date)) [\(level.rawValue)] \(message)"
        }

        static let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter
        }()
    }

    public func write(_ message: String, level: LogLevel = .info, scope: LogScope = .local) {
        let entry = LogEntry(date: Date(), level: level, scope: scope, message: message)
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(entry)
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
            self.logger.log("\(entry.level.rawValue, privacy: .public) \(entry.message, privacy: .public)")
            self.append(entry.line)
        }
    }

    public func recent(_ count: Int = 20) -> [LogEntry] {
        queue.sync { Array(buffer.suffix(count)) }
    }

    /// Prune the on-disk log when it grows past a few megabytes.
    private func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL)
                return
            }
            let attributes = try? fm.attributesOfItem(atPath: fileURL.path)
            let size = (attributes?[.size] as? Int) ?? 0
            if size > 4_000_000 {
                // Rotate rather than grow without bound.
                try? fm.removeItem(at: fileURL)
                try data.write(to: fileURL)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never take the app down.
        }
    }
}
