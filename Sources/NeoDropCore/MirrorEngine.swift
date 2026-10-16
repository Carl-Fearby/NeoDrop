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
                    // Repair overwrites the bad copy too. It might be a damaged transfer, or it
                    // might be an edit made on the share; either way these are bytes that would
                    // otherwise exist nowhere after repair, so retain them before writing. A
                    // directory is not a repair candidate: it may hold someone's files.
                    let retention: Retention
                    if FileManager.default.fileExists(atPath: destination.path) {
                        retention = retainOverwrittenBytes(
                            relativePath: relativePath, replica: replica, config: config
                        )
                    } else {
                        retention = .nothingToKeep
                    }
                    switch retention {
                    case .notNeoDropsCopy:
                        report.failed += 1
                        report.errors.append("\(relativePath): a folder is sitting where this file belongs on \(replica.displayName) — it was left alone during repair.")
                        continue
                    case .failed(let why):
                        report.failed += 1
                        report.errors.append("\(relativePath): could not keep the replaced bytes for recovery (\(why)) — repair was not written.")
                        continue
                    case .kept:
                        report.replaced += 1
                    case .nothingToKeep:
                        break
                    }
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
        /// Paths where something else is sitting this run, for the manifest (the Finder badge and
        /// the report both read it).
        var foreign: [String] = []

        for (relativePath, file) in plan.files {
            doneFiles += 1
            let destination = replica.url.appendingPathComponent(relativePath)
            let sizeOnReplica = FileMeta.size(ofFileAt: destination)

            if let entry = manifest.entries[relativePath],
               entry.sha256 == file.sha256,
               entry.size == file.size,
               sizeOnReplica == file.size {
                report.upToDate += 1
                doneBytes += file.size
                continue
            }

            // Something is already at this path and NeoDrop has no record of writing it. The bytes
            // tell two very different situations apart, and getting this wrong loses data:
            //
            //   * identical to the source — the manifest is gone (a reset, a fresh install pointed at
            //     an existing mirror, a state directory restored from a backup) and this is NeoDrop's
            //     own copy. Adopt it: the mirror is already correct, and re-uploading a whole library
            //     over a share at every clean install is exactly what the reset instructions promise
            //     will not happen.
            //   * different — it is somebody else's file, and a mirror must not replace it. This is
            //     the one operation in the engine that can destroy a file that exists nowhere else
            //     (the badges call it “Not written by NeoDrop”), so it is left exactly as it is and
            //     reported. Moving or deleting it on the share is the user's decision, and the next
            //     sync takes the path then.
            //
            // The size is read first because it costs nothing: only a same-size candidate is worth
            // hashing, and a directory sitting where a file belongs (a size, but not a file's) is
            // somebody else's too.
            if manifest.entries[relativePath] == nil,
               FileManager.default.fileExists(atPath: destination.path) {
                if !FileMeta.isDirectory(destination),
                   let sizeOnReplica,
                   sizeOnReplica == file.size,
                   let digest = try? Hashing.sha256(ofFileAt: destination), digest == file.sha256 {
                    manifest.entries[relativePath] = ManifestEntry(
                        size: file.size,
                        mtime: file.mtime,
                        sha256: file.sha256,
                        verifiedAt: Date(),
                        sourceID: file.sourceID
                    )
                    report.adopted += 1
                    doneBytes += file.size
                    continue
                }
                // This includes directories: they are not adoptable, but the user should still
                // see that the path is blocked, and automatic sync must never replace its tree.
                foreign.append(relativePath)
                report.foreign += 1
                doneBytes += file.size
                continue
            }

            // A previous run may have written these exact source bytes, then crashed or failed to
            // save its manifest. They are already the wanted version, not a hand edit to preserve:
            // verify the digest, reconcile the manifest and move on without rewriting or refusing.
            // This also covers a user who has independently put the exact source bytes on the share.
            if manifest.entries[relativePath] != nil,
               sizeOnReplica == file.size,
               let digestOnReplica = try? Hashing.sha256(ofFileAt: destination),
               digestOnReplica == file.sha256 {
                manifest.entries[relativePath] = ManifestEntry(
                    size: file.size,
                    mtime: file.mtime,
                    sha256: file.sha256,
                    verifiedAt: Date(),
                    sourceID: file.sourceID
                )
                report.upToDate += 1
                doneBytes += file.size
                continue
            }

            let isUpdate = manifest.entries[relativePath] != nil
            // A replacement is the second way a version leaves the mirror, and the only one where
            // NeoDrop is about to write over bytes it put on the share itself. Keep them first —
            // the same retention a deletion gets — or refuse the copy. The alternative is an edit
            // that afterwards exists nowhere, which is the one outcome a mirror must never produce
            // quietly.
            var retention = Retention.nothingToKeep
            if let entry = manifest.entries[relativePath] {
                retention = retainReplacedVersion(
                    relativePath: relativePath, replica: replica, entry: entry, config: config
                )
                if retention == .kept { report.replaced += 1 }
            }

            switch retention {
            case .notNeoDropsCopy:
                // The path is NeoDrop's, but what is at it is not the bytes NeoDrop recorded: an
                // edit made straight on the share, an upload that stopped halfway, or a folder
                // where the file belongs. They exist nowhere else, so they are left alone and
                // named — overwriting here is how the mirror would eat an edit it never saw.
                report.failed += 1
                let what = FileMeta.isDirectory(destination)
                    ? "a folder is sitting where this file belongs"
                    : "the copy is not the version NeoDrop wrote (changed on the share, or partial)"
                report.errors.append(
                    "\(relativePath): \(what) on \(replica.displayName) — it was left alone, so the source version was not mirrored there."
                )
            case .failed(let why):
                report.failed += 1
                report.errors.append(
                    "\(relativePath): could not keep the previous version for recovery (\(why)) — the copy on \(replica.displayName) was left as it is."
                )
            case .nothingToKeep, .kept:
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
        // Replaced rather than appended to: a path that is NeoDrop's again has stopped being an
        // exception, and a stale entry would keep badging a file that is now perfectly in sync.
        manifest.foreignPaths = foreign
        try? manifestStore.save(manifest)

        if !foreign.isEmpty {
            let named = foreign.sorted().prefix(3).joined(separator: ", ")
            report.errors.append(
                "\(foreign.count) file(s) on \(replica.displayName) were not written by NeoDrop and were left untouched: \(named)\(foreign.count > 3 ? ", …" : ""). Delete or move them on the share and the next sync will mirror there."
            )
        }

        report.errors.append(contentsOf: plan.errors)
        report.status = report.failed > 0 || !report.errors.isEmpty ? .degraded : .online
        return report
    }

    /// List the recorded foreign paths, including offline or otherwise unreplaceable conflicts.
    /// Hashing is bounded to just the conflicts the user opened, not the whole mirror. The hash is
    /// returned for optimistic concurrency: replace refuses if those exact bytes have since changed.
    public func listForeignCopies(config: AppConfig) -> [ForeignCopyEntry] {
        config.replicas.flatMap { replica -> [ForeignCopyEntry] in
            let manifest = manifestStore.load(replicaID: replica.id)
            return manifest.foreignPaths.sorted().map { relativePath in
                let url = replica.url.appendingPathComponent(relativePath)
                let available = replica.enabled && Self.isUsableDirectory(replica.url)
                let isFile = available && FileManager.default.fileExists(atPath: url.path)
                    && !FileMeta.isDirectory(url)
                let source = Self.sourceFile(forMirroredPath: relativePath, config: config)
                let sourceAvailable = source.map {
                    Self.isUsableDirectory($0.root.url)
                        && FileManager.default.fileExists(atPath: $0.file.path)
                        && !FileMeta.isDirectory($0.file)
                } ?? false
                let size = isFile ? FileMeta.size(ofFileAt: url) : nil
                let digest = isFile ? try? Hashing.sha256(ofFileAt: url) : nil
                let replaceable = isFile && digest != nil && sourceAvailable
                let reason: String?
                if !available { reason = "Destination is offline or disabled" }
                else if !isFile { reason = "The conflict is no longer a regular file on the share" }
                else if digest == nil { reason = "The file on the share could not be read" }
                else if !sourceAvailable { reason = "The corresponding source file is unavailable" }
                else { reason = nil }
                return ForeignCopyEntry(
                    relativePath: relativePath,
                    replicaID: replica.id,
                    replicaName: replica.displayName,
                    absolutePath: url.path,
                    sourcePath: source?.file.path,
                    size: size,
                    sha256: digest,
                    replaceable: replaceable,
                    unavailableReason: reason
                )
            }
        }
    }

    /// Explicitly replace a foreign file on one replica with the live source's bytes.
    ///
    /// This is the deliberate, in-app counterpart to the sync rule that never replaces foreign
    /// data automatically. It is scoped to a single configured enabled replica and requires all
    /// of the following before it acts:
    ///
    /// * the path is valid, is a regular file, and is currently listed in that replica's
    ///   `foreignPaths`;
    /// * the destination is currently a regular file whose digest still matches the digest NeoDrop
    ///   showed in the confirmation UI, so a file changed after the user saw the dialog is refused;
    /// * the source still exists, and its digest is computed at action time;
    /// * the share copy and its `.replaced` recovery record are safely retained before replacement.
    ///
    /// Directories and untracked path conflicts are not eligible. A successful operation updates
    /// that replica's manifest and removes its foreign badge; the caller starts a normal sync so
    /// the other replicas receive the source bytes as usual.
    public func replaceForeignCopy(
        relativePath: String,
        replicaID: UUID,
        expectedForeignSHA256: String,
        config: AppConfig
    ) throws -> URL {
        guard Self.isSafeRelativePath(relativePath),
              expectedForeignSHA256.count == 64,
              expectedForeignSHA256.allSatisfy({ $0.isHexDigit }),
              let replica = config.enabledReplicas.first(where: { $0.id == replicaID }),
              Self.isUsableDirectory(replica.url) else {
            throw NeoDropError.foreignCopyUnavailable(relativePath)
        }
        var manifest = manifestStore.load(replicaID: replica.id)
        guard manifest.foreignPaths.contains(relativePath) else {
            throw NeoDropError.foreignCopyChanged(relativePath)
        }

        let destination = replica.url.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: destination.path),
              !FileMeta.isDirectory(destination),
              let digest = try? Hashing.sha256(ofFileAt: destination),
              digest == expectedForeignSHA256 else {
            throw NeoDropError.foreignCopyChanged(relativePath)
        }
        guard let source = Self.sourceFile(forMirroredPath: relativePath, config: config),
              Self.isUsableDirectory(source.root.url),
              FileManager.default.fileExists(atPath: source.file.path),
              !FileMeta.isDirectory(source.file) else {
            throw NeoDropError.restoreSourceUnavailable(relativePath)
        }
        guard let sourceDigest = try? Hashing.sha256(ofFileAt: source.file),
              let sourceSize = FileMeta.size(ofFileAt: source.file) else {
            throw NeoDropError.restoreSourceUnavailable(source.file.path)
        }
        let sourceMtime = FileMeta.modificationDate(ofFileAt: source.file) ?? Date()

        let previousRecord = DeleteStore(paths: paths).load(replicaID: replica.id)
            .first { $0.relativePath == relativePath }
        switch retainOverwrittenBytes(relativePath: relativePath, replica: replica, config: config) {
        case .kept:
            // A second digest check catches an edit racing the first check. Its bytes are safe in
            // retention, but this request was confirmed against a different file, so do not write
            // the source over it on a stale confirmation. Roll back only the record written by
            // this call; preserve an older record if the move failed partway through.
            let records = DeleteStore(paths: paths).load(replicaID: replica.id)
            guard records.first(where: { $0.relativePath == relativePath })?.sha256 == expectedForeignSHA256 else {
                var restoredRecords = records.filter { $0.relativePath != relativePath }
                if let previousRecord { restoredRecords.append(previousRecord) }
                try? DeleteStore(paths: paths).save(restoredRecords, for: replica.id)
                throw NeoDropError.foreignCopyChanged(relativePath)
            }
        case .notNeoDropsCopy:
            throw NeoDropError.foreignCopyChanged(relativePath)
        case .nothingToKeep:
            throw NeoDropError.foreignCopyUnavailable(relativePath)
        case .failed(let reason):
            throw NeoDropError.foreignCopyRetentionFailed(relativePath, reason)
        }

        // Copy only after the bytes on the share are in the recoverable store. If the copy fails,
        // the old share bytes remain available in the recovery list, and no tracking record claims
        // that the new bytes have landed.
        do {
            try copy(source.file, to: destination, config: config)
        } catch {
            throw error
        }
        manifest.entries[relativePath] = ManifestEntry(
            size: sourceSize,
            mtime: sourceMtime,
            sha256: sourceDigest,
            sourceID: source.root.id
        )
        manifest.foreignPaths.removeAll { $0 == relativePath }
        manifest.lastSync = Date()
        try manifestStore.save(manifest)
        return destination
    }

    /// A mirrored path is data, never a path traversal command from an HTTP request or JSON record.
    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Resolve a mirrored path to the one source file it represents. Multi-source mirrors are
    /// namespaced by display name, matching `buildSourcePlan` exactly.
    private static func sourceFile(forMirroredPath path: String, config: AppConfig) -> (root: SourceRoot, file: URL)? {
        guard !config.sources.isEmpty, isSafeRelativePath(path) else { return nil }
        if config.sources.count == 1 {
            let root = config.sources[0]
            return (root, root.url.appendingPathComponent(path))
        }
        for root in config.sources {
            let prefix = root.displayName + "/"
            guard path.hasPrefix(prefix) else { continue }
            let suffix = String(path.dropFirst(prefix.count))
            guard !suffix.isEmpty else { return nil }
            return (root, root.url.appendingPathComponent(suffix))
        }
        return nil
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

    // MARK: - Keeping the version a copy is about to replace

    /// What happened when the sync tried to keep the version it is about to overwrite.
    private enum Retention: Equatable {
        /// Nothing is there to keep: nothing exists at the path, so the copy is a clean create.
        case nothingToKeep
        /// The previous version is in the trash, recorded, and the new bytes may be written.
        case kept
        /// What is at the path is not the version NeoDrop recorded: different bytes (an edit on the
        /// share, a partial upload) or not a file at all.
        case notNeoDropsCopy
        /// The previous version could not be kept, so nothing was written over it.
        case failed(String)
    }

    /// In a regular sync, move the copy that is about to be replaced into the replica's trash and
    /// record it, so an overwritten edit stays recoverable for the retention window instead of
    /// existing nowhere afterwards. Only bytes matching the manifest are eligible: an edit made
    /// straight on the share, or an interrupted upload, is left alone rather than overwritten.
    /// Verify & Repair has its own path below: it may keep mismatching bytes, since repair is the
    /// explicit instruction to replace a bad copy.
    private func retainReplacedVersion(
        relativePath: String,
        replica: Replica,
        entry: ManifestEntry,
        config: AppConfig
    ) -> Retention {
        let destination = replica.url.appendingPathComponent(relativePath)
        guard let size = FileMeta.size(ofFileAt: destination),
              let digest = try? Hashing.sha256(ofFileAt: destination),
              size == entry.size, digest == entry.sha256 else {
            return FileManager.default.fileExists(atPath: destination.path)
                ? .notNeoDropsCopy
                : .nothingToKeep
        }
        return retainBytes(relativePath: relativePath, replica: replica, size: size,
                           digest: digest, config: config)
    }

    /// Verify & Repair is explicitly allowed to replace a copy that no longer matches the
    /// manifest. That copy may be a partial transfer or somebody's edit on the share; keep its
    /// actual bytes and digest before repair, so the chosen repair source cannot make them vanish.
    private func retainOverwrittenBytes(
        relativePath: String,
        replica: Replica,
        config: AppConfig
    ) -> Retention {
        let destination = replica.url.appendingPathComponent(relativePath)
        guard !FileMeta.isDirectory(destination) else { return .notNeoDropsCopy }
        guard let size = FileMeta.size(ofFileAt: destination),
              let digest = try? Hashing.sha256(ofFileAt: destination) else {
            return .failed("the existing copy could not be read and hashed")
        }
        return retainBytes(relativePath: relativePath, replica: replica, size: size,
                           digest: digest, config: config)
    }

    /// Persist and move actual replica bytes into retention after their digest has been verified.
    private func retainBytes(
        relativePath: String,
        replica: Replica,
        size: Int64,
        digest: String,
        config: AppConfig
    ) -> Retention {
        let fm = FileManager.default
        let destination = replica.url.appendingPathComponent(relativePath)
        guard !FileMeta.isDirectory(destination), fm.fileExists(atPath: destination.path) else {
            return .failed("the copy that was about to be retained is no longer a regular file")
        }
        let store = DeleteStore(paths: paths)
        var records = store.load(replicaID: replica.id)
        // One version per path: a newer retention supersedes the previous one for the same file.
        records.removeAll { $0.relativePath == relativePath }
        let trashURL = DeleteRecord(relativePath: relativePath, sourcePath: "", size: 0, sha256: "")
            .trashURL(onReplicaRoot: replica.url)
        guard Self.isInside(trashURL, of: trashRoot(replica.url)) else {
            return .failed("the path for its retained copy is outside the replica")
        }
        records.append(DeleteRecord(
            relativePath: relativePath,
            sourcePath: Self.sourcePath(forMirroredPath: relativePath, config: config),
            size: size,
            sha256: digest,
            reason: .replaced
        ))
        do {
            try store.save(records, for: replica.id)
        } catch {
            return .failed(error.localizedDescription)
        }
        do {
            try fm.createDirectory(at: trashURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: trashURL.path) {
                try fm.removeItem(at: trashURL)
            }
            // One rename inside the share: the bytes never travel.
            try fm.moveItem(at: destination, to: trashURL)
        } catch {
            // Never leave a record claiming bytes that are not in the trash.
            records.removeAll { $0.relativePath == relativePath }
            try? store.save(records, for: replica.id)
            return .failed(error.localizedDescription)
        }
        return .kept
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

    /// A place that holds retained copies of deleted files: a replica, or the local folder of a
    /// two-way vault link (a deletion another machine published moves the file into that folder's
    /// trash, exactly like a mirrored deletion does).
    ///
    /// Recovery has to treat both the same way, or a vault's trash would grow forever and a file
    /// deleted from one Mac could never be listed, let alone restored.
    struct DeleteDestination {
        var id: UUID
        var name: String
        /// The root the retained copies live under, in `.neodrop-trash/`.
        var root: URL
        var isAvailable: Bool
    }

    static func deleteDestinations(config: AppConfig) -> [DeleteDestination] {
        config.replicas.map {
            DeleteDestination(id: $0.id, name: $0.displayName, root: $0.url, isAvailable: isUsableDirectory($0.url))
        } + config.vaults.map {
            DeleteDestination(id: $0.id, name: $0.displayName, root: $0.localURL, isAvailable: isUsableDirectory($0.localURL))
        }
    }

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

        for destination in Self.deleteDestinations(config: config) {
            let records = store.load(replicaID: destination.id)
            guard !records.isEmpty else { continue }
            // A reachable destination with a retained copy is what makes an entry restorable;
            // an unmounted share is reported as unavailable rather than assumed gone.
            let reachable = destination.isAvailable
            let trashRoot = self.trashRoot(destination.root)
            for record in records where record.expiresAt > now {
                let trashURL = record.trashURL(onReplicaRoot: destination.root)
                let available = reachable
                    && Self.isInside(trashURL, of: trashRoot)
                    && fm.fileExists(atPath: trashURL.path)
                recordsByPath[record.relativePath, default: []].append(record)
                copiesByPath[record.relativePath, default: []].append(
                    DeletionCopy(replicaID: destination.id, replicaName: destination.name, available: available)
                )
            }
        }

        // Written out one value at a time on purpose: as a single expression this closure is more
        // than the type checker will accept in reasonable time.
        return recordsByPath.compactMap { relativePath, records -> DeletionEntry? in
            guard let earliest = records.min(by: { $0.deletedAt < $1.deletedAt }) else { return nil }
            let sourcePath: String = records.first(where: { !$0.sourcePath.isEmpty })?.sourcePath
                ?? earliest.sourcePath
            // The entry is only as safe as its weakest copy: the window closes for all of them at
            // the first expiry, because that is when any of them may be purged.
            let expiresAt: Date = records.map(\.expiresAt).min() ?? earliest.expiresAt
            let copies: [DeletionCopy] = (copiesByPath[relativePath] ?? [])
                .sorted { $0.replicaName < $1.replicaName }
            return DeletionEntry(
                relativePath: relativePath,
                sourcePath: sourcePath,
                size: earliest.size,
                sha256: earliest.sha256,
                deletedAt: earliest.deletedAt,
                expiresAt: expiresAt,
                copies: copies,
                // What happened is the earliest record's story: the first replica to let the
                // bytes go is the one that decided whether the file was deleted or replaced.
                reason: earliest.reason
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

    /// Put a retained version back where it came from, using the best verified copy. Both kinds of
    /// record come through here: a file that was deleted everywhere, and the version a newer one
    /// replaced. Restoring either is the same operation — a verified copy goes back to the source
    /// path the record names — so they share every rule below and the same button.
    ///
    /// Safety rules, in the same spirit as the rest of the engine:
    ///
    /// * A restore never guesses. Overwriting what is at the destination happens for one reason
    ///   only: putting an earlier version back over the one that superseded it. Even then it needs
    ///   the version it is about to write over to be verifiably on a mounted replica already
    ///   (`newerVersionIsOnAReplica`) — otherwise the file at that path is the user's newest work,
    ///   it exists nowhere else, and the restore is refused with the reason rather than done.
    /// * Restoring a deleted file still refuses to overwrite anything: a file the user put at that
    ///   path is newer than the deletion, and only the user undoes a deletion.
    /// * If the destination already holds the retained bytes, the restore counts as done and the
    ///   retained copies are handed back.
    /// * The retained bytes are verified against the digest in the record before the source
    ///   folder is touched, and the written copy is verified again after it lands.
    /// * The destination is validated against the configured source roots, so a record that was
    ///   edited on disk cannot point a restore outside the folders the user protects.
    @discardableResult
    public func restore(relativePath: String, config: AppConfig) throws -> URL {
        let store = DeleteStore(paths: paths)
        let fm = FileManager.default
        let destinations = Self.deleteDestinations(config: config)

        var recordByDestination: [UUID: DeleteRecord] = [:]
        for destination in destinations {
            if let record = store.load(replicaID: destination.id).first(where: { $0.relativePath == relativePath }) {
                recordByDestination[destination.id] = record
            }
        }
        guard let primary = recordByDestination.values.min(by: { $0.deletedAt < $1.deletedAt }) else {
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
            // A file is at the destination and it is not the version being restored.
            guard primary.reason == .replaced else {
                // A deletion: the file there is newer than the deletion, and undoing a deletion is
                // the user's call, not a side effect of pressing Restore.
                throw NeoDropError.restoreConflict(target.destination.path)
            }
            // A replacement: putting the earlier version back is exactly what was asked for, so
            // the newer file is overwritten — but only when it is provably on a mounted replica
            // already. Otherwise these are the user's newest bytes, on this Mac alone, and they
            // would be gone: the version being restored is still safely in the trash, so refusing
            // costs nothing that cannot be retried after a sync.
            guard newerVersionIsOnAReplica(
                relativePath: relativePath,
                fileAt: target.destination,
                config: config
            ) else {
                throw NeoDropError.restoreWouldLoseNewerWork(target.destination.path)
            }
        }

        var lastError: Error = NeoDropError.retainedCopyUnavailable(relativePath)
        var restored = false
        // Destinations are tried in the order the user configured them, so the fastest share wins.
        for destination in destinations {
            guard let record = recordByDestination[destination.id], destination.isAvailable else { continue }
            let trashURL = record.trashURL(onReplicaRoot: destination.root)
            guard Self.isInside(trashURL, of: trashRoot(destination.root)),
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

        // A restore into a two-way folder is an instruction to undo the deletion on every machine,
        // and the next reconcile cannot tell it apart from a Mac that was merely offline. Say which
        // one it is (`PendingUndeleteStore`), so this becomes an undelete rather than a copy beside
        // the original while the deletion stands.
        if config.vaults.contains(where: { $0.id == target.source.id }) {
            PendingUndeleteStore(paths: paths).mark(relativePath: relativePath, sha256: primary.sha256, linkID: target.source.id)
        }

        discardRetainedCopies(relativePath: relativePath, config: config)
        return target.destination
    }

    /// Is the version standing at `fileAt` verifiably on a mounted replica?
    ///
    /// This is the question a restore of a replaced version has to answer before it writes over
    /// the newer file. A digest match on a reachable replica means nothing is lost by putting the
    /// earlier version back — the share still holds the newer bytes, and they can be mirrored back
    /// whenever they are wanted. An unreachable replica is not an answer, for the same reason the
    /// retention bookkeeping never assumes an unmounted share is empty: a copy that cannot be read
    /// cannot be counted on.
    private func newerVersionIsOnAReplica(relativePath: String, fileAt file: URL, config: AppConfig) -> Bool {
        guard let size = FileMeta.size(ofFileAt: file),
              let digest = try? Hashing.sha256(ofFileAt: file) else { return false }
        for destination in Self.deleteDestinations(config: config) where destination.isAvailable {
            let copy = destination.root.appendingPathComponent(relativePath)
            guard FileMeta.size(ofFileAt: copy) == size,
                  let digestOnReplica = try? Hashing.sha256(ofFileAt: copy),
                  digestOnReplica == digest else { continue }
            return true
        }
        return false
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

        for destination in Self.deleteDestinations(config: config) {
            // An unmounted share must be skipped, not treated as empty: its retained copies are
            // still there, and dropping the records now would orphan them forever.
            guard destination.isAvailable else { continue }
            let records = store.load(replicaID: destination.id)
            guard records.contains(where: { $0.expiresAt <= now }) else { continue }

            let trashRoot = self.trashRoot(destination.root)
            var kept: [DeleteRecord] = []
            var changed = false
            for record in records {
                guard record.expiresAt <= now else {
                    kept.append(record)
                    continue
                }
                let trashURL = record.trashURL(onReplicaRoot: destination.root)
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
            if changed { try? store.save(kept, for: destination.id) }
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
        for destination in Self.deleteDestinations(config: config) {
            guard destination.isAvailable else { continue }
            let records = store.load(replicaID: destination.id)
            guard records.contains(where: { $0.relativePath == relativePath }) else { continue }

            let trashRoot = self.trashRoot(destination.root)
            var kept: [DeleteRecord] = []
            for record in records where record.relativePath == relativePath {
                let trashURL = record.trashURL(onReplicaRoot: destination.root)
                guard Self.isInside(trashURL, of: trashRoot) else { continue }
                if fm.fileExists(atPath: trashURL.path), (try? fm.removeItem(at: trashURL)) == nil {
                    kept.append(record)
                }
            }
            kept.append(contentsOf: records.filter { $0.relativePath != relativePath })
            try? store.save(kept, for: destination.id)
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
    ///
    /// Compared canonically (`PathIdentity`), because a record holds the spelling the enumerator
    /// produced while the configuration holds the spelling a person chose, and on macOS those differ
    /// for anything under `/var` — the same directory under two names.
    static func isInside(_ child: URL, of root: URL) -> Bool {
        PathIdentity.contains(root, child)
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
            // A two-way link's local folder is a legitimate place to put a file back, and the
            // reconcile that follows publishes it to the vault again — which is what makes a
            // restore here an undelete for every machine rather than a local-only fix.
            for link in config.vaults where isInside(url, of: link.localURL) {
                return (url, SourceRoot(id: link.id, name: link.displayName, path: link.localPath))
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
    case foreignCopyUnavailable(String)
    case foreignCopyChanged(String)
    case foreignCopyRetentionFailed(String, String)
    /// Restoring an earlier version was refused because the version it would write over is not on
    /// any mounted replica yet, so putting the earlier one back would lose the newer one.
    case restoreWouldLoseNewerWork(String)

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
        case .foreignCopyUnavailable(let path):
            return "No eligible foreign file is available to replace at \(path)"
        case .foreignCopyChanged(let path):
            return "The file on the share changed since it was listed; nothing was replaced at \(path). Refresh and review it again"
        case .foreignCopyRetentionFailed(let path, let reason):
            return "Could not preserve the file on the share at \(path) (\(reason)); nothing was replaced"
        case .restoreWouldLoseNewerWork(let path):
            return "The version of \(path) on this Mac has not reached a mounted destination yet, so putting the previous version back would lose it — sync first, then restore again"
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
