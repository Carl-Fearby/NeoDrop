import Foundation
import os

public enum LogLevel: String, Sendable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    case success = "OK"
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

    public func write(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(date: Date(), level: level, message: message)
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
