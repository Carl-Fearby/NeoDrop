import Foundation

/// The heart of NeoDrop: a full mirror of every source folder onto every replica, with
/// checksum verification and repair.
///
/// Design rules that keep this safe to point at real NAS data:
///
/// * NeoDrop only ever writes or deletes files it recorded in a replica's manifest. Anything
///   else on the share is left alone, so a replica can share a volume with other data.
/// * A replica root must already exist. NeoDrop never creates the mount point itself, because
///   creating `/Volumes/NAS2/NeoDrop` while the share is unmounted would silently write to the
///   boot volume instead of the NAS.
/// * Every copy goes through a temp file in the destination directory and a rename, so a
///   dropped SMB connection cannot leave a half-written file that looks complete.
/// * Deletion from a replica happens only after the file is gone from every source, and only
///   when `mirrorDeletions` is on.
public actor MirrorEngine {
    private let paths: StorePaths
    private let manifestStore: ManifestStore
    private let runtimeStore: RuntimeStateStore
    private let sourceIndexStore: SourceIndexStore
    private let indexer = SourceIndexer()

    private var running = false

    public init(paths: StorePaths = .standard) {
        self.paths = paths
        self.manifestStore = ManifestStore(paths: paths)
        self.runtimeStore = RuntimeStateStore(paths: paths)
        self.sourceIndexStore = SourceIndexStore(paths: paths)
    }

    public var isRunning: Bool { running }

    // MARK: - Inspection (cheap, no I/O beyond stat)

    /// Per-replica view for the menu, without touching file contents.
    public func inspect(config: AppConfig) async -> [ReplicaSnapshot] {
        let runtime = runtimeStore.load()
        return config.replicas.map { replica in
            let state = runtime.runtime(for: replica.id)
            let manifest = manifestStore.load(replicaID: replica.id)
            let reachable = Self.isUsableDirectory(replica.url)
            var snapshot = ReplicaSnapshot(
                replica: replica,
                status: !replica.enabled ? .disabled : (reachable ? (state.status == .unknown ? .unknown : state.status) : .offline),
                files: manifest.entries.count,
                bytes: manifest.totalBytes,
                corrupt: manifest.corruptPaths.count,
                lastSync: manifest.lastSync,
                lastVerify: manifest.lastVerify,
                lastError: state.lastError
            )
            if !reachable { snapshot.status = replica.enabled ? .offline : .disabled }
            return snapshot
        }
    }

    /// Number of files/bytes NeoDrop intends to protect, plus any source that is missing.
    public func sourceStats(config: AppConfig) async -> SourceStats {
        var files = 0
        var bytes: Int64 = 0
        var missing: [String] = []
        let excludes = ExcludeMatcher(patterns: config.excludes)
        for source in config.sources {
            do {
                let scanned = try Scanner.scan(source: source, excludes: excludes)
                files += scanned.count
                bytes += scanned.reduce(0) { $0 + $1.size }
            } catch {
                missing.append(source.displayName)
            }
        }
        return SourceStats(fileCount: files, byteCount: bytes, missingSources: missing)
    }

    // MARK: - Sync

    /// Mirror every source onto every enabled replica, then verify what was written.
    public func sync(
        config: AppConfig,
        progress: @Sendable (SyncProgress) -> Void = { _ in }
    ) async -> SyncSummary? {
        guard !running else { return nil }
        running = true
        defer { running = false }

        var summary = SyncSummary(phase: .scanning, startedAt: Date())
        progress(SyncProgress(phase: .scanning))

        // Retention housekeeping before anything else: deletions whose 30-day window has closed
        // give their space back on every destination that is currently mounted.
        purgeExpiredDeletions(config: config)

        guard !config.sources.isEmpty else {
            summary.phase = .failed("No source folder is configured")
            summary.finishedAt = Date()
            return summary
        }

        // An empty plan is not an early exit: "the source is now empty" is a real state, and
        // mirroring it is legitimate. Only deletions are dangerous there, and `syncReplica`
        // refuses those whenever a source could not be read at all.
        let plan = buildSourcePlan(config: config, progress: progress)

        for replica in config.enabledReplicas {
            let report = await syncReplica(replica: replica, plan: plan, config: config, progress: progress)
            summary.replicas.append(report)
        }

        summary.phase = .finished
        summary.finishedAt = Date()
        persistRuntime(summary: summary)
        return summary
    }

    // MARK: - Verify and repair

    /// Re-hash every file on the chosen replicas and compare against the manifest. With
    /// `repair` the bad copies are rewritten from the source, or from another healthy replica
    /// when the source no longer has the file.
    public func verify(
        config: AppConfig,
        replicas targetIDs: [UUID]? = nil,
        repair: Bool = true,
        progress: @Sendable (SyncProgress) -> Void = { _ in }
    ) async -> SyncSummary? {
        guard !running else { return nil }
        running = true
        defer { running = false }

        var summary = SyncSummary(phase: .verifying, startedAt: Date())
        progress(SyncProgress(phase: .verifying))

        let candidates = config.enabledReplicas.filter { targetIDs?.contains($0.id) ?? true }

        // Manifest data for the healthy replicas doubles as a repair source.
        let allManifests = Dictionary(
            uniqueKeysWithValues: config.enabledReplicas.map { ($0.id, manifestStore.load(replicaID: $0.id)) }
        )
        // Live source paths, keyed exactly like the manifest, so a repair can prefer the original.
        let sourceFiles = liveSourceFiles(config: config)

        for replica in candidates {
            var manifest = manifestStore.load(replicaID: replica.id)
            var report = ReplicaReport(id: replica.id, name: replica.displayName, status: .unknown)

            guard Self.isUsableDirectory(replica.url) else {
                report.status = .offline
                report.errors.append("Replica folder is not available")
                summary.replicas.append(report)
                continue
            }

            let entries = manifest.entries
            let total = entries.count
            let totalBytes = entries.values.reduce(0) { $0 + $1.size }
            var checked = 0
            var checkedBytes: Int64 = 0
            var corrupt: [String] = []

            progress(SyncProgress(
                phase: .verifying, replicaName: replica.displayName,
                filesTotal: total, bytesTotal: totalBytes
            ))

            for (relativePath, entry) in entries {
                checked += 1
                checkedBytes += entry.size
                let destination = replica.url.appendingPathComponent(relativePath)

                if FileMeta.size(ofFileAt: destination) == entry.size,
                   let digest = try? Hashing.sha256(ofFileAt: destination),
                   digest == entry.sha256 {
                    manifest.entries[relativePath]?.verifiedAt = Date()
                } else {
                    corrupt.append(relativePath)
                }

                if checked % 25 == 0 || checked == total {
                    progress(SyncProgress(
                        phase: .verifying, replicaName: replica.displayName,
                        currentFile: relativePath,
                        filesTotal: total, filesDone: checked,
                        bytesTotal: totalBytes, bytesDone: checkedBytes
                    ))
                }
            }

            manifest.corruptPaths = corrupt
            manifest.lastVerify = Date()

            if !corrupt.isEmpty && repair {
                progress(SyncProgress(phase: .repairing, replicaName: replica.displayName,
                                      filesTotal: corrupt.count, filesDone: 0))
                for (index, relativePath) in corrupt.enumerated() {
                    guard let entry = manifest.entries[relativePath] else { continue }
                    guard let origin = repairSource(
                        for: relativePath,
                        expected: entry,
                        excluding: replica.id,
                        sourceFiles: sourceFiles,
                        manifests: allManifests,
                        config: config
                    ) else {
                        report.failed += 1
                        report.errors.append("\(relativePath): no healthy copy available to repair from")
                        continue
                    }
                    let destination = replica.url.appendingPathComponent(relativePath)
                    do {
                        try copy(origin, to: destination, config: config)
                        manifest.entries[relativePath]?.writtenAt = Date()
                        manifest.entries[relativePath]?.verifiedAt = Date()
                        report.repaired += 1
                        report.bytesWritten += entry.size
                    } catch {
                        report.failed += 1
                        report.errors.append("\(relativePath): \(error.localizedDescription)")
                    }
                    progress(SyncProgress(phase: .repairing, replicaName: replica.displayName,
                                          currentFile: relativePath,
                                          filesTotal: corrupt.count, filesDone: index + 1,
                                          bytesTotal: totalBytes, bytesDone: checkedBytes))
                }
                manifest.corruptPaths = manifest.corruptPaths.filter { path in
                    report.errors.contains { $0.hasPrefix(path + ":") }
                }
            }

            // `corrupt` counts what we found; after a repair the interesting number is what is
            // still wrong, which is exactly the count of repair failures.
            let remaining = repair ? report.failed : corrupt.count
            report.corrupt = remaining
            report.upToDate = total - remaining
            report.copied = report.repaired
            report.status = report.failed > 0 || remaining > 0 ? .degraded : .online
            try? manifestStore.save(manifest)
            summary.replicas.append(report)
        }

        summary.phase = .finished
        summary.finishedAt = Date()
        persistRuntime(summary: summary, verified: true)
        return summary
    }

    /// Decide where a repair copy should come from, preferring the live source and falling back
    /// to any replica that still has a verified copy.
    private func repairSource(
        for relativePath: String,
        expected: ManifestEntry,
        excluding replicaID: UUID,
        sourceFiles: [String: URL],
        manifests: [UUID: Manifest],
        config: AppConfig
    ) -> URL? {
        if let url = sourceFiles[relativePath], FileMeta.size(ofFileAt: url) == expected.size {
            return url
        }
        for (id, manifest) in manifests where id != replicaID {
            guard let entry = manifest.entries[relativePath], entry.sha256 == expected.sha256 else { continue }
            // Read the replica list from the caller's config, never from disk: the engine must
            // interpret exactly the configuration it was handed.
            guard let replica = config.replica(id: id) else { continue }
            let url = replica.url.appendingPathComponent(relativePath)
            if FileMeta.size(ofFileAt: url) == entry.size,
               let digest = try? Hashing.sha256(ofFileAt: url), digest == entry.sha256 {
                return url
            }
        }
        return nil
    }

    // MARK: - Per-replica sync

    private func syncReplica(
        replica: Replica,
        plan: SourcePlan,
        config: AppConfig,
        progress: @Sendable (SyncProgress) -> Void
    ) async -> ReplicaReport {
        var report = ReplicaReport(id: replica.id, name: replica.displayName, status: .unknown)

        guard Self.isUsableDirectory(replica.url) else {
            report.status = .offline
            report.errors.append("Replica folder is not available — is the share mounted?")
            report.failed = plan.files.count
            return report
        }

        var manifest = manifestStore.load(replicaID: replica.id)

        // Retention bookkeeping, run on every sync regardless of `mirrorDeletions`: a record
        // whose file is genuinely back in the source (same digest — the plan already hashed it)
        // was restored, and a record whose retained bytes have vanished cannot restore anything.
        // Both would otherwise linger as rows in the deleted-files view that do nothing.
        reconcileRetainedCopies(replica: replica, plan: plan)

        // 1. Deletions: files NeoDrop wrote that no longer exist in any source.
        let pendingDeletions = manifest.entries.keys.filter { plan.files[$0] == nil }
        if !config.mirrorDeletions {
            // Mirroring deletions is off, so the replica is an archive and keeps everything.
        } else if !plan.allSourcesReadable {
            // A source we could not read might still hold every one of these files. Deleting now
            // is how a mirror silently eats a NAS, so refuse and say so.
            report.errors.append("Deletions skipped: \(plan.errors.first ?? "a source folder could not be read") — nothing was removed from this replica.")
        } else if Self.exceedsDeletionGuard(
            pending: pendingDeletions.count,
            known: manifest.entries.count,
            allowBulkDeletions: config.allowBulkDeletions
        ) {
            report.errors.append("Refused to remove \(pendingDeletions) of \(manifest.entries.count) mirrored files in one run. Check that the source folder is still the right one, or tick “Allow bulk deletions” in Settings to proceed.")
        } else {
            let deleteStore = DeleteStore(paths: paths)
            var records = deleteStore.load(replicaID: replica.id)
            let moving = Set(pendingDeletions.filter {
                FileManager.default.fileExists(atPath: replica.url.appendingPathComponent($0).path)
            })

            // Manifest entries whose file is already not on the replica need no record — only
            // the entry removal, since there are no bytes left to retain or destroy.
            for relativePath in pendingDeletions where !moving.contains(relativePath) {
                manifest.entries.removeValue(forKey: relativePath)
                report.deleted += 1
            }

            if !moving.isEmpty {
                // Records are saved before any byte moves: a record without bytes self-heals
                // (the next sync finds no trash file and drops it), while bytes without a
                // record are unreachable forever. If recording fails, nothing moves — a
                // failure to record is a failure to delete, never a silent orphan.
                for relativePath in moving {
                    records.removeAll { $0.relativePath == relativePath }
                    records.append(Self.recordForDeletion(
                        relativePath: relativePath,
                        config: config,
                        previous: manifest.entries[relativePath]
                    ))
                }
                var staged = true
                do {
                    try deleteStore.save(records, for: replica.id)
                } catch {
                    staged = false
                    report.failed += moving.count
                    report.errors.append(
                        "Deletions skipped: could not record them for recovery (\(error.localizedDescription)) — nothing was removed from this replica."
                    )
                }

                if staged {
                    for relativePath in moving {
                        let destination = replica.url.appendingPathComponent(relativePath)
                        let trashURL = DeleteRecord(relativePath: relativePath, sourcePath: "", size: 0, sha256: "")
                            .trashURL(onReplicaRoot: replica.url)
                        do {
                            try FileManager.default.createDirectory(
                                at: trashURL.deletingLastPathComponent(), withIntermediateDirectories: true
                            )
                            // A retained copy from an earlier cycle of this same path loses to
                            // the newest deletion: it was superseded when the file was recreated.
                            if FileManager.default.fileExists(atPath: trashURL.path) {
                                try FileManager.default.removeItem(at: trashURL)
                            }
                            // One SMB rename instead of an upload: the bytes never leave the share.
                            try FileManager.default.moveItem(at: destination, to: trashURL)
                            manifest.entries.removeValue(forKey: relativePath)
                            report.deleted += 1
                        } catch {
                            // Drop the staged record again: it must never claim bytes that are
                            // not in the trash. The manifest entry stays, so the file keeps
                            // being treated as mirrored data and the deletion retries next sync.
                            records.removeAll { $0.relativePath == relativePath }
                            try? deleteStore.save(records, for: replica.id)
                            report.failed += 1
                            report.errors.append("delete \(relativePath): \(error.localizedDescription)")
                        }
                    }
                }
            }
            Self.pruneEmptyDirectories(root: replica.url, keeping: Set(plan.files.keys))
        }

        // 2. Copies: only the files whose digest on the replica is not already right.
        let totalBytes = plan.files.values.reduce(Int64(0)) { $0 + $1.size }
        var doneBytes: Int64 = 0
        var doneFiles = 0

        for (relativePath, file) in plan.files {
            doneFiles += 1
            let destination = replica.url.appendingPathComponent(relativePath)

            if let entry = manifest.entries[relativePath],
               entry.sha256 == file.sha256,
               entry.size == file.size,
               FileMeta.size(ofFileAt: destination) == file.size {
                report.upToDate += 1
                doneBytes += file.size
                continue
            }

            let isUpdate = manifest.entries[relativePath] != nil
            do {
                try copy(file.url, to: destination, config: config)
                manifest.entries[relativePath] = ManifestEntry(
                    size: file.size,
                    mtime: file.mtime,
                    sha256: file.sha256,
                    sourceID: file.sourceID
                )
                if isUpdate { report.updated += 1 } else { report.copied += 1 }
                report.bytesWritten += file.size
            } catch {
                report.failed += 1
                report.errors.append("\(relativePath): \(error.localizedDescription)")
            }

            doneBytes += file.size
            if doneFiles % 10 == 0 || doneFiles == plan.files.count {
                progress(SyncProgress(
                    phase: .syncing,
                    replicaName: replica.displayName,
                    currentFile: relativePath,
                    filesTotal: plan.files.count,
                    filesDone: doneFiles,
                    bytesTotal: totalBytes,
                    bytesDone: doneBytes
                ))
            }
        }

        manifest.lastSync = Date()
        manifest.replicaID = replica.id
        try? manifestStore.save(manifest)

        report.errors.append(contentsOf: plan.errors)
        report.status = report.failed > 0 || !report.errors.isEmpty ? .degraded : .online
        return report
    }

    /// Guards the one operation that can destroy data: removing many files in a single run.
    ///
    /// The classic disaster is a source folder that got renamed, unplugged or re-pointed, after
    /// which a mirror dutifully deletes everything it had protected. Anything beyond a quarter of
    /// the mirror (or 25 files, whichever is larger) has to be asked for explicitly.
    public static func exceedsDeletionGuard(pending: Int, known: Int, allowBulkDeletions: Bool) -> Bool {
        guard !allowBulkDeletions, known > 0, pending > 0 else { return false }
        let threshold = max(25, Int(Double(known) * 0.25))
        return pending > threshold
    }

    /// Build the record for a file that is about to leave the mirror. Nothing is touched on the
    /// replica — only the description a restore needs: where it goes back, its size, and the
    /// source's digest (the retained bytes are that same file renamed, so the manifest's hash
    /// stays the right thing to verify a restore against).
    private static func recordForDeletion(
        relativePath: String,
        config: AppConfig,
        previous: ManifestEntry?
    ) -> DeleteRecord {
        DeleteRecord(
            relativePath: relativePath,
            sourcePath: sourcePath(forMirroredPath: relativePath, config: config),
            size: previous?.size ?? 0,
            sha256: previous?.sha256 ?? ""
        )
    }

    /// Where a restore should put this mirrored path back: the absolute file URL in its source
    /// root, resolved through the same namespacing the scanner applied when it was copied.
    private static func sourcePath(forMirroredPath relativePath: String, config: AppConfig) -> String {
        guard !config.sources.isEmpty else { return "" }
        // With one source the mirrored path *is* the source-relative path. With several, the
        // mirror is namespaced under the source's display name.
        if config.sources.count == 1 {
            return config.sources[0].url.appendingPathComponent(relativePath).path
        }
        for source in config.sources {
            let prefix = source.displayName + "/"
            if relativePath.hasPrefix(prefix) {
                return source.url.appendingPathComponent(String(relativePath.dropFirst(prefix.count))).path
            }
        }
        // The source was removed from the configuration between copy and delete: record the
        // first root as a best guess so the entry is not simply lost; the restore path is
        // validated against the configured roots before anything is written.
        return config.sources[0].url.appendingPathComponent(relativePath).path
    }

    private func copy(_ origin: URL, to destination: URL, config: AppConfig) throws {
        try AtomicFile.copy(from: origin, to: destination)
        if config.verifyAfterCopy {
            // Re-read what actually landed. On a flaky share this is where a bad copy is caught,
            // instead of weeks later during a verify.
            guard let written = try? Hashing.sha256(ofFileAt: destination),
                  written == (try? Hashing.sha256(ofFileAt: origin)) else {
                throw NeoDropError.verificationFailed(destination.path)
            }
        }
    }

    // MARK: - Source planning

    /// Every scanned source file, keyed by the path it occupies on a replica.
    private func liveSourceFiles(config: AppConfig) -> [String: URL] {
        let excludes = ExcludeMatcher(patterns: config.excludes)
        var files: [String: URL] = [:]
        for source in config.sources {
            for scanned in (try? Scanner.scan(source: source, excludes: excludes)) ?? [] {
                files[Scanner.namespaced(relativePath: scanned.relativePath, source: source, sourceCount: config.sources.count)] = scanned.url
            }
        }
        return files
    }

    private struct PlannedFile: Sendable {
        var url: URL
        var size: Int64
        var mtime: Date
        var sha256: String
        var sourceID: UUID
    }

    private struct SourcePlan: Sendable {
        /// Keyed by the mirrored relative path (`Photos/a.jpg`, or `Source/Photos/a.jpg`).
        var files: [String: PlannedFile]
        var errors: [String]
        /// False when at least one source could not be read. An unreadable source makes
        /// deletions unsafe, because its files might simply be out of sight.
        var allSourcesReadable: Bool
    }

    private func buildSourcePlan(config: AppConfig, progress: @Sendable (SyncProgress) -> Void) -> SourcePlan {
        let excludes = ExcludeMatcher(patterns: config.excludes)
        var scanned: [ScannedFile] = []
        var errors: [String] = []
        var unreadable = 0
        for source in config.sources {
            do {
                scanned.append(contentsOf: try Scanner.scan(source: source, excludes: excludes))
            } catch {
                unreadable += 1
                errors.append("\(source.displayName): \(error.localizedDescription)")
            }
        }

        let previous = sourceIndexStore.load()
        let refreshed = indexer.refresh(files: scanned, previous: previous)
        try? sourceIndexStore.save(refreshed.index)
        errors.append(contentsOf: refreshed.errors)

        let byID = Dictionary(uniqueKeysWithValues: config.sources.map { ($0.id, $0) })
        var files: [String: PlannedFile] = [:]

        for file in scanned {
            let key = "\(file.sourceID.uuidString)/\(file.relativePath)"
            guard let entry = refreshed.index.entries[key] else { continue }
            // With several sources the mirror gets one top-level folder per source, so two files
            // called `notes.txt` never fight over the same path on the NAS.
            let mirrored = Scanner.namespaced(
                relativePath: file.relativePath,
                source: byID[file.sourceID] ?? SourceRoot(id: file.sourceID, name: file.sourceID.uuidString, path: "/"),
                sourceCount: config.sources.count
            )
            files[mirrored] = PlannedFile(
                url: file.url,
                size: file.size,
                mtime: file.mtime,
                sha256: entry.sha256,
                sourceID: file.sourceID
            )
        }

        progress(SyncProgress(phase: .syncing, filesTotal: files.count, bytesTotal: files.values.reduce(0) { $0 + $1.size }))
        return SourcePlan(files: files, errors: errors, allSourcesReadable: unreadable == 0)
    }

    // MARK: - Deleted files: list, restore, purge

    /// Everything the deleted-files view shows, aggregated across destinations.
    ///
    /// `relativePath` is the identity: each replica records the same logical deletion
    /// independently, moments apart, so they are folded into one entry with one row per
    /// destination. Expired entries are left out — they are purge fodder, and a row whose
    /// restore button cannot work is worse than no row at all.
    public func listDeletions(config: AppConfig) -> [DeletionEntry] {
        let store = DeleteStore(paths: paths)
        let fm = FileManager.default
        let now = Date()
        var recordsByPath: [String: [DeleteRecord]] = [:]
        var copiesByPath: [String: [DeletionCopy]] = [:]

        for replica in config.replicas {
            let records = store.load(replicaID: replica.id)
            guard !records.isEmpty else { continue }
            // A reachable destination with a retained copy is what makes an entry restorable;
            // an unmounted share is reported as unavailable rather than assumed gone.
            let reachable = Self.isUsableDirectory(replica.url)
            let trashRoot = self.trashRoot(replica.url)
            for record in records where record.expiresAt > now {
                let trashURL = record.trashURL(onReplicaRoot: replica.url)
                let available = reachable
                    && Self.isInside(trashURL, of: trashRoot)
                    && fm.fileExists(atPath: trashURL.path)
                recordsByPath[record.relativePath, default: []].append(record)
                copiesByPath[record.relativePath, default: []].append(
                    DeletionCopy(replicaID: replica.id, replicaName: replica.displayName, available: available)
                )
            }
        }

        return recordsByPath.compactMap { relativePath, records in
            guard let earliest = records.min(by: { $0.deletedAt < $1.deletedAt }) else { return nil }
            return DeletionEntry(
                relativePath: relativePath,
                sourcePath: records.first(where: { !$0.sourcePath.isEmpty })?.sourcePath ?? earliest.sourcePath,
                size: earliest.size,
                sha256: earliest.sha256,
                deletedAt: earliest.deletedAt,
                // The entry is only as safe as its weakest copy: the window closes for all of
                // them at the first expiry, because that is when any of them may be purged.
                expiresAt: records.map(\.expiresAt).min() ?? earliest.expiresAt,
                copies: (copiesByPath[relativePath] ?? []).sorted { $0.replicaName < $1.replicaName }
            )
        }
        // Newest first. Records are stored with second precision, so deletions in the same second
        // are genuinely unordered — the path breaks the tie so the list never reshuffles itself
        // between refreshes.
        .sorted { left, right in
            left.deletedAt == right.deletedAt
                ? left.relativePath < right.relativePath
                : left.deletedAt > right.deletedAt
        }
    }

    /// Put a deleted file back where it came from, using the best verified retained copy.
    ///
    /// Safety rules, in the same spirit as the rest of the engine:
    ///
    /// * Nothing is ever overwritten. If a file already sits at the destination, the restore
    ///   only counts as done when that file is byte-identical — the deletion was already undone.
    ///   Anything else is a conflict and the user's new file wins.
    /// * The retained bytes are verified against the digest in the record before the source
    ///   folder is touched, and the written copy is verified again after it lands.
    /// * The destination is validated against the configured source roots, so a record that was
    ///   edited on disk cannot point a restore outside the folders the user protects.
    @discardableResult
    public func restore(relativePath: String, config: AppConfig) throws -> URL {
        let store = DeleteStore(paths: paths)
        let fm = FileManager.default

        var recordByReplica: [UUID: DeleteRecord] = [:]
        for replica in config.replicas {
            if let record = store.load(replicaID: replica.id).first(where: { $0.relativePath == relativePath }) {
                recordByReplica[replica.id] = record
            }
        }
        guard let primary = recordByReplica.values.min(by: { $0.deletedAt < $1.deletedAt }) else {
            throw NeoDropError.retainedCopyUnavailable(relativePath)
        }
        // No digest means no way to tell a good copy from a corrupt one, so there is nothing to
        // verify a restore against. Refuse rather than write bytes we cannot vouch for.
        guard !primary.sha256.isEmpty else { throw NeoDropError.retainedCopyUnavailable(relativePath) }
        guard let target = Self.restoreTarget(record: primary, relativePath: relativePath, config: config) else {
            throw NeoDropError.restoreSourceUnavailable(relativePath)
        }
        guard Self.isUsableDirectory(target.source.url) else {
            throw NeoDropError.restoreSourceUnavailable(target.source.displayName)
        }

        if fm.fileExists(atPath: target.destination.path) {
            if let existing = try? Hashing.sha256(ofFileAt: target.destination), existing == primary.sha256 {
                // Already back (by hand, or by the other source root). Treat it as done and give
                // the retained copies back.
                discardRetainedCopies(relativePath: relativePath, config: config)
                return target.destination
            }
            throw NeoDropError.restoreConflict(target.destination.path)
        }

        var lastError: Error = NeoDropError.retainedCopyUnavailable(relativePath)
        var restored = false
        // Replicas are tried in the order the user configured them, so the fastest share wins.
        for replica in config.replicas {
            guard let record = recordByReplica[replica.id], Self.isUsableDirectory(replica.url) else { continue }
            let trashURL = record.trashURL(onReplicaRoot: replica.url)
            guard Self.isInside(trashURL, of: trashRoot(replica.url)),
                  fm.fileExists(atPath: trashURL.path) else { continue }
            do {
                let digest = try Hashing.sha256(ofFileAt: trashURL)
                guard digest == primary.sha256 else {
                    throw NeoDropError.retainedCopyUnavailable(relativePath)
                }
                try AtomicFile.copy(from: trashURL, to: target.destination)
                guard let written = try? Hashing.sha256(ofFileAt: target.destination), written == digest else {
                    // Do not leave a copy we cannot vouch for where the original used to be.
                    try? fm.removeItem(at: target.destination)
                    throw NeoDropError.verificationFailed(target.destination.path)
                }
                restored = true
                break
            } catch {
                lastError = error
            }
        }
        guard restored else { throw lastError }

        discardRetainedCopies(relativePath: relativePath, config: config)
        return target.destination
    }

    /// Hand back the space of deletions whose window has closed: bytes first, then the record.
    ///
    /// That order matters. An interrupted purge can then only leave a record whose bytes are
    /// gone — which the next sync reconciles away — never bytes with no record, which nothing
    /// would ever find again.
    @discardableResult
    public func purgeExpiredDeletions(config: AppConfig) -> Int {
        let store = DeleteStore(paths: paths)
        let fm = FileManager.default
        let now = Date()
        var purged = 0

        for replica in config.replicas {
            // An unmounted share must be skipped, not treated as empty: its retained copies are
            // still there, and dropping the records now would orphan them forever.
            guard Self.isUsableDirectory(replica.url) else { continue }
            let records = store.load(replicaID: replica.id)
            guard records.contains(where: { $0.expiresAt <= now }) else { continue }

            let trashRoot = self.trashRoot(replica.url)
            var kept: [DeleteRecord] = []
            var changed = false
            for record in records {
                guard record.expiresAt <= now else {
                    kept.append(record)
                    continue
                }
                let trashURL = record.trashURL(onReplicaRoot: replica.url)
                guard Self.isInside(trashURL, of: trashRoot) else {
                    // A record that points outside the trash directory is not ours to act on:
                    // drop it and never touch the file it names.
                    changed = true
                    continue
                }
                if fm.fileExists(atPath: trashURL.path), (try? fm.removeItem(at: trashURL)) == nil {
                    // Could not free the bytes (read-only share, open handle): keep the record and
                    // retry on the next sync rather than lose track of the copy.
                    kept.append(record)
                    continue
                }
                purged += 1
                changed = true
            }
            if changed { try? store.save(kept, for: replica.id) }
        }
        return purged
    }

    /// Keep the retention list honest on every sync, whatever `mirrorDeletions` says now:
    ///
    /// * a file that is back in the source with the same digest was restored — the deletion is
    ///   undone, so the record and the retained bytes both go;
    /// * a record whose retained bytes are missing cannot restore anything, so it is only a dead
    ///   row in the deleted-files view;
    /// * a record that points outside the trash directory is never acted on.
    private func reconcileRetainedCopies(replica: Replica, plan: SourcePlan) {
        let store = DeleteStore(paths: paths)
        let records = store.load(replicaID: replica.id)
        guard !records.isEmpty else { return }

        let fm = FileManager.default
        let trashRoot = self.trashRoot(replica.url)
        var changed = false
        let kept = records.filter { record in
            let trashURL = record.trashURL(onReplicaRoot: replica.url)
            guard Self.isInside(trashURL, of: trashRoot) else {
                changed = true
                return false
            }
            if let back = plan.files[record.relativePath],
               !record.sha256.isEmpty,
               back.sha256 == record.sha256 {
                if fm.fileExists(atPath: trashURL.path), (try? fm.removeItem(at: trashURL)) == nil {
                    return true
                }
                changed = true
                return false
            }
            if !fm.fileExists(atPath: trashURL.path) {
                changed = true
                return false
            }
            return true
        }
        if changed { try? store.save(kept, for: replica.id) }
    }

    /// Forget a restored file on every destination that still holds it.
    ///
    /// Bytes go first and the record second, so an interrupted pass leaves at most a record with
    /// nothing behind it, which the next sync reconciles away. Unreachable destinations are left
    /// alone on purpose: their copies are still there, and the next sync drops the record once it
    /// sees the file back in the source.
    private func discardRetainedCopies(relativePath: String, config: AppConfig) {
        let store = DeleteStore(paths: paths)
        let fm = FileManager.default
        for replica in config.replicas {
            guard Self.isUsableDirectory(replica.url) else { continue }
            let records = store.load(replicaID: replica.id)
            guard records.contains(where: { $0.relativePath == relativePath }) else { continue }

            let trashRoot = self.trashRoot(replica.url)
            var kept: [DeleteRecord] = []
            for record in records where record.relativePath == relativePath {
                let trashURL = record.trashURL(onReplicaRoot: replica.url)
                guard Self.isInside(trashURL, of: trashRoot) else { continue }
                if fm.fileExists(atPath: trashURL.path), (try? fm.removeItem(at: trashURL)) == nil {
                    kept.append(record)
                }
            }
            kept.append(contentsOf: records.filter { $0.relativePath != relativePath })
            try? store.save(kept, for: replica.id)
        }
    }

    // MARK: - Runtime state

    private func persistRuntime(summary: SyncSummary, verified: Bool = false) {
        var state = runtimeStore.load()
        let now = Date()
        for report in summary.replicas {
            state.update(report.id) { runtime in
                runtime.status = report.status
                runtime.lastError = report.errors.first
                if verified {
                    runtime.lastVerify = now
                    runtime.corrupt = report.corrupt
                } else {
                    runtime.lastSync = now
                }
            }
        }
        if verified { state.lastVerify = now } else { state.lastSync = now }
        let failures = summary.replicas.flatMap(\.errors)
        if let first = failures.first { state.lastError = first }
        try? runtimeStore.save(state)
    }

    // MARK: - Helpers

    /// A replica must be an existing directory. Never create it: an unmounted share would make
    /// us write into the boot volume at the same path.
    public static func isUsableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// Where a record's retained bytes live on a replica.
    private func trashRoot(_ replicaRoot: URL) -> URL {
        replicaRoot.appendingPathComponent(DeleteRecord.trashDirectoryName, isDirectory: true)
    }

    /// Guard for every path derived from a record on disk: a hand-edited or corrupt record must
    /// never be able to point a delete or a restore outside the directory it belongs in.
    static func isInside(_ child: URL, of root: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// Where a restore may write: the absolute path recorded at deletion time, or the path
    /// re-derived from the mirrored name when that record predates a configuration change — but
    /// only when it lands inside a source root the user still protects.
    static func restoreTarget(
        record: DeleteRecord,
        relativePath: String,
        config: AppConfig
    ) -> (destination: URL, source: SourceRoot)? {
        var candidates = [sourcePath(forMirroredPath: relativePath, config: config)]
        if !record.sourcePath.isEmpty { candidates.insert(record.sourcePath, at: 0) }
        for path in candidates where !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            for source in config.sources where isInside(url, of: source.url) {
                return (url, source)
            }
        }
        return nil
    }

    /// Remove now-empty directories that NeoDrop emptied, without ever touching the root.
    static func pruneEmptyDirectories(root: URL, keeping planned: Set<String>) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator where FileMeta.isDirectory(url) {
            directories.append(url)
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            guard directory.standardizedFileURL != root.standardizedFileURL else { continue }
            let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            if contents.isEmpty {
                try? fm.removeItem(at: directory)
            }
        }
    }
}

public enum NeoDropError: Error, LocalizedError {
    case verificationFailed(String)
    case noHealthyReplica
    case replicaUnavailable(String)
    case restoreConflict(String)
    case restoreSourceUnavailable(String)
    case retainedCopyUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .verificationFailed(let path):
            return "The copy written to \(path) did not match the source checksum"
        case .noHealthyReplica:
            return "No replica holds a verified copy of this file"
        case .replicaUnavailable(let path):
            return "Replica is not available: \(path)"
        case .restoreConflict(let path):
            return "A different file already exists at \(path) — nothing was overwritten"
        case .restoreSourceUnavailable(let path):
            return "The original folder is no longer configured, so \(path) has nowhere to go"
        case .retainedCopyUnavailable(let path):
            return "No destination holds a verified retained copy of \(path)"
        }
    }
}

/// Read-only view of a replica for the menu and settings window.
public struct ReplicaSnapshot: Identifiable, Sendable {
    public var id: UUID { replica.id }
    public var replica: Replica
    public var status: ReplicaStatus
    public var files: Int
    public var bytes: Int64
    public var corrupt: Int
    public var lastSync: Date?
    public var lastVerify: Date?
    public var lastError: String?

    public init(
        replica: Replica,
        status: ReplicaStatus,
        files: Int,
        bytes: Int64,
        corrupt: Int,
        lastSync: Date? = nil,
        lastVerify: Date? = nil,
        lastError: String? = nil
    ) {
        self.replica = replica
        self.status = status
        self.files = files
        self.bytes = bytes
        self.corrupt = corrupt
        self.lastSync = lastSync
        self.lastVerify = lastVerify
        self.lastError = lastError
    }

    public var displayName: String { replica.displayName }
}

public struct SourceStats: Sendable {
    public var fileCount: Int
    public var byteCount: Int64
    public var missingSources: [String]

    public init(fileCount: Int, byteCount: Int64, missingSources: [String]) {
        self.fileCount = fileCount
        self.byteCount = byteCount
        self.missingSources = missingSources
    }
}
