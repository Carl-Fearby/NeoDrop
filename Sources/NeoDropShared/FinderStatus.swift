import Foundation

/// What one file or folder's badge in Finder says.
///
/// A Finder Sync extension cannot ask the app anything: it is started by Finder, may outlive the app
/// and has no channel to it. So the app publishes its knowledge to a small file, and this file is the
/// shared vocabulary — the app writes it, the extension reads it, and both sides agree on what a
/// badge means. It is deliberately split into its own module with no dependencies so the extension
/// can be compiled against it without dragging the engine in.
///
/// The badges are a *summary*, not the report: `FileStatusQuery` answers "is this file safe?" in
/// detail, and this answers "does this folder look right?" at a glance, which is the only thing a
/// badge can carry.
public enum FinderBadge: String, Codable, Sendable, CaseIterable {
    /// Here and copied to every destination NeoDrop recorded. The default, and by far the most
    /// common state — which is why the index stores only exceptions to it.
    case synced
    /// Here, but not copied everywhere yet: new or edited since the last sync, or a destination was
    /// not reachable when it ran. This is the badge that means "wait, or run Sync Now".
    case waiting
    /// NeoDrop is reading or writing this exact file right now.
    case working
    /// A destination copy is missing or no longer matches what NeoDrop recorded. Needs Verify &
    /// Repair, or the file put back.
    case attention
    /// Bytes NeoDrop is deliberately holding after a deletion — recoverable from Deleted Files.
    case held
    /// On a destination, but not written by NeoDrop: someone put it there by hand. NeoDrop will not
    /// delete or overwrite it.
    case foreign
    /// Nothing to do with NeoDrop, inside a folder it protects but matching an ignore pattern.
    case ignored

    /// What Finder shows in its menu and tooltip. Short: it is a menu item in a long list.
    public var label: String {
        switch self {
        case .synced: return "In sync"
        case .waiting: return "Waiting to sync"
        case .working: return "Syncing now"
        case .attention: return "Needs attention"
        case .held: return "Kept by NeoDrop"
        case .foreign: return "Not written by NeoDrop"
        case .ignored: return "Ignored"
        }
    }

    /// An SF Symbol name. The extension draws the badge itself rather than shipping artwork: it is a
    /// separate bundle, and a system symbol already looks like the rest of the Finder chrome.
    public var symbolName: String {
        switch self {
        case .synced: return "checkmark.circle.fill"
        case .waiting: return "clock.badge.checkmark"
        case .working: return "arrow.triangle.2.circlepath"
        case .attention: return "exclamationmark.triangle.fill"
        case .held: return "trash.circle.fill"
        case .foreign: return "questionmark.circle.fill"
        case .ignored: return "minus.circle"
        }
    }

    /// How loudly it should speak when a folder has to summarise its contents. Higher wins, so a
    /// folder containing one file needing attention shows attention rather than a green tick.
    /// `synced` is lowest because "everything inside is fine" is the state that says nothing.
    public var severity: Int {
        switch self {
        case .synced: return 0
        case .ignored: return 1
        case .held: return 2
        case .foreign: return 3
        case .waiting: return 4
        case .attention: return 5
        case .working: return 6
        }
    }

    /// The worst of two badges, for summarising a directory.
    public static func worst(_ badges: [FinderBadge]) -> FinderBadge? {
        badges.max { $0.severity < $1.severity }
    }
}

/// A folder NeoDrop watches, and what it is in the arrangement.
public struct FinderRoot: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// A protected folder on this Mac.
        case source
        /// This Mac's half of a two-way folder.
        case vaultLocal
        /// A destination: a NAS copy, or a vault's live tree on the share.
        case destination
    }

    public var path: String
    public var name: String
    public var kind: Kind

    public init(path: String, name: String, kind: Kind) {
        self.path = path
        self.name = name
        self.kind = kind
    }

    /// The badge for anything inside this root that no exception covers. Everything NeoDrop watches
    /// defaults to "in sync" because the index only records what is *not*.
    public var defaultBadge: FinderBadge { .synced }
}

/// What the app publishes for the Finder extension to read.
///
/// `exceptions` holds only the paths whose badge is not the root's default, so in a healthy library
/// it is empty and the file is a few hundred bytes no matter how many files are protected. That is
/// what makes a per-file badge possible at all: the extension never walks a tree, and it never hashes
/// anything — it looks up one path in a dictionary and falls back to its root.
///
/// An entry may name a directory, in which case it covers everything below it (a trash directory is
/// marked once, not once per retained copy), and the longest matching entry wins.
public struct FinderStatusIndex: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// Where the app writes it and the extension reads it, relative to the support directory.
    public static let fileName = "finder-status.json"
    /// The directory inside that support directory, so the index sits in one named folder rather
    /// than loose beside whatever else is there.
    public static let badgesDirectoryName = "NeoDrop"
    /// The Finder extension's bundle identifier — and therefore the name of the container the app
    /// publishes into. Kept next to the path that uses it so the two cannot drift apart; must match
    /// `CFBundleIdentifier` in packaging/FinderExtension-Info.plist.in, which scripts/verify.sh checks
    /// against the shipped app.
    public static let extensionBundleIdentifier = "ai.storyteller.neodrop.finder"

    // MARK: - The one file both sides meet over

    /// Where the **extension** reads the index: `<its own Application Support>/NeoDrop/finder-status.json`.
    ///
    /// Inside the extension that resolves into its sandbox container, which is the only place a
    /// sandboxed process may read, and the app writes to exactly that directory from outside. Measured
    /// on macOS 26 while building this, because the obvious answer does not work:
    ///
    ///   * An extension **must be sandboxed**: PlugInKit refuses to register one that is not, saying
    ///     "plug-ins must be sandboxed" in the system log and nowhere else.
    ///   * The **app** must *not* be sandboxed: it reads and writes mounted shares under `/Volumes`,
    ///     which the App Sandbox forbids.
    ///   * So an App Group looks like the answer, and it is not. `~/Library/Group Containers` is closed
    ///     to an unsandboxed process: writing into the group container failed with EPERM as an ad-hoc
    ///     signature *and* signed with an Apple Development certificate ("You don't have permission to
    ///     save the file … in the folder group.…"), and a sandboxed process is refused as well when the
    ///     container was created by another bundle. A badge index nothing can write is no badge index.
    ///   * The container is where the two processes meet — **when they share a team identity**. Since
    ///     macOS 14 a container is protected from processes outside the team that owns it, so an ad-hoc
    ///     signature, which has no team at all, is refused with "You don't have permission to save the
    ///     file …" and the badges stay dark. Measured on macOS 26: refused ad-hoc, published as soon as
    ///     both bundles carried one Apple Development identity. The app also has to be started by
    ///     LaunchServices rather than from a shell, because the check follows the responsible process —
    ///     `swift run NeoDrop` therefore badges nothing even when signed. scripts/verify.sh fails a
    ///     build whose two bundles disagree on the team; AGENTS.md has the log lines.
    ///
    /// Neither side needs an entitlement for this: the extension keeps the App Sandbox and nothing
    /// else, which is also the smallest thing it could be granted while still being registerable.
    ///
    /// Nil only when Application Support cannot be resolved at all.
    public static func extensionIndexURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent(badgesDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// The same file as the **app** resolves it: the extension's container on the real file system.
    ///
    /// `extensionIndexURL` is correct wherever it is called and therefore deliberately relative — the
    /// sandbox answers it with the container's own `Library`. The app is outside the sandbox, so it has
    /// to name the container to reach the identical directory, and the pieces are spelled out from the
    /// home directory rather than by asking for `libraryDirectory` (which, for the app, is the real
    /// `~/Library`).
    ///
    /// Nothing has to exist first: `save(to:)` creates the directory it needs, which is what lets the
    /// app publish before the extension has ever run. The container the extension creates for itself on
    /// first launch is the same directory, so either order ends with the two processes agreeing —
    /// subject to the team identity above, which is what makes this call fail rather than the path.
    public static func extensionContainerIndexURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(extensionBundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(badgesDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public var version: Int
    public var generatedAt: Date
    /// This machine's name, so the extension can say which Mac published a state.
    public var machineName: String
    public var roots: [FinderRoot]
    /// Absolute path → badge, for paths whose badge is not the default. Paths are resolved
    /// (`PathsForBadges.resolve`), which is what lets the extension compare the URL Finder hands it
    /// with the strings the app wrote.
    public var exceptions: [String: FinderBadge]

    public init(
        version: Int = FinderStatusIndex.currentVersion,
        generatedAt: Date = Date(),
        machineName: String = "",
        roots: [FinderRoot] = [],
        exceptions: [String: FinderBadge] = [:]
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.machineName = machineName
        self.roots = roots
        self.exceptions = exceptions
    }

    // MARK: - Building

    public mutating func set(_ badge: FinderBadge, forPath path: String) {
        let resolved = PathsForBadges.resolve(path)
        guard !resolved.isEmpty else { return }
        exceptions[resolved] = badge
    }

    /// Record the worst of two badges for a path, so two reasons for the same file do not hide each
    /// other (a file waiting to upload *and* damaged elsewhere is damaged).
    public mutating func merge(_ badge: FinderBadge, forPath path: String) {
        let resolved = PathsForBadges.resolve(path)
        guard !resolved.isEmpty else { return }
        if let existing = exceptions[resolved] {
            exceptions[resolved] = FinderBadge.worst([existing, badge])
        } else {
            exceptions[resolved] = badge
        }
    }

    // MARK: - Asking

    /// The watched folder a path belongs to, if any. Longest match wins, so a destination nested
    /// inside a source (a mistake the configuration validator warns about) still resolves to the
    /// more specific one.
    public func root(containing path: String) -> FinderRoot? {
        // Both sides are resolved here, not just the query: a root is stored as the configuration
        // spells it (`/Volumes/…`, a path typed into Settings, anything) while the query arrives as
        // whatever spelling Finder handed over, and comparing one resolved string with one raw string
        // is how a watched folder stops matching its own files.
        let resolved = PathsForBadges.resolve(path)
        var best: (path: String, root: FinderRoot)?
        for root in roots {
            let rootPath = PathsForBadges.resolve(root.path)
            guard PathsForBadges.contains(rootPath, resolved) else { continue }
            if let current = best, current.path.count >= rootPath.count { continue }
            best = (rootPath, root)
        }
        return best?.root
    }

    /// The badge for one item, or nil when no watched folder contains it — which the extension shows
    /// as no badge at all, because a file NeoDrop has nothing to do with should look untouched.
    public func badge(for path: String) -> FinderBadge? {
        let resolved = PathsForBadges.resolve(path)
        guard let root = root(containing: resolved) else { return nil }
        return badge(resolved: resolved, default: root.defaultBadge)
    }

    /// The badge for a folder: the worst badge of anything inside it that NeoDrop has an opinion
    /// about. Scans the exception keys rather than the file system, which is why a folder with a
    /// million files and no exceptions costs the same as an empty one.
    public func badgeIncludingDescendants(forPath path: String) -> FinderBadge? {
        let resolved = PathsForBadges.resolve(path)
        guard let root = root(containing: resolved) else { return nil }
        var badges: [FinderBadge] = [badge(resolved: resolved, default: root.defaultBadge)]
        for (key, badge) in exceptions where PathsForBadges.contains(resolved, key) {
            badges.append(badge)
        }
        return FinderBadge.worst(badges)
    }

    private func badge(resolved: String, default fallback: FinderBadge) -> FinderBadge {
        var best: (path: String, badge: FinderBadge)?
        for (key, badge) in exceptions where PathsForBadges.contains(key, resolved) {
            if let current = best, current.path.count >= key.count { continue }
            best = (key, badge)
        }
        return best?.badge ?? fallback
    }

    /// The paths Finder should be asked to badge. A destination is included so browsing the NAS in
    /// Finder shows whether a copy is NeoDrop's, one it is holding, or somebody else's.
    ///
    /// Resolved, because these become the URLs Finder monitors: registering the wrong spelling of a
    /// directory means Finder never asks about the files inside it.
    public var watchedPaths: [String] { roots.map { PathsForBadges.resolve($0.path) } }
}

// MARK: - Reading and writing

extension FinderStatusIndex {
    /// The two processes that meet over this file — the app writing it, Finder's extension reading it
    /// — need the same encoding on both sides, and they cannot share the engine's `JSONFile` (the
    /// extension does not link it). So the format owns its own coding, with whole-second ISO-8601
    /// dates, which both sides read the same way.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Write atomically: Finder may read this at any moment, including while the app is writing it,
    /// and half an index is worse than a stale one.
    public func save(to url: URL) throws {
        let data = try Self.encoder().encode(self)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(6))")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    /// Nil when there is no index or it cannot be read. A missing index means "the app has never
    /// published one", which the extension shows as no badges rather than as everything being fine —
    /// claiming "in sync" on no evidence is exactly the lie a badge must not tell.
    public static func load(from url: URL) -> FinderStatusIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// The same bytes the file holds, for the channel that does not use a file: the app answers the
    /// extension over XPC with exactly this encoding, so a build with a team identity (which reads
    /// the file) and an ad-hoc one (which asks the app) cannot disagree about what an index says.
    public func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    /// Nil for bytes that are not an index, and for one written by a newer NeoDrop: a future index
    /// may mean something this build cannot answer, and a wrong badge is worse than no badge.
    public static func decode(_ data: Data) -> FinderStatusIndex? {
        guard let index = try? decoder().decode(FinderStatusIndex.self, from: data) else { return nil }
        guard index.version <= currentVersion else { return nil }
        return index
    }
}

/// Path comparison for badge lookups, shared by the app and the extension.
///
/// The app writes paths through `PathIdentity.canonical` and the extension sees URLs from Finder, and
/// the two spellings of one directory must not disagree: `/var/…` and `/private/var/…` are the same
/// place, and a badged file that is compared as a different string simply never matches. Resolving
/// the existing prefix is what both sides do; nothing is resolved for a path that no longer exists,
/// which is exactly the case for a retained copy.
///
/// The direction matters and was measured rather than assumed: `resolvingSymlinksInPath` normalises
/// *towards* the short spelling on macOS (an existing `/private/tmp/x` becomes `/tmp/x`, and
/// `/private/var/…` becomes `/var/…`), which is the same spelling `PathIdentity.canonical` produces,
/// because it resolves component by component with the same primitive. Both sides are therefore
/// stable, and a test holds it (`testTheTwoSpellingsOfOneDirectoryAreTheSamePath`).
public enum PathsForBadges {
    public static func resolve(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }

    /// Is `child` the same as `parent`, or inside it?
    public static func contains(_ parent: String, _ child: String) -> Bool {
        if parent == child { return true }
        return child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
}
