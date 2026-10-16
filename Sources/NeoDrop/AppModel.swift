import Foundation
import AppKit
import NeoDropCore
import NeoDropShared
import ServiceManagement
import UserNotifications

/// Everything the UI reads and everything the menu triggers. Owns the engine, the FSEvents
/// watcher, the timers and the persisted configuration.
@MainActor
final class AppModel: ObservableObject {
    @Published var config: AppConfig {
        didSet {
            guard !isLoadingConfig else { return }
            schedulePersist()
        }
    }

    @Published private(set) var snapshots: [ReplicaSnapshot] = []
    /// One entry per configured vault: what the last reconcile did, and when.
    @Published private(set) var vaultStatuses: [UUID: VaultStatus] = [:]
    /// This machine's name — what other machines see on conflicted copies and in the log.
    @Published private(set) var machineName: String = ""
    @Published private(set) var progress = SyncProgress(phase: .idle)
    @Published private(set) var summary: SyncSummary?
    @Published private(set) var activity: [NeoDropLog.LogEntry] = []
    @Published private(set) var issues: [ConfigIssue] = []
    @Published private(set) var stats = SourceStats(fileCount: 0, byteCount: 0, missingSources: [])
    @Published private(set) var isBusy = false
    @Published private(set) var isWatching = false
    @Published var banner: String?
    @Published var launchAtLogin = false

    var onOpenSettings: (() -> Void)?
    var onOpenDeletedFiles: (() -> Void)?
    var onOpenSetup: (() -> Void)?
    /// Show the status of one file from Finder's Services menu. A nil path asks the user which file;
    /// that is what the menu item does.
    var onOpenFileStatus: ((String?) -> Void)?
    var onOpenActivity: (() -> Void)?

    let paths: StorePaths
    let engine: MirrorEngine
    /// Two-way sync, one vault at a time. Separate from `engine` on purpose: a mirror and a vault
    /// are different jobs with different failure modes, and a vault that cannot be reached must not
    /// stop the mirror from running.
    let vaultEngine: VaultSync
    private let configStore: ConfigStore
    private let machineStore: MachineIdentityStore

    /// The loopback page behind “Deleted Files…”. Started once at launch; `deletedFilesURL` is
    /// what the web view loads, and nil only while the server is coming up or if it failed.
    private var webServer: WebUIServer?
    @Published private(set) var deletedFilesURL: URL?
    /// How many deletions are currently recoverable, for the menu badge.
    @Published private(set) var deletionCount = 0

    /// The menu item is only useful once there is a page to open.
    var deletedFilesAvailable: Bool { deletedFilesURL != nil }

    private var watcher: FolderWatcher?
    private var timer: Timer?
    private var verifyTimer: Timer?
    private var persistTask: Task<Void, Never>?
    private var isLoadingConfig = false
    private var lastSyncFinished: Date?

    init(paths: StorePaths = .standard) {
        self.paths = paths
        self.configStore = ConfigStore(paths: paths)
        self.engine = MirrorEngine(paths: paths)
        self.vaultEngine = VaultSync(paths: paths)
        self.machineStore = MachineIdentityStore(paths: paths)
        self.config = configStore.load()
        self.launchAtLogin = Self.isLaunchAtLoginEnabled
        try? paths.ensureDirectories()
        // Read (or mint) this machine's identity up front: it is written into the journal of every
        // vault, and a machine that changed its id would look brand new to everyone else.
        self.machineName = machineStore.loadOrCreate().name
    }

    func setMachineName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var identity = machineStore.loadOrCreate()
        identity.name = trimmed
        try? machineStore.save(identity)
        machineName = trimmed
        banner = "This machine is now “\(trimmed)” to your other Macs. Names already written to conflicted copies do not change."
    }

    // MARK: - Lifecycle

    func start() {
        NeoDropLog.shared.write(
            "NeoDrop started on “\(machineName)” (sources: \(config.sources.count), replicas: \(config.replicas.count), two-way folders: \(config.vaults.count))"
        )
        issues = ConfigValidator.validate(config)
        logIssues()
        restartWatcher()
        scheduleTimer()
        refreshActivity()
        startWebUI()
        offerSetupIfPristine()
        Task {
            await refresh()
            // A quiet sync on launch closes the gap left by whatever happened while we were off.
            if config.isConfigured { syncNow(reason: "launch") }
        }
    }

    /// Introduce the wizard on a fresh install, once.
    ///
    /// A cleared state directory is a fresh install (see `StorePaths`), so a first run and a reset
    /// land in the same place: nothing configured, and no idea what the tabs mean. `didOfferSetup`
    /// is what keeps it to one introduction — somebody who closes the wizard deliberately must not
    /// be asked again on every launch, and the menu keeps it one click away.
    private func offerSetupIfPristine() {
        guard config.isPristine, !config.didOfferSetup else { return }
        config.didOfferSetup = true
        onOpenSetup?()
    }

    func stop() {
        watcher?.stop()
        timer?.invalidate()
        verifyTimer?.invalidate()
        persistTask?.cancel()
        webServer?.stop()
        webServer = nil
        deletedFilesURL = nil
    }

    // MARK: - Deleted files web UI

    /// Bring up the loopback page the web view loads.
    ///
    /// A failure here is not fatal to NeoDrop: mirroring is the product, the deleted-files view
    /// is a convenience, so it is reported in the log and the menu item stays disabled.
    private func startWebUI() {
        guard webServer == nil else { return }
        let server = WebUIServer(
            list: { [weak self] in
                guard let self else { return [] }
                return await self.deletionEntries()
            },
            restore: { [weak self] relativePath in
                guard let self else { throw NeoDropError.retainedCopyUnavailable(relativePath) }
                return try await self.restoreDeletion(relativePath)
            },
            foreignList: { [weak self] in
                guard let self else { return [] }
                return await self.foreignCopyEntries()
            },
            replaceForeign: { [weak self] relativePath, replicaID, expectedSHA256 in
                guard let self else { throw NeoDropError.foreignCopyUnavailable(relativePath) }
                return try await self.replaceForeignCopy(
                    relativePath, replicaID: replicaID, expectedSHA256: expectedSHA256
                )
            },
            status: { [weak self] path in
                await self?.fileStatus(path: path)
            }
        )
        webServer = server
        Task { @MainActor in
            do {
                let url = try await server.start()
                deletedFilesURL = url
                NeoDropLog.shared.write("Deleted files view ready at \(url.absoluteString)")
                await refreshDeletionCount()
            } catch {
                webServer = nil
                NeoDropLog.shared.write("Deleted files view unavailable: \(error.localizedDescription)", level: .warning)
            }
        }
    }

    /// What NeoDrop knows about one path, for the Finder service and the status page.
    ///
    /// Reads only: manifests, the source index, delete records and the vault journals, plus a stat.
    /// Nothing is hashed, so this is safe to answer instantly for a file of any size — see
    /// `FileStatusQuery`.
    func fileStatus(path: String) async -> FileStatusReport? {
        FileStatusQuery(paths: paths, config: config).report(for: URL(fileURLWithPath: path))
    }

    /// The page that shows one file's status, on the local server.
    func statusPageURL(for path: String) -> URL? {
        guard let base = deletedFilesURL else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        return components?.url
    }

    /// Everything the page lists, straight from the engine's records.
    func deletionEntries() async -> [DeletionEntry] {
        await engine.listDeletions(config: config)
    }

    func refreshDeletionCount() async {
        deletionCount = await deletionEntries().count
    }

    func foreignCopyEntries() async -> [ForeignCopyEntry] {
        await engine.listForeignCopies(config: config)
    }

    /// The user's explicit answer to a conflict on one replica. The engine verifies that the
    /// share still holds the bytes shown in the UI, keeps them for recovery, then copies the live
    /// source version in. A normal sync follows to bring every other destination up to date.
    func replaceForeignCopy(_ relativePath: String, replicaID: UUID, expectedSHA256: String) async throws -> URL {
        let destination = try await engine.replaceForeignCopy(
            relativePath: relativePath,
            replicaID: replicaID,
            expectedForeignSHA256: expectedSHA256,
            config: config
        )
        NeoDropLog.shared.write("Replaced foreign copy \(relativePath) on \(config.replica(id: replicaID)?.displayName ?? "destination") after retaining its bytes", level: .success)
        banner = "Replaced the share's copy. Its previous bytes are available in Deleted Files & Versions."
        syncNow(reason: "after resolving \(destination.lastPathComponent)")
        return destination
    }

    /// Restore one deletion at the user's request from the web view.
    ///
    /// The engine does the work; the app's part is to say so in the log and to re-mirror the file
    /// immediately, so it lands on every destination rather than at the next scheduled sync.
    func restoreDeletion(_ relativePath: String) async throws -> URL {
        let destination = try await engine.restore(relativePath: relativePath, config: config)
        NeoDropLog.shared.write("Restored \(relativePath) to \(destination.path)", level: .success)
        banner = "Restored \(destination.lastPathComponent) to its original folder."
        await refreshDeletionCount()
        syncNow(reason: "after restoring \(destination.lastPathComponent)")
        return destination
    }

    // MARK: - Actions

    func syncNow(reason: String = "manual") {
        guard !isBusy else { return }
        guard config.isConfigured else {
            banner = "Add a source folder and a NAS destination, or a two-way folder, first."
            return
        }
        isBusy = true
        progress = SyncProgress(phase: .scanning)
        NeoDropLog.shared.write("Sync started (\(reason))")

        Task {
            // One-way mirrors first, then two-way folders: a vault that cannot be reached must not
            // stop the backups, and the reverse is just as true, so each half runs on its own.
            let result = config.hasMirrors
                ? await engine.sync(config: config) { [weak self] update in
                    Task { @MainActor in self?.progress = update }
                  }
                : nil
            await reconcileVaults(reason: reason)
            await finish(result)
        }
    }

    /// Sync one two-way folder now, without waiting for the schedule. Used by the menu item that
    /// sits under a single folder, where "Sync Now" at the top level would be the wrong scope.
    func syncVaultNow(_ link: VaultLink) {
        guard !isBusy else { return }
        isBusy = true
        progress = SyncProgress(phase: .scanning)
        NeoDropLog.shared.write("Syncing “\(link.displayName)”", scope: .shared)
        Task {
            await reconcileVaults(reason: "manual", only: [link.id])
            isBusy = false
            await finish(nil)
        }
    }

    /// Sync every enabled two-way folder, one at a time, and record what each one did.
    private func reconcileVaults(reason: String, only: Set<UUID>? = nil) async {
        let links = config.enabledVaults.filter { only?.contains($0.id) ?? true }
        guard !links.isEmpty else { return }
        progress = SyncProgress(phase: .scanning)

        for link in links {
            let summary = await vaultEngine.reconcile(link: link, config: config) { [weak self] update in
                Task { @MainActor in self?.progress = update }
            }
            guard let summary else { continue }

            var status = vaultStatuses[link.id] ?? VaultStatus(link: link)
            status.link = link
            status.status = summary.isDegraded ? .degraded : .online
            status.lastSync = summary.finishedAt
            status.summary = summary
            vaultStatuses[link.id] = status

            NeoDropLog.shared.write(Self.describe(summary, link: link),
                                    level: summary.isDegraded ? .warning : .success,
                                    scope: .shared)
            for error in summary.errors.prefix(5) {
                NeoDropLog.shared.write("\(link.displayName): \(error)", level: .warning, scope: .shared)
            }
            if summary.seeded {
                banner = "\(link.displayName): pulled \(summary.downloaded) file(s) from the vault on this Mac's first sync."
            }
            if !summary.conflicts.isEmpty {
                banner = "\(summary.conflicts.count) file(s) changed on two Macs at once. Both versions were kept — look for “conflicted copy”."
            }
        }

        // Deletions are recoverable for a fixed window; the purge has to run for two-way folders
        // too, or their trash grows without bound.
        let purged = await engine.purgeExpiredDeletions(config: config)
        if purged > 0 { NeoDropLog.shared.write("Freed \(purged) retained copy(ies) whose 30-day window closed") }
        if links.contains(where: { vaultStatuses[$0.id]?.summary?.adoptedInVault ?? 0 > 0 }) {
            let adopted = links.reduce(0) { $0 + (vaultStatuses[$1.id]?.summary?.adoptedInVault ?? 0) }
            banner = "\(adopted) file(s) found in the vault and taken into the sync."
        }
        if let latest = links.compactMap({ vaultStatuses[$0.id]?.lastSync }).max() {
            lastSyncFinished = max(lastSyncFinished ?? .distantPast, latest)
        }
        await refreshDeletionCount()
    }

    /// One line a person can read in the log: what happened, in either direction.
    private static func describe(_ summary: VaultSyncSummary, link: VaultLink) -> String {
        var line = "\(link.displayName): \(summary.uploaded) sent, \(summary.downloaded) received"
        if summary.remoteDeletionsApplied > 0 { line += ", \(summary.remoteDeletionsApplied) deleted here (recoverable)" }
        if summary.localDeletionsPublished > 0 { line += ", \(summary.localDeletionsPublished) deleted on every Mac" }
        if !summary.undeleted.isEmpty { line += ", \(summary.undeleted.count) restored everywhere" }
        if !summary.conflicts.isEmpty { line += ", \(summary.conflicts.count) conflict(s) kept as copies" }
        if summary.versionsRetained > 0 { line += ", \(summary.versionsRetained) version(s) retained" }
        if !summary.repairs.isEmpty { line += ", \(summary.repairs.count) repaired on the share" }
        if summary.adoptedInVault > 0 { line += ", \(summary.adoptedInVault) adopted from the share" }
        if summary.seeded { line += " (first sync on this Mac)" }
        if summary.changes == 0 && summary.errors.isEmpty { line += " — up to date" }
        return line
    }

    func verifyNow(repair: Bool = true, replicas: [UUID]? = nil) {
        guard !isBusy else { return }
        guard config.isConfigured else { return }
        isBusy = true
        progress = SyncProgress(phase: .verifying)
        NeoDropLog.shared.write("Verify started\(repair ? " with repair" : "")")

        Task {
            let result = config.hasMirrors
                ? await engine.verify(config: config, replicas: replicas, repair: repair) { [weak self] update in
                    Task { @MainActor in self?.progress = update }
                  }
                : nil
            // A two-way folder is verified by reconciling it: every file's size on the share is
            // checked against the journal, a share copy that went missing or was truncated is put
            // back from retained content, and the walk is what surfaces a broken journal. Above
            // all, “Verify & Repair” must not be a button that silently does nothing.
            await reconcileVaults(reason: "verify")
            await finish(result)
        }
    }

    func mount(_ replica: Replica) {
        guard let smbURL = replica.smbURL, !smbURL.isEmpty else {
            banner = "No share address saved for \(replica.displayName). Mount it in Finder, or edit the destination."
            return
        }
        banner = "Asking Finder to mount \(smbURL)…"
        _ = MountManager.requestMount(smbURL: smbURL)
        Task {
            let ok = await MountManager.waitForAvailability(replicaPath: replica.path)
            banner = ok ? "\(replica.displayName) is mounted." : "\(replica.displayName) did not appear. Check the share and try again."
            await refresh()
            if ok { syncNow(reason: "after mounting \(replica.displayName)") }
        }
    }

    func reveal(_ replica: Replica) {
        NSWorkspace.shared.activateFileViewerSelecting([replica.url])
    }

    func openLog() {
        NSWorkspace.shared.open(paths.base)
    }

    // MARK: - Configuration editing

    func addSource(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard MirrorEngine.isUsableDirectory(url) else {
            banner = "That source folder is not available."
            return
        }
        guard !config.sources.contains(where: { PathIdentity.contains($0.url, url) && PathIdentity.contains(url, $0.url) }) else {
            banner = "That folder is already a source."
            return
        }
        config.sources.append(SourceRoot(name: url.lastPathComponent, path: expanded))
        banner = "Added source \(url.lastPathComponent)."
    }

    func addReplica(path: String, name: String? = nil, smbURL: String? = nil) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard MirrorEngine.isUsableDirectory(url) else {
            banner = "That NAS folder is not mounted or does not exist yet."
            return
        }
        if config.sources.contains(where: { PathIdentity.overlaps($0.url, url) }) {
            banner = "A replica cannot overlap a source folder."
            return
        }
        if config.vaults.contains(where: { PathIdentity.overlaps($0.localURL, url) || PathIdentity.overlaps($0.vaultURL, url) }) {
            banner = "A replica cannot overlap a two-way folder."
            return
        }
        guard !config.replicas.contains(where: { PathIdentity.contains($0.url, url) && PathIdentity.contains(url, $0.url) }) else {
            banner = "That destination is already configured."
            return
        }
        config.replicas.append(Replica(
            name: name?.isEmpty == false ? name! : url.lastPathComponent,
            path: expanded,
            smbURL: smbURL,
            priority: (config.replicas.map(\.priority).max() ?? 99) + 1
        ))
        banner = "Added destination \(url.lastPathComponent)."
    }

    func removeReplica(_ replica: Replica) {
        config.replicas.removeAll { $0.id == replica.id }
        try? ManifestStore(paths: paths).remove(replicaID: replica.id)
    }

    func removeSource(_ source: SourceRoot) {
        config.sources.removeAll { $0.id == source.id }
    }

    func updateReplica(_ id: UUID, name: String, smbURL: String?) {
        guard let index = config.replicas.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        config.replicas[index].name = trimmed
        config.replicas[index].smbURL = smbURL?.trimmingCharacters(in: .whitespaces)
    }

    func toggleReplica(_ replica: Replica) {
        guard let index = config.replicas.firstIndex(where: { $0.id == replica.id }) else { return }
        config.replicas[index].enabled.toggle()
    }

    // MARK: - Two-way folders

    /// Pair a local folder with a vault on a share.
    ///
    /// Both folders must already exist. NeoDrop never creates either one: an unmounted share and an
    /// empty local folder look identical from here, and creating the local folder when the volume
    /// it should live on is missing is how a sync tool ends up filling the boot disk.
    func addVault(localPath: String, vaultPath: String, name: String? = nil, smbURL: String? = nil) {
        let local = URL(fileURLWithPath: (localPath as NSString).expandingTildeInPath)
        let vault = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)

        guard MirrorEngine.isUsableDirectory(local) else {
            banner = "That local folder is not there. Create it first — NeoDrop will not, because an unmounted disk looks exactly like an empty folder."
            return
        }
        guard MirrorEngine.isUsableDirectory(vault) else {
            banner = "That folder on the share is not mounted. Mount the NAS first, then choose the folder that should hold the shared copy."
            return
        }
        guard !Self.overlaps(local, vault) else {
            banner = "The local folder and the vault cannot sit inside one another — the sync would feed on its own output."
            return
        }
        guard !config.vaults.contains(where: { Self.overlaps($0.localURL, local) || Self.overlaps($0.vaultURL, vault) }) else {
            banner = "That folder is already part of a two-way folder."
            return
        }
        if config.sources.contains(where: { Self.overlaps($0.url, local) }) {
            banner = "That folder is already a one-way source. Two-way folders must be separate, or the same files would be mirrored and synced."
            return
        }
        if let replica = config.replicas.first(where: { Self.overlaps($0.url, vault) }) {
            banner = "The vault cannot live inside the replica “\(replica.displayName)”."
            return
        }

        let link = VaultLink(
            name: name?.isEmpty == false ? name! : vault.lastPathComponent,
            vaultPath: vault.path,
            localPath: local.path,
            smbURL: smbURL
        )
        config.vaults.append(link)
        banner = "Added two-way folder “\(link.displayName)”. The first sync brings both sides together."
        syncNow(reason: "after adding a two-way folder")
    }

    func removeVault(_ link: VaultLink) {
        config.vaults.removeAll { $0.id == link.id }
        vaultStatuses[link.id] = nil
        // The local state goes with it: a cursor, a machine name and records for a folder that is
        // no longer synced are only things to be confused by later. Nothing on disk is touched.
        try? FileManager.default.removeItem(at: paths.vaultCursorURL(vaultID: link.id))
        try? DeleteStore(paths: paths).save([], for: link.id)
    }

    func toggleVault(_ link: VaultLink) {
        guard let index = config.vaults.firstIndex(where: { $0.id == link.id }) else { return }
        config.vaults[index].enabled.toggle()
    }

    func updateVault(_ id: UUID, name: String, smbURL: String?) {
        guard let index = config.vaults.firstIndex(where: { $0.id == id }) else { return }
        config.vaults[index].name = name.trimmingCharacters(in: .whitespaces)
        config.vaults[index].smbURL = smbURL?.trimmingCharacters(in: .whitespaces)
    }

    func mountVault(_ link: VaultLink) {
        guard let smbURL = link.smbURL, !smbURL.isEmpty else {
            banner = "No share address saved for “\(link.displayName)”. Mount it in Finder, or add the address."
            return
        }
        banner = "Asking Finder to mount \(smbURL)…"
        _ = MountManager.requestMount(smbURL: smbURL)
        Task {
            let ok = await MountManager.waitForAvailability(replicaPath: link.vaultPath)
            banner = ok ? "\(smbURL) is mounted." : "\(smbURL) did not appear. Check the share and try again."
            await refresh()
            if ok { syncNow(reason: "after mounting the vault") }
        }
    }

    func reveal(_ link: VaultLink) {
        NSWorkspace.shared.activateFileViewerSelecting([link.vaultURL])
    }

    /// Do these two paths contain one another (or coincide)? The check that keeps a sync from
    /// feeding on its own output. Canonical, so the same folder spelled `/var/...` and
    /// `/private/var/...` is not mistaken for two (`PathIdentity`).
    private static func overlaps(_ left: URL, _ right: URL) -> Bool {
        PathIdentity.overlaps(left, right)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else {
            banner = "Launch at login needs the packaged NeoDrop.app."
            launchAtLogin = false
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            banner = "Could not change the login item: \(error.localizedDescription)"
            launchAtLogin = Self.isLaunchAtLoginEnabled
        }
    }

    // MARK: - Derived display state

    var overallStatus: ReplicaStatus {
        if isBusy { return .syncing }
        if issues.contains(where: { $0.severity == .error }) { return .degraded }
        guard config.isConfigured else { return .unknown }
        let active = snapshots.filter { $0.replica.enabled }
        let vaults = config.enabledVaults.map { vaultStatuses[$0.id] }
        // Nothing inspected yet: say so rather than accusing a NAS of being down before looking.
        if active.isEmpty && vaults.allSatisfy({ $0 == nil }) { return .unknown }
        if active.contains(where: { $0.status == .offline }) || vaults.contains(where: { $0?.status == .offline }) { return .offline }
        if active.contains(where: { $0.status == .degraded }) || vaults.contains(where: { $0?.status == .degraded }) { return .degraded }
        if active.contains(where: { $0.status == .unknown }) || vaults.contains(where: { $0 == nil || $0?.status == .unknown }) { return .unknown }
        return .online
    }

    var statusTitle: String {
        if isBusy {
            switch progress.phase {
            case .verifying: return "Verifying…"
            case .repairing: return "Repairing…"
            case .scanning: return "Scanning…"
            default: return "Mirroring…"
            }
        }
        if !config.isConfigured { return "Not set up" }
        switch overallStatus {
        case .online: return lastSyncDescription
        case .degraded: return "Needs attention"
        case .offline: return "Replica offline"
        case .unknown: return "Waiting for first sync"
        case .syncing: return "Working…"
        case .disabled: return "Disabled"
        }
    }

    var statusSymbol: String {
        if isBusy { return "arrow.triangle.2.circlepath" }
        if !config.isConfigured { return "externaldrive.badge.questionmark" }
        switch overallStatus {
        case .online: return "externaldrive.badge.checkmark"
        case .degraded: return "externaldrive.badge.exclamationmark"
        case .offline: return "externaldrive.badge.xmark"
        default: return "externaldrive"
        }
    }

    /// The one-line description of the pass running now, or nil when nothing is running. The
    /// wording lives in `ActivityFeed` so the menu, the window and their tests agree on it.
    var progressLine: String? {
        guard isBusy else { return nil }
        return ActivityFeed.progressLine(progress)
    }

    var lastSyncDescription: String {
        guard let date = summary?.finishedAt ?? lastSyncFinished else { return "No sync yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    var redundancyLine: String {
        var parts: [String] = []
        let enabled = config.enabledReplicas
        if !enabled.isEmpty {
            let online = snapshots.filter { $0.replica.enabled && ($0.status == .online || $0.status == .syncing) }.count
            parts.append("\(online) of \(enabled.count) replicas online")
        }
        let links = config.enabledVaults
        if !links.isEmpty {
            let reachable = links.filter { vaultStatuses[$0.id]?.status != .offline }.count
            let counts = links.compactMap { vaultStatuses[$0.id]?.summary?.filesInVault }
            let files = counts.isEmpty ? "" : " · \(counts.max() ?? 0) file(s) shared"
            parts.append("\(reachable) of \(links.count) two-way folders\(files)")
        }
        return parts.isEmpty ? "Nothing configured yet" : parts.joined(separator: " · ")
    }

    func refreshActivity() {
        activity = NeoDropLog.shared.recent(40).reversed()
    }

    func openActivity() {
        refreshActivity()
        onOpenActivity?()
    }

    func refresh() async {
        issues = ConfigValidator.validate(config)
        snapshots = await engine.inspect(config: config)
        stats = await engine.sourceStats(config: config)
        refreshVaultStatuses()
        publishFinderStatus()
    }

    /// Republish what Finder should badge, for the Finder Sync extension to read.
    ///
    /// The extension cannot ask this process anything — it is started by Finder and may run before,
    /// during or after the app — so the answer has to be a file. Called wherever the facts change: at
    /// launch, after a sync or a verify (both end in `refresh`), and after settings are saved.
    func publishFinderStatus() {
        let index = FinderStatusIndex.build(config: config, paths: paths, progress: progress)
        do {
            // Two copies of the same bytes, on purpose: the state directory keeps it with the rest of
            // what NeoDrop knows (and is what the tests and scripts/e2e.sh read), and the Finder
            // extension's own container is the one place the sandboxed extension can read it from.
            try index.write(to: paths)
            try index.save(to: FinderStatusIndex.extensionContainerIndexURL())
            NeoDropLog.shared.write(
                "Finder badges updated: \(index.roots.count) folder(s), \(index.exceptions.count) needing attention",
                level: .info
            )
        } catch {
            // Not fatal: the badges go stale, the protection does not.
            NeoDropLog.shared.write("Finder badges could not be updated: \(error.localizedDescription)", level: .warning)
        }
    }

    /// Availability is a property of right now, not of the last sync: a share that has been
    /// unplugged since must stop claiming to be in sync.
    private func refreshVaultStatuses() {
        for link in config.vaults {
            var status = vaultStatuses[link.id] ?? VaultStatus(link: link)
            status.link = link
            if !link.enabled {
                status.status = .disabled
            } else if !MirrorEngine.isUsableDirectory(link.vaultURL) || !MirrorEngine.isUsableDirectory(link.localURL) {
                status.status = .offline
            } else if status.status == .offline {
                status.status = status.lastSync == nil ? .unknown : .online
            }
            vaultStatuses[link.id] = status
        }
        for id in vaultStatuses.keys where config.vault(id: id) == nil {
            vaultStatuses[id] = nil
        }
    }

    // MARK: - Internals

    private func finish(_ result: SyncSummary?) async {
        isBusy = false
        guard let result else {
            // A two-way-only run: there is no mirror summary to report, so the phase comes from
            // whether any vault came back with a problem.
            let degraded = config.enabledVaults.contains { vaultStatuses[$0.id]?.summary?.isDegraded == true }
            progress = SyncProgress(phase: degraded ? .failed("A two-way folder needs attention") : .finished)
            await refresh()
            await refreshDeletionCount()
            refreshActivity()
            return
        }
        summary = result
        lastSyncFinished = result.finishedAt
        progress = SyncProgress(phase: result.phase)

        let failures = result.replicas.flatMap(\.errors)
        let level: LogLevel = result.isDegraded ? .warning : .success
        var line = "\(result.phase == .finished ? "Done" : "Finished") in \(String(format: "%.1f", result.duration))s: "
        line += "\(result.filesCopied) copied, \(result.filesRepaired) repaired, \(result.filesDeleted) removed, "
        line += "\(result.failures) failed across \(result.replicas.count) replica(s)"
        // Both of these are unusual enough to be worth naming, and silent when they are zero: the
        // first says a manifest was missing (a reset or a new Mac), the second that somebody else's
        // file is in the way and was deliberately left alone.
        if result.filesAdopted > 0 {
            line += ", \(result.filesAdopted) already on the share"
        }
        if result.foreignFiles > 0 {
            line += ", \(result.foreignFiles) left alone (not written by NeoDrop)"
        }
        // Not unusual enough to warn about — a file was edited and the previous version is still
        // recoverable — but naming it is what tells the user where an overwritten edit went.
        if result.versionsKept > 0 {
            line += ", \(result.versionsKept) previous version(s) kept for recovery"
        }
        NeoDropLog.shared.write(line, level: level)
        for failure in failures.prefix(5) {
            NeoDropLog.shared.write(failure, level: .warning)
        }

        await refresh()
        // A sync reconciles deletions (restored files drop out of the list, expired ones are
        // purged), so the count the menu shows is only correct once the sync has finished.
        await refreshDeletionCount()
        refreshActivity()

        if result.isDegraded {
            notify(
                title: "NeoDrop: protection degraded",
                body: failures.first ?? "A replica is offline or holds a copy that failed verification."
            )
        }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.persistNow()
        }
    }

    private func persistNow() async {
        do {
            try configStore.save(config)
        } catch {
            NeoDropLog.shared.write("Could not save config: \(error.localizedDescription)", level: .error)
            banner = "Could not save settings: \(error.localizedDescription)"
        }
        issues = ConfigValidator.validate(config)
        logIssues()
        restartWatcher()
        scheduleTimer()
        // A folder added or removed in Settings becomes a folder Finder badges (or stops being one).
        publishFinderStatus()
    }

    /// Put configuration problems in the log too, so "why does it say needs attention?" can be
    /// answered from the log file without hunting through the UI.
    private func logIssues() {
        for issue in issues {
            NeoDropLog.shared.write(issue.message, level: issue.severity == .error ? .error : .warning)
        }
    }

    private func restartWatcher() {
        watcher?.stop()
        watcher = nil
        isWatching = false

        // A two-way folder's local side is a working copy: an edit there is exactly what has to
        // reach the other Macs, so it is watched with the same urgency as a mirrored source.
        //
        // The vault on the share is watched too, so a change another Mac publishes is picked up in
        // seconds rather than at the next scheduled sync. On SMB, FSEvents is best effort — which
        // is exactly why the timer exists as well, rather than instead.
        let paths = config.sources.map(\.path)
            + config.enabledVaults.map(\.localPath)
            + config.enabledVaults.map(\.vaultPath)
        guard config.watchForChanges, !paths.isEmpty else { return }
        let watcher = FolderWatcher(paths: paths, quietPeriod: 4) { [weak self] changed in
            Task { @MainActor in
                guard let self else { return }
                NeoDropLog.shared.write("Detected \(changed.count) change(s) under the folders")
                self.syncNow(reason: "file change")
            }
        }
        isWatching = watcher.start()
        self.watcher = watcher
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        verifyTimer?.invalidate()
        verifyTimer = nil
        guard config.isConfigured else { return }

        if config.scheduledSync {
            let interval = TimeInterval(max(1, config.syncIntervalMinutes) * 60)
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.syncNow(reason: "scheduled") }
            }
        }

        if config.scheduledVerify {
            let interval = TimeInterval(max(1, config.verifyIntervalHours) * 3600)
            verifyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.verifyNow(repair: true) }
            }
        }
    }

    /// Async rather than the completion-handler API: `UNUserNotificationCenter` is not `Sendable`,
    /// so capturing it in a `@Sendable` closure is genuinely unsafe. Awaiting keeps every
    /// non-Sendable value on this actor.
    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static var isLaunchAtLoginEnabled: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return SMAppService.mainApp.status == .enabled
    }
}

extension ReplicaStatus {
    var menuDescription: String {
        switch self {
        case .unknown: return "not checked yet"
        case .online: return "in sync"
        case .syncing: return "working"
        case .degraded: return "degraded"
        case .offline: return "offline"
        case .disabled: return "disabled"
        }
    }
}
