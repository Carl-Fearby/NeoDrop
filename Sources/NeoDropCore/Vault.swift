import Foundation

// MARK: - Identity

/// The shared copy of a folder tree that lives on a NAS share and that every machine syncs
/// against.
///
/// Vault mode is two-way: a machine publishes its local changes to the vault and applies the
/// changes other machines published. That only works if the machines share something, and the
/// share itself is the only thing they have in common — so the vault carries its own identity and
/// a journal, and each machine keeps its own identity locally.
public struct VaultIdentity: Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Bumped when the on-disk layout changes in a way older builds cannot read.
    public var formatVersion: Int
    public var createdAt: Date

    public static let currentFormatVersion = 1

    public init(id: UUID = UUID(), name: String, formatVersion: Int = VaultIdentity.currentFormatVersion, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.formatVersion = formatVersion
        self.createdAt = createdAt
    }
}

/// Who this machine is. Stored in local state, never in the vault: a journal belongs to exactly
/// one machine, and two machines must never write the same one.
public struct MachineIdentity: Codable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// A name a human will recognise in "Anna's MacBook (conflicted copy)". Host name is the best
    /// guess available without asking, and it can be edited in Settings.
    public static func defaultName() -> String {
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        let host = ProcessInfo.processInfo.hostName
        return host.isEmpty ? "This Mac" : host.replacingOccurrences(of: ".local", with: "")
    }
}

public struct MachineIdentityStore: Sendable {
    public let paths: StorePaths

    public init(paths: StorePaths = .standard) { self.paths = paths }

    /// Load this machine's identity, creating one on first use. The id must be stable for the life
    /// of the install: it names the journal file, and a machine that changed its id would look
    /// like a brand-new machine to everyone else and stop reading its own history.
    public func loadOrCreate() -> MachineIdentity {
        if let identity = JSONFile.load(MachineIdentity.self, from: paths.machineURL) {
            return identity
        }
        let identity = MachineIdentity(name: MachineIdentity.defaultName())
        try? JSONFile.save(identity, to: paths.machineURL)
        return identity
    }

    public func save(_ identity: MachineIdentity) throws {
        try JSONFile.save(identity, to: paths.machineURL)
    }
}

// MARK: - Paths

/// Vault-relative path handling.
///
/// Two normalisations happen here and both exist because NAS shares are hostile to naive string
/// comparison: SMB mostly ignores case, and macOS hands out decomposed Unicode (NFD) while other
/// machines hand out composed (NFC), so `Café.png` written on one machine compares unequal to
/// `Café.png` written on another unless it is normalised. Every key in the journal, in the cursor
/// and in the merge is `canonical`, and the original spelling is kept only for display and for
/// touching the file system.
public enum VaultPath {
    /// NFC-normalised, no leading/trailing slash, `/` separators.
    public static func normalize(_ path: String) -> String {
        var cleaned = path.precomposedStringWithCanonicalMapping
        while cleaned.hasPrefix("/") { cleaned.removeFirst() }
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        return cleaned
    }

    /// The comparison key: normalised, and case-folded because a share treats `Notes.txt` and
    /// `notes.txt` as the same file. Case-sensitive shares are the rare case; the cost of being
    /// wrong here is duplicated files, not lost ones.
    public static func key(_ path: String) -> String {
        normalize(path).lowercased()
    }

    public static func parent(of path: String) -> String {
        (normalize(path) as NSString).deletingLastPathComponent
    }

    public static func name(of path: String) -> String {
        (normalize(path) as NSString).lastPathComponent
    }

    /// The Dropbox-style name for the copy that lost a conflict.
    public static func conflictedName(
        for path: String,
        machineName: String,
        at date: Date,
        isTaken: (String) -> Bool
    ) -> String {
        let parent = parent(of: path)
        let name = name(of: path) as NSString
        let base = name.deletingPathExtension
        let ext = name.pathExtension
        let stamp = Self.stamp.string(from: date)
        let owner = machineName.isEmpty ? "another Mac" : machineName
        let suffix = " (\(owner)'s conflicted copy \(stamp))"
        var attempt = 1
        while true {
            let candidateName = attempt == 1
                ? "\(base)\(suffix)\(ext.isEmpty ? "" : "." + ext)"
                : "\(base)\(suffix) \(attempt)\(ext.isEmpty ? "" : "." + ext)"
            let candidate = parent.isEmpty ? candidateName : "\(parent)/\(candidateName)"
            if !isTaken(candidate) { return candidate }
            attempt += 1
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Journal

/// One change a machine published to the vault. The journal is append-only, one JSON object per
/// line, one file per machine, which is what makes concurrent writers safe without locking: a
/// machine only ever appends to its own file, and everyone reads all of them.
public struct JournalEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case create
        case update
        case delete
    }

    /// Per-machine, monotonic. Used for tie-breaking and for reporting, never for "is mine newer".
    public var seq: Int
    /// The machine that published it (its `MachineIdentity.id`).
    public var machine: String
    /// Denormalised so a conflict can be named after the machine without a lookup.
    public var machineName: String
    public var at: Date
    public var path: String
    public var kind: Kind
    public var size: Int64
    /// Content hash. Empty only for a deletion of something whose bytes were already gone.
    public var sha256: String
    /// What this entry replaced or removed, so the vault can retain it for recovery.
    public var previousSha256: String?

    public init(
        seq: Int,
        machine: String,
        machineName: String,
        at: Date = Date(),
        path: String,
        kind: Kind,
        size: Int64,
        sha256: String,
        previousSha256: String? = nil
    ) {
        self.seq = seq
        self.machine = machine
        self.machineName = machineName
        self.at = at
        self.path = VaultPath.normalize(path)
        self.kind = kind
        self.size = size
        self.sha256 = sha256
        self.previousSha256 = previousSha256
    }

    /// Deterministic total order, so every machine picks the same winner for the same journal
    /// content. Wall-clock time is used as the primary key because "the later edit wins" is what
    /// people expect, but a conflict never loses data regardless of whose clock was wrong: the
    /// loser is kept as a conflicted copy and in retained versions.
    ///
    /// Two rules matter more than they look.
    ///
    /// Timestamps carry milliseconds (`JournalCoding`), because one-second resolution made two
    /// changes made moments apart compare *equal* — and the tie-break then decided the winner by
    /// machine id, which silently reverted a real edit to the version it replaced. That was a
    /// reproducible data-reverting bug, not a theoretical one.
    ///
    /// And when timestamps still tie, `previousSha256` breaks it: an entry that was written on top
    /// of the other's content is the later one, no matter what either clock said. That is causality
    /// rather than a guess, and it is what makes two machines agree even with skewed clocks. The
    /// remaining tie-break is arbitrary but *identical everywhere*, which is the only other
    /// property that matters.
    public static func precedes(_ left: JournalEntry, _ right: JournalEntry) -> Bool {
        if left.at != right.at { return left.at < right.at }
        if let previous = left.previousSha256, !previous.isEmpty, previous == right.sha256 { return false }
        if let previous = right.previousSha256, !previous.isEmpty, previous == left.sha256 { return true }
        if left.machine != right.machine { return left.machine < right.machine }
        return left.seq < right.seq
    }
}

/// How journal lines are encoded.
///
/// Dates are ISO-8601 *with milliseconds*. `JSONEncoder.DateEncodingStrategy.iso8601` drops the
/// fractional part, and the loss was not cosmetic: two entries written in the same second decoded
/// to the same instant, and the merge then ordered them by machine id — so a change could lose to
/// the version it replaced. Readable on purpose (the journal is a plain-text file a person can
/// open), and the decoder still accepts whole-second timestamps from an older journal.
enum JournalCoding {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractional.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = fractional.date(from: text) ?? whole.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable timestamp: \(text)")
        }
        return decoder
    }
}

/// The vault's current state: what every journal says the tree should be, merged.
public struct VaultState: Sendable {
    /// Live paths, keyed by `VaultPath.key`.
    public var files: [String: JournalEntry] = [:]
    /// Paths whose newest entry is a deletion, keyed the same way.
    public var tombstones: [String: JournalEntry] = [:]

    public init(files: [String: JournalEntry] = [:], tombstones: [String: JournalEntry] = [:]) {
        self.files = files
        self.tombstones = tombstones
    }

    public var fileCount: Int { files.count }

    public var livePaths: [String] { files.values.map(\.path) }
}

/// Reads and writes everything inside `<vaultRoot>/.neodrop/`.
///
/// The live tree stays where it was — `<vaultRoot>/Photos/a.jpg` is a real file you can open in
/// Finder, which is the property that makes this still a NAS tool rather than a proprietary
/// store. The hidden directory holds only what has to be shared: the identity, the journals and
/// the retained versions.
public struct VaultStore: Sendable {
    public let root: URL
    public static let metadataDirectoryName = ".neodrop"

    public init(root: URL) { self.root = root }

    public var metadataURL: URL { root.appendingPathComponent(Self.metadataDirectoryName, isDirectory: true) }
    public var identityURL: URL { metadataURL.appendingPathComponent("vault.json") }
    public var journalsURL: URL { metadataURL.appendingPathComponent("journals", isDirectory: true) }
    public var versionsURL: URL { metadataURL.appendingPathComponent("versions", isDirectory: true) }

    public func journalURL(machine: String) -> URL {
        journalsURL.appendingPathComponent("\(machine).jsonl")
    }

    public func fileURL(for path: String) -> URL {
        root.appendingPathComponent(VaultPath.normalize(path))
    }

    public func versionURL(sha256: String) -> URL {
        versionsURL.appendingPathComponent(sha256)
    }

    // MARK: Identity

    public func loadIdentity() -> VaultIdentity? {
        JSONFile.load(VaultIdentity.self, from: identityURL)
    }

    /// Read the identity, creating the vault on the share if there is not one there yet. This is
    /// what "point at an existing share" and "make a new vault" have in common: whichever machine
    /// arrives first writes the identity, and everyone else adopts it.
    @discardableResult
    public func loadOrCreateIdentity(name: String) throws -> VaultIdentity {
        if let identity = loadIdentity() { return identity }
        try ensureDirectories()
        let identity = VaultIdentity(name: name.isEmpty ? root.lastPathComponent : name)
        try JSONFile.save(identity, to: identityURL)
        return identity
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for directory in [metadataURL, journalsURL, versionsURL] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Regular files in the live tree that no journal entry mentions — bytes put there by hand: a
    /// folder dragged onto the share, a copy made outside NeoDrop, content restored from a backup.
    ///
    /// A stat-per-entry walk with no hashing: most paths are already known, and the caller hashes
    /// only what it decides to adopt.
    public func untrackedFiles(known livePaths: Set<String>, excludes: ExcludeMatcher) -> [String] {
        liveTree(excludes: excludes)
            .filter { !livePaths.contains($0.key) }
            .map(\.path)
    }

    /// The share's live tree as it is now: every regular file, with the path it is spelled with on
    /// disk and its size.
    ///
    /// One walk answers every question a sync still has about the share — "is what the journal says
    /// is there still there, at the size we recorded?" and "did a person drop something in?" —
    /// which is why this exists at all rather than a check per path: on a share holding thousands of
    /// files, per-path checks are thousands of round trips, and this is one enumeration. Order is
    /// the filesystem's, so callers that care about order (adoption, and the journal sequence it
    /// writes) see the same order they always did.
    public func liveTree(excludes: ExcludeMatcher) -> [(key: String, path: String, size: Int64)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [(key: String, path: String, size: Int64)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = url.lastPathComponent
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if name == Self.metadataDirectoryName {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true {
                if excludes.matchesDirectory(named: name) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let relative = Scanner.relativePath(of: url, under: root)
            if excludes.matches(fileName: name, relativePath: relative) { continue }
            files.append((VaultPath.key(relative), relative, Int64(values.fileSize ?? 0)))
        }
        return files
    }

    /// The byte size of every journal file, by name.
    ///
    /// A journal is append-only, so "has any of them grown?" is an exact answer to "has another
    /// machine published anything since I looked?" — exact where a timestamp is not (two entries can
    /// share a millisecond) and cheaper than reading them, since it is one stat per machine.
    public func journalSizes() -> [String: Int64] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: journalsURL.path) else { return [:] }
        var sizes: [String: Int64] = [:]
        for name in names where name.hasSuffix(".jsonl") {
            let attributes = try? fm.attributesOfItem(atPath: journalsURL.appendingPathComponent(name).path)
            sizes[name] = ((attributes?[.size] as? NSNumber)?.int64Value) ?? 0
        }
        return sizes
    }

    /// True when the directory looks like a vault (or is an empty folder we can turn into one).
    public func isVaultOrEmpty() -> Bool {
        if loadIdentity() != nil { return true }
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        let visible = contents.filter { $0 != ".DS_Store" && $0 != Self.metadataDirectoryName }
        return visible.isEmpty
    }

    // MARK: Journals

    /// Append to this machine's journal. One `write` per entry, each ending in a newline, so a
    /// crash can only ever leave a torn *last* line — which `loadEntries` tolerates.
    public func append(_ entries: [JournalEntry], machineID: String) throws {
        guard !entries.isEmpty else { return }
        try ensureDirectories()
        let url = journalURL(machine: machineID)
        var payload = Data()
        let encoder = JournalCoding.encoder()
        for entry in entries {
            payload.append(try encoder.encode(entry))
            payload.append(0x0a)
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try payload.write(to: url, options: .atomic)
            try? AtomicFile.flush(fileAt: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
        try handle.synchronize()
    }

    /// Everything every machine has published, plus the lines that could not be read.
    ///
    /// A torn final line is not an error: it is what a crash or a pulled cable during an append
    /// looks like, and the change it described is still on disk to be re-published on the next
    /// reconcile. A torn line *in the middle* is real corruption and is reported.
    public func loadEntries() -> (entries: [JournalEntry], errors: [String]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: journalsURL.path) else { return ([], []) }
        let decoder = JournalCoding.decoder()
        var entries: [JournalEntry] = []
        var errors: [String] = []

        for name in names.sorted() where name.hasSuffix(".jsonl") {
            let url = journalsURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else {
                errors.append("journal \(name) could not be read")
                continue
            }
            let lines = data.split(separator: 0x0a, omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if line.isEmpty { continue }
                if let entry = try? decoder.decode(JournalEntry.self, from: Data(line)) {
                    entries.append(entry)
                    continue
                }
                let isLast = index == lines.count - 1
                if isLast {
                    // Torn tail: ignore it silently, the next reconcile re-publishes the change.
                    continue
                }
                errors.append("journal \(name) has an unreadable line \(index + 1)")
            }
        }
        return (entries, errors)
    }

    /// Merge every journal into one view of the tree. The newest entry for a path wins; a delete
    /// is just another entry, which is what stops a deleted file from coming back on the next
    /// machine that still has it.
    public func state(from entries: [JournalEntry]) -> VaultState {
        var newest: [String: JournalEntry] = [:]
        for entry in entries {
            let key = VaultPath.key(entry.path)
            if let current = newest[key], !JournalEntry.precedes(current, entry) { continue }
            newest[key] = entry
        }
        var state = VaultState()
        for (key, entry) in newest {
            if entry.kind == .delete {
                state.tombstones[key] = entry
            } else {
                state.files[key] = entry
            }
        }
        return state
    }

    /// The next per-machine sequence number. A pass should ask `VaultSync.nextSequence(in:machineID:)`
    /// instead when it already holds the entries: this reads and decodes every journal to answer a
    /// question about one of them.
    public func nextSequence(machineID: String) -> Int {
        let entries = loadEntries().entries.filter { $0.machine == machineID }
        return (entries.map(\.seq).max() ?? 0) + 1
    }

    // MARK: Retained versions

    /// Keep a copy of content that is about to leave the live tree — overwritten by another
    /// machine's edit, or deleted. Content-addressed, so the same bytes are never stored twice.
    @discardableResult
    public func retainVersion(from source: URL, sha256: String) -> Bool {
        guard !sha256.isEmpty else { return false }
        let destination = versionURL(sha256: sha256)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return true }
        do {
            try ensureDirectories()
            try AtomicFile.copy(from: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    public func hasVersion(sha256: String) -> Bool {
        !sha256.isEmpty && FileManager.default.fileExists(atPath: versionURL(sha256: sha256).path)
    }

    /// Whether any journal entry still points at this content in a way that matters: as the
    /// current version of a live path, or as something a machine could still be asked to restore.
    public func retainableVersions(from entries: [JournalEntry], within window: TimeInterval, now: Date) -> Set<String> {
        var keep: Set<String> = []
        for entry in entries {
            guard now.timeIntervalSince(entry.at) <= window else { continue }
            keep.insert(entry.sha256)
            if let previous = entry.previousSha256 { keep.insert(previous) }
        }
        return keep
    }

    /// Hand back the space of versions no machine can still need, once their window has closed.
    @discardableResult
    public func purgeVersions(keeping keep: Set<String>, olderThan window: TimeInterval, now: Date) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: versionsURL.path) else { return 0 }
        var purged = 0
        for name in names where !name.hasPrefix(".") {
            guard !keep.contains(name) else { continue }
            let url = versionsURL.appendingPathComponent(name)
            let modified = FileMeta.modificationDate(ofFileAt: url) ?? .distantPast
            guard now.timeIntervalSince(modified) > window else { continue }
            if (try? fm.removeItem(at: url)) != nil { purged += 1 }
        }
        return purged
    }
}

// MARK: - Local state for one vault on one machine

/// What this machine and the vault last agreed on, per path.
///
/// This is the merge base of a three-way comparison: `local != base` means this machine changed
/// the file, `vault != base` means someone else did, and both at once is a conflict. Stored
/// locally because it is per-machine knowledge, exactly like the identity.
public struct VaultCursor: Codable, Sendable {
    public var vaultID: UUID
    public var machineID: UUID
    /// Canonical path -> content hash both sides agreed on. `""` means "agreed that it is gone".
    public var applied: [String: String]
    public var lastSync: Date?
    /// Last path processed in a bounded catch-up pass. Nil means the current tree was fully walked.
    public var catchUpAfter: String?
    /// Changed paths discovered behind the page cursor, carried forward until reconciled.
    public var catchUpDirtyPaths: [String]?
    /// The newest journal entry this machine has finished a pass over, in milliseconds since 1970.
    ///
    /// Milliseconds rather than a `Date` on purpose: this file is written as ISO-8601 to whole
    /// seconds while the journal keeps milliseconds, so an entry published in the same second this
    /// pass finished would compare as *newer* than a whole-second watermark and be re-checked for
    /// ever. An integer round-trips exactly.
    ///
    /// It is a heuristic, and it only decides what is re-checked *early*: a change the page walk
    /// has left behind is picked up by the next walk over the tree regardless of what this says.
    public var catchUpSeenAt: Int64?
    /// The journal files' byte sizes as this machine last saw them *before* a pass it finished.
    ///
    /// This is what makes a sync that has nothing to do provable rather than a guess: journals only
    /// grow, so equal sizes mean nothing has been published to the vault since, and a tree this
    /// machine agrees with cannot have changed behind its back. Nil means no completed pass to
    /// compare against, which is a fresh install or a cleared state directory — it always walks.
    ///
    /// Recorded from the sizes read at the *start* of a pass, on purpose: if another machine appends
    /// while that pass runs, the record stays behind reality and the next pass walks, which is the
    /// safe direction. Our own appends have the same effect, and cost one extra walk after a sync
    /// that published something.
    public var catchUpJournalBytes: [String: Int64]?

    public init(
        vaultID: UUID,
        machineID: UUID,
        applied: [String: String] = [:],
        lastSync: Date? = nil,
        catchUpAfter: String? = nil,
        catchUpDirtyPaths: [String]? = nil,
        catchUpSeenAt: Int64? = nil,
        catchUpJournalBytes: [String: Int64]? = nil
    ) {
        self.vaultID = vaultID
        self.machineID = machineID
        self.applied = applied
        self.lastSync = lastSync
        self.catchUpAfter = catchUpAfter
        self.catchUpDirtyPaths = catchUpDirtyPaths
        self.catchUpSeenAt = catchUpSeenAt
        self.catchUpJournalBytes = catchUpJournalBytes
    }
}

public struct VaultCursorStore: Sendable {
    public let paths: StorePaths

    public init(paths: StorePaths = .standard) { self.paths = paths }

    public func load(vaultID: UUID) -> VaultCursor? {
        JSONFile.load(VaultCursor.self, from: paths.vaultCursorURL(vaultID: vaultID))
    }

    public func save(_ cursor: VaultCursor) throws {
        try JSONFile.save(cursor, to: paths.vaultCursorURL(vaultID: cursor.vaultID))
    }
}

/// Files this machine has deliberately put back after a deletion reached it, waiting to be published.
///
/// A restore and a Mac that was asleep through the deletion look *identical* in a folder: a local
/// file sitting at a path the journal says was deleted, with the content the deletion removed. They
/// must not be treated the same way, though — for the Mac that missed the delete the deletion has to
/// win (that is what makes deleting on one Mac stick), while a restore is an instruction to undo it.
/// Without this marker the first version of two-way restore produced a conflicted copy and the
/// deletion stood, which is not what the Restore button says it does.
public struct PendingUndeleteStore: Sendable {
    public let paths: StorePaths

    public init(paths: StorePaths = .standard) { self.paths = paths }

    /// `path → sha256` of what was restored, keyed by `VaultPath.key`.
    public func load(linkID: UUID) -> [String: String] {
        JSONFile.load([String: String].self, from: paths.vaultUndeleteURL(linkID: linkID)) ?? [:]
    }

    public func mark(relativePath: String, sha256: String, linkID: UUID) {
        guard !sha256.isEmpty else { return }
        var pending = load(linkID: linkID)
        pending[VaultPath.key(relativePath)] = sha256
        try? JSONFile.save(pending, to: paths.vaultUndeleteURL(linkID: linkID))
    }

    public func clear(_ key: String, linkID: UUID) {
        var pending = load(linkID: linkID)
        guard pending.removeValue(forKey: key) != nil else { return }
        try? JSONFile.save(pending, to: paths.vaultUndeleteURL(linkID: linkID))
    }

    /// Drop markers for paths the journal no longer calls deleted: the file is back in the tree on
    /// its own terms, so there is nothing left to publish. Without this a marker for a path that a
    /// later sync re-created would sit there forever and quietly turn a future stale copy into an
    /// undelete.
    public func prune(keeping keys: Set<String>, linkID: UUID) {
        let pending = load(linkID: linkID)
        guard !pending.isEmpty else { return }
        let kept = pending.filter { keys.contains($0.key) }
        guard kept.count != pending.count else { return }
        try? JSONFile.save(kept, to: paths.vaultUndeleteURL(linkID: linkID))
    }
}

// MARK: - Configuration

/// A folder on this machine paired with the vault it syncs with. This is the two-way counterpart
/// of a `Replica`, which stays a one-way destination.
public struct VaultLink: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// The share root that holds the live tree and the hidden `.neodrop/` directory.
    public var vaultPath: String
    /// This machine's folder, the working copy.
    public var localPath: String
    public var smbURL: String?
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        vaultPath: String,
        localPath: String,
        smbURL: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.vaultPath = vaultPath
        self.localPath = localPath
        self.smbURL = smbURL
        self.enabled = enabled
    }

    public var vaultURL: URL { URL(fileURLWithPath: vaultPath) }
    public var localURL: URL { URL(fileURLWithPath: localPath) }

    public var displayName: String {
        name.isEmpty ? vaultURL.lastPathComponent : name
    }
}
