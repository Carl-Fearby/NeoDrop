import AppKit
import FinderSync

/// The badge in Finder, next to a file's date — the "is this protected?" glance.
///
/// This runs inside Finder, in its own process, with no way to ask the app anything: it may start
/// before the app, outlive it, or run while the app is busy. So the app publishes what it knows as a
/// small file (`FinderStatusIndex`) and this reads it. Everything here is therefore a lookup, never a
/// walk and never a hash — Finder asks for badges while scrolling, and a badge that takes a directory
/// enumeration to answer is a badge that makes the Finder stutter.
///
/// It reads the index from its own sandbox container — the one place a sandboxed process may read,
/// and where the app publishes it from outside, provided the two bundles share a team identity (see
/// `FinderStatusIndex.extensionIndexURL` for the measurements behind both, and for why an App Group
/// cannot be used). It does not read the app's own
/// state directory, which the sandbox would refuse anyway, and it does not follow `NEODROP_HOME`: the
/// extension is registered once for the installed app, and a second installation (which the end-to-end
/// scripts use) is not what the Finder showing the user's files should be about.
@objc(NeoDropFinderExtension)
final class NeoDropFinderExtension: FIFinderSync {
    private var indexURL: URL? { FinderStatusIndex.extensionIndexURL() }

    private var index: FinderStatusIndex?
    /// The index file's modification date when it was read, so a reload can be skipped.
    private var indexStamp: Date?
    /// The URLs Finder has asked about, newest last, so a change to the index can be pushed to what is
    /// on screen. Bounded: an extension that remembers every file in a 4 TB library is a leak.
    private var seen: [String: Date] = [:]
    private static let rememberedLimit = 20_000
    /// Polling, not FSEvents: the index is one small file written by another process, and a stat every
    /// couple of seconds is cheaper than a watched-directory setup for a single path.
    private var timer: DispatchSourceTimer?

    override init() {
        super.init()
        let controller = FIFinderSyncController.default()
        for badge in FinderBadge.allCases {
            controller.setBadgeImage(Self.image(for: badge), label: badge.label, forBadgeIdentifier: badge.rawValue)
        }
        reloadIndex()
        applyWatchedDirectories()
        startWatching()
    }

    deinit {
        timer?.cancel()
    }

    // MARK: - Badges

    override func requestBadgeIdentifier(for url: URL) {
        guard let index, let badge = index.badgeIncludingDescendants(forPath: url.path) else {
            // Nothing NeoDrop has an opinion about: no badge at all, which is what an untouched file
            // in an untouched folder should look like.
            return
        }
        remember(url.path)
        FIFinderSyncController.default().setBadgeIdentifier(badge.rawValue, for: url)
    }

    /// Directories Finder is looking at. Unused for the answer — `badgeIncludingDescendants` already
    /// summarises a folder's exceptions — but it is where a "this folder is syncing" state would be
    /// pushed from when the app reports progress per folder.
    override func beginObservingDirectory(at url: URL) {}

    override func endObservingDirectory(at url: URL) {}

    // MARK: - The menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "Show NeoDrop Status",
                              action: #selector(openStatus(_:)),
                              keyEquivalent: "")
        item.target = self
        menu.addItem(item)

        if let index, let first = FIFinderSyncController.default().selectedItemURLs()?.first,
           let badge = index.badge(for: first.path) {
            // Why the badge says what it says, in the menu itself: a tooltip is not where a person
            // looks when a green tick is wrong.
            let line = NSMenuItem(title: badge.label, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        return menu
    }

    /// Opens the app's own status window for the selection, through the URL scheme the app registers.
    /// The extension cannot draw the report itself: it has no engine, and a second copy of the logic
    /// would be a second answer.
    @objc private func openStatus(_ sender: Any?) {
        guard let url = FIFinderSyncController.default().selectedItemURLs()?.first else { return }
        var components = URLComponents()
        components.scheme = "neodrop"
        components.host = "status"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        guard let target = components.url else { return }
        NSWorkspace.shared.open(target)
    }

    // MARK: - Keeping up with the app

    private func startWatching() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.reloadIndexIfChanged()
        }
        timer.resume()
        self.timer = timer
    }

    private func reloadIndex() {
        guard let url = indexURL else {
            index = nil
            indexStamp = nil
            return
        }
        indexStamp = Self.modificationDate(of: url)
        index = FinderStatusIndex.load(from: url)
    }

    private func reloadIndexIfChanged() {
        guard let url = indexURL else { return }
        let stamp = Self.modificationDate(of: url)
        guard stamp != indexStamp else { return }
        reloadIndex()
        applyWatchedDirectories()
        pushBadges()
    }

    /// Tell Finder which directories are NeoDrop's — and tell it again every time the index changes.
    ///
    /// The repetition looks redundant and is the fix for a bug that is easy to miss, because the state
    /// was right and only the icons were wrong. FinderSync has no "refresh" call: a badge is drawn when
    /// Finder *asks* about an item, and a freshly launched extension process has been asked about
    /// nothing. So assigning `directoryURLs` once at startup, and only re-assigning it when the set of
    /// roots changes, left everything already on screen unbadged after this process started — which
    /// Finder does on its own schedule, and after any relaunch of the app. Measured with a Finder window
    /// open while the index was deleted and republished: re-assigning the same set is what makes Finder
    /// ask again, and the badges come back without the user touching anything.
    ///
    /// It also covers the other half of the setting: a destination added in Settings becomes a folder
    /// Finder can badge, and a removed one stops being watched rather than keeping files badged that
    /// NeoDrop no longer protects.
    private func applyWatchedDirectories() {
        FIFinderSyncController.default().directoryURLs = Set(
            (index?.watchedPaths ?? []).map { URL(fileURLWithPath: $0) }
        )
    }

    /// Re-apply the badges Finder is already showing, so a sync completing — or an edit — appears
    /// without the user doing anything.
    ///
    /// Two sets of paths, and the second is the one that matters. `seen` is what Finder has asked
    /// about, which is what a file whose badge has *returned to normal* needs (a green tick has to be
    /// put back explicitly; FinderSync cannot unset a badge). The exception paths are pushed even when
    /// Finder has not asked: they are the files that need attention, the index is small by construction
    /// precisely because it holds only those, and a file that needs attention while the user is
    /// looking at its folder is the whole point of the badge. Pushing only `seen` left exactly those
    /// icons missing in an open window after Finder relaunched the extension, which is how this was
    /// found: the state was right and two clocks were invisible.
    private func pushBadges() {
        let cutoff = Date().addingTimeInterval(-300)
        seen = seen.filter { $0.value > cutoff }
        var paths = Set(seen.keys)
        paths.formUnion(index.map { Array($0.exceptions.keys) } ?? [])
        for path in paths {
            guard let badge = index?.badgeIncludingDescendants(forPath: path) else { continue }
            FIFinderSyncController.default().setBadgeIdentifier(badge.rawValue, for: URL(fileURLWithPath: path))
        }
    }

    private func remember(_ path: String) {
        seen[path] = Date()
        guard seen.count > Self.rememberedLimit else { return }
        // Drop the oldest half rather than one at a time: this runs in Finder's scroll path.
        let oldest = seen.sorted { $0.value < $1.value }.prefix(Self.rememberedLimit / 2)
        for entry in oldest { seen[entry.key] = nil }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Badge artwork

    /// Drawn from system symbols rather than shipped as files: the badge has to look like the rest of
    /// Finder, and a coloured symbol already does. The colours are the only signal Finder gives us, so
    /// they mean what the app's own status colours mean.
    private static func image(for badge: FinderBadge) -> NSImage {
        let colour: NSColor
        switch badge {
        case .synced: colour = .systemGreen
        case .waiting: colour = .systemBlue
        case .working: colour = .controlAccentColor
        case .attention: colour = .systemOrange
        case .held: colour = .systemGray
        case .foreign: colour = .systemPurple
        case .ignored: colour = .tertiaryLabelColor
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [colour]))
        let image = NSImage(systemSymbolName: badge.symbolName, accessibilityDescription: badge.label)?
            .withSymbolConfiguration(configuration)
        image?.size = NSSize(width: 14, height: 14)
        return image ?? NSImage(size: NSSize(width: 14, height: 14))
    }
}
