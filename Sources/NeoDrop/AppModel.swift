import Foundation
import AppKit
import NeoDropCore
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

    let paths: StorePaths
    let engine: MirrorEngine
    private let configStore: ConfigStore

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
        self.config = configStore.load()
        self.launchAtLogin = Self.isLaunchAtLoginEnabled
        try? paths.ensureDirectories()
    }

    // MARK: - Lifecycle

    func start() {
        NeoDropLog.shared.write("NeoDrop started (sources: \(config.sources.count), replicas: \(config.replicas.count))")
        issues = ConfigValidator.validate(config)
        logIssues()
        restartWatcher()
        scheduleTimer()
        refreshActivity()
        startWebUI()
        Task {
            await refresh()
            // A quiet sync on launch closes the gap left by whatever happened while we were off.
            if config.isConfigured { syncNow(reason: "launch") }
        }
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

    /// Everything the page lists, straight from the engine's records.
    func deletionEntries() async -> [DeletionEntry] {
        await engine.listDeletions(config: config)
    }

    func refreshDeletionCount() async {
        deletionCount = await deletionEntries().count
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
            banner = "Add at least one source folder and one NAS destination first."
            return
        }
        isBusy = true
        progress = SyncProgress(phase: .scanning)
        NeoDropLog.shared.write("Sync started (\(reason))")

        Task {
            let result = await engine.sync(config: config) { [weak self] update in
                Task { @MainActor in self?.progress = update }
            }
            await finish(result)
        }
    }

    func verifyNow(repair: Bool = true, replicas: [UUID]? = nil) {
        guard !isBusy else { return }
        guard config.isConfigured else { return }
        isBusy = true
        progress = SyncProgress(phase: .verifying)
        NeoDropLog.shared.write("Verify started\(repair ? " with repair" : "")")

        Task {
            let result = await engine.verify(config: config, replicas: replicas, repair: repair) { [weak self] update in
                Task { @MainActor in self?.progress = update }
            }
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
        guard !config.sources.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) else {
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
        if config.sources.contains(where: { source in
            let s = source.url.standardizedFileURL.path
            let r = url.standardizedFileURL.path
            return r == s || r.hasPrefix(s + "/") || s.hasPrefix(r + "/")
        }) {
            banner = "A replica cannot overlap a source folder."
            return
        }
        guard !config.replicas.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) else {
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
        // Nothing inspected yet: say so rather than accusing a NAS of being down before looking.
        if active.isEmpty { return .unknown }
        if active.contains(where: { $0.status == .offline }) { return .offline }
        if active.contains(where: { $0.status == .degraded }) { return .degraded }
        if active.contains(where: { $0.status == .unknown }) { return .unknown }
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

    var progressLine: String? {
        guard isBusy else { return nil }
        var parts: [String] = [progress.phase.label]
        if let name = progress.replicaName { parts.append("→ \(name)") }
        if progress.filesTotal > 0 {
            parts.append("\(progress.filesDone)/\(progress.filesTotal) files")
        }
        if let file = progress.currentFile { parts.append(file) }
        return parts.joined(separator: " · ")
    }

    var lastSyncDescription: String {
        guard let date = summary?.finishedAt ?? lastSyncFinished else { return "No sync yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    var redundancyLine: String {
        let enabled = config.enabledReplicas
        guard !enabled.isEmpty else { return "No replicas configured" }
        let online = snapshots.filter { $0.replica.enabled && ($0.status == .online || $0.status == .syncing) }.count
        return "\(online) of \(enabled.count) replicas online"
    }

    func refreshActivity() {
        activity = NeoDropLog.shared.recent(40).reversed()
    }

    func refresh() async {
        issues = ConfigValidator.validate(config)
        snapshots = await engine.inspect(config: config)
        stats = await engine.sourceStats(config: config)
    }

    // MARK: - Internals

    private func finish(_ result: SyncSummary?) async {
        isBusy = false
        guard let result else { return }
        summary = result
        lastSyncFinished = result.finishedAt
        progress = SyncProgress(phase: result.phase)

        let failures = result.replicas.flatMap(\.errors)
        let level: LogLevel = result.isDegraded ? .warning : .success
        var line = "\(result.phase == .finished ? "Done" : "Finished") in \(String(format: "%.1f", result.duration))s: "
        line += "\(result.filesCopied) copied, \(result.filesRepaired) repaired, \(result.filesDeleted) removed, "
        line += "\(result.failures) failed across \(result.replicas.count) replica(s)"
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

        guard config.watchForChanges, !config.sources.isEmpty else { return }
        let paths = config.sources.map(\.path)
        let watcher = FolderWatcher(paths: paths, quietPeriod: 4) { [weak self] changed in
            Task { @MainActor in
                guard let self else { return }
                NeoDropLog.shared.write("Detected \(changed.count) change(s) under the sources")
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

extension Int64 {
    var byteDescription: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
