import Foundation

/// What the Activity window shows, worked out without a view.
///
/// The window is where a person answers "what is it doing, and did it do the thing I asked?", so
/// its filtering and its wording are worth being able to check on their own. Everything here is a
/// pure function of the log and the current progress; the SwiftUI view that draws the result is
/// layout, not judgement.
public struct ActivityFeed: Sendable {

    /// The two tabs the window offers. "You" is the whole log; "Shared" is the work that involves a
    /// two-way folder, which is what someone with a vault on a share came to look at. The tab is
    /// decided by `LogScope`, so it is the writer's answer rather than a guess about wording.
    public enum Scope: Sendable, CaseIterable {
        case you
        case shared

        /// The scope a line has to be written with to appear under this tab.
        var matching: LogScope? {
            switch self {
            case .you: return nil
            case .shared: return .shared
            }
        }
    }

    /// One line of activity: what it was about, how it went, and which mark to draw beside it.
    public struct Row: Equatable, Sendable, Identifiable {
        public enum Mark: Equatable, Sendable {
            case document
            /// Something a person has to look at: a warning or an error.
            case problem
        }

        public let id: UUID
        public let title: String
        public let detail: String
        public let mark: Mark
        /// A file that finished well gets a full bar, the way a finished transfer looks.
        public let isComplete: Bool

        public init(id: UUID, title: String, detail: String, mark: Mark, isComplete: Bool) {
            self.id = id
            self.title = title
            self.detail = detail
            self.mark = mark
            self.isComplete = isComplete
        }
    }

    /// The row for the pass running now.
    public struct InFlight: Equatable, Sendable {
        public let title: String
        public let detail: String
        public let fraction: Double

        public init(title: String, detail: String, fraction: Double) {
            self.title = title
            self.detail = detail
            self.fraction = fraction
        }
    }

    /// How many rows the window draws. The log holds far more, and a list longer than this is a
    /// scroll nobody reads.
    public static let rowLimit = 40

    /// The most recent `limit` entries that belong to `scope` and match `query`, newest first.
    ///
    /// The caller hands the log over newest-first (`AppModel.activity` reverses the ring buffer),
    /// and a row is built per entry so the same entry always produces the same row.
    public static func rows(
        from log: [NeoDropLog.LogEntry],
        scope: Scope,
        query: String = "",
        limit: Int = ActivityFeed.rowLimit
    ) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = scope.matching
        let matching = log.filter { entry in
            (wanted == nil || entry.scope == wanted)
                && (needle.isEmpty || entry.message.localizedCaseInsensitiveContains(needle))
        }
        return matching.prefix(max(0, limit)).map { entry in
            let split = split(entry.message)
            return Row(
                id: entry.id,
                title: split.title,
                // The outcome and the time, then whatever the title did not already say. A line
                // about a file is titled with the file, and repeating the whole line underneath it
                // would say the path twice in one row.
                detail: [entry.level.rawValue.capitalized, clockTime(entry.date), split.rest]
                    .compactMap { $0 }
                    .joined(separator: " · "),
                mark: entry.level == .error || entry.level == .warning ? .problem : .document,
                isComplete: entry.level == .success
            )
        }
    }

    /// The clock time a line was written, in the reader's own locale.
    static func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// A log line as a title and whatever it said beyond it.
    ///
    /// Lines about a file are written "path: what happened", and the path is what a person scanning
    /// the list is looking for, so it becomes the title and the rest the detail. A line that does
    /// not start with a path — "Syncing “Shared”", "Could not write the journal: the disk is full",
    /// "Shared: 2 sent, 1 received" — is its own title: cutting it at a colon would invent a file
    /// name that is not in it, or throw away the half that carries the meaning.
    static func split(_ message: String) -> (title: String, rest: String?) {
        guard let colon = message.firstIndex(of: ":") else { return (message, nil) }
        let prefix = String(message[..<colon])
        guard prefix.contains("/") || prefix.contains(".") else { return (message, nil) }
        let rest = String(message[message.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (prefix, rest.isEmpty ? nil : rest)
    }

    /// The title of a log line: the file it is about, when the line names one.
    public static func fileTitle(_ message: String) -> String {
        split(message).title
    }

    public static func sectionTitle(isBusy: Bool) -> String {
        isBusy ? "In progress" : "Recent activity"
    }

    /// The row for what is running: the file being moved, the line describing the pass, and how far
    /// along it is. Nil when nothing is running, which is when the list is the whole story.
    public static func inFlight(isBusy: Bool, progress: SyncProgress) -> InFlight? {
        guard isBusy else { return nil }
        return InFlight(
            title: progress.currentFile ?? progress.replicaName ?? "Preparing files…",
            detail: progressLine(progress),
            fraction: progress.fraction
        )
    }

    /// One line describing a pass, in the order a person reads it: the phase, where it is going, how
    /// far it has got, and which file is moving.
    public static func progressLine(_ progress: SyncProgress) -> String {
        var parts: [String] = [progress.phase.label]
        if let name = progress.replicaName { parts.append("→ \(name)") }
        if progress.filesTotal > 0 { parts.append("\(progress.filesDone)/\(progress.filesTotal) files") }
        if let file = progress.currentFile { parts.append(file) }
        return parts.joined(separator: " · ")
    }

    /// The footer: how much is left to move while it is moving, and the standing summary of the
    /// setup when it is not.
    public static func footer(isBusy: Bool, progress: SyncProgress, fallback: String) -> String {
        guard isBusy else { return fallback }
        if progress.bytesTotal > 0 {
            return "\(progress.bytesDone.byteDescription) of \(progress.bytesTotal.byteDescription)"
        }
        if progress.filesTotal > 0 { return "\(progress.filesDone) of \(progress.filesTotal) files" }
        return fallback
    }
}

public extension Int64 {
    /// A size a person can read, in the units Finder uses.
    var byteDescription: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
