import Foundation

/// What one machine did in one reconcile. Flat and countable, so the menu can say "3 up, 12 down,
/// 1 conflict" without anyone reading a log.
public struct VaultSyncSummary: Sendable {
    public var vaultID: UUID
    public var vaultName: String
    public var machineName: String
    public var phase: SyncPhase
    public var startedAt: Date
    public var finishedAt: Date?
    /// Files this machine published to the vault (new and changed).
    public var uploaded = 0
    /// Files the vault gave this machine (new and changed) — every file of a seed lands here.
    public var downloaded = 0
    /// Deletions made elsewhere that this machine applied, keeping the bytes locally.
    public var remoteDeletionsApplied = 0
    /// Deletions made here that this machine published for the others.
    public var localDeletionsPublished = 0
    /// Content kept because it was overwritten: recoverable, not destroyed.
    public var versionsRetained = 0
    public var versionsPurged = 0
    /// Paths where both sides changed: the loser was kept as a conflicted copy.
    public var conflicts: [String] = []
    /// Vault files that were missing on the share and were repaired from retained content.
    public var repairs: [String] = []
    /// How many files the vault holds once this reconcile finished — the number the menu shows.
    public var filesInVault = 0
    /// Files found in the vault's live tree that no journal mentioned and that this machine took
    /// ownership of because a person put them there by hand.
    public var adoptedInVault = 0
    /// Files this machine put back at the user's request, which are therefore live on every machine
    /// again rather than only here.
    public var undeleted: [String] = []
    public var upToDate = 0
    public var bytesUp: Int64 = 0
    public var bytesDown: Int64 = 0
    public var errors: [String] = []
    /// True when this machine had never synced this vault and pulled the tree down.
    public var seeded = false
    /// More paths remain after this bounded pass; the next scheduled/manual sync resumes it.
    public var catchUpPending = false
    /// Number of paths included in this reconcile pass.
    public var catchUpProcessed = 0

    public init(vaultID: UUID, vaultName: String, machineName: String, phase: SyncPhase, startedAt: Date) {
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.machineName = machineName
        self.phase = phase
        self.startedAt = startedAt
    }

    public var finishedDate: Date { finishedAt ?? Date() }
    public var duration: TimeInterval { finishedDate.timeIntervalSince(startedAt) }
    public var changes: Int { uploaded + downloaded + remoteDeletionsApplied + localDeletionsPublished }
    public var isDegraded: Bool { !errors.isEmpty }

    /// Fold a later pass of the same sync into this one.
    ///
    /// A pass over a tree larger than `catchUpBatchSize` covers only a page of it, and the caller
    /// keeps calling until `catchUpPending` is false. That is one sync from the user's side, so it
    /// has to be counted and reported as one: without this, a folder of 2,000 files would report
    /// "500 sent" at the end of the sync that actually sent 2,000.
    public mutating func absorb(_ later: VaultSyncSummary) {
        uploaded += later.uploaded
        downloaded += later.downloaded
        remoteDeletionsApplied += later.remoteDeletionsApplied
        localDeletionsPublished += later.localDeletionsPublished
        versionsRetained += later.versionsRetained
        versionsPurged += later.versionsPurged
        conflicts += later.conflicts
        repairs += later.repairs
        undeleted += later.undeleted
        adoptedInVault += later.adoptedInVault
        upToDate += later.upToDate
        bytesUp += later.bytesUp
        bytesDown += later.bytesDown
        errors += later.errors
        catchUpProcessed += later.catchUpProcessed
        seeded = seeded || later.seeded
        // The last pass has the final word on these: they describe what is true now, not what each
        // page added on the way.
        catchUpPending = later.catchUpPending
        filesInVault = later.filesInVault
        phase = later.phase
        finishedAt = later.finishedAt
    }
}

public enum VaultError: Error, LocalizedError {
    case vaultUnavailable(String)
    case localFolderUnavailable(String)
    case foldersOverlap(String)
    case newerFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .vaultUnavailable(let path):
            return "The vault is not available: \(path) — is the share mounted?"
        case .localFolderUnavailable(let path):
            return "The local folder does not exist: \(path)"
        case .foldersOverlap(let path):
            return "The vault and the local folder overlap at \(path), so syncing would feed itself"
        case .newerFormat(let version):
            return "This vault was written by a newer version of NeoDrop (format \(version))"
        }
    }
}

/// Syncs one local folder with one vault, in both directions.
///
/// The model is a three-way merge. `applied` in the local cursor is the merge base — the content
/// this machine and the vault last agreed on — so for every path:
///
/// * local differs from the base, vault does not → publish the local file to the vault;
/// * vault differs, local does not → apply the vault's file here;
/// * both differ → a conflict, resolved by keeping both (see `resolveConflict`);
/// * local is gone but the base says it existed → publish a deletion;
/// * the vault says deleted and local still matches the base → delete it here, *into the trash*.
///
/// Nothing is ever destroyed: content that leaves the live tree is retained (vault-side in
/// `.neodrop/versions/`, locally in `.neodrop-trash/` with a record), and the losing side of a
/// conflict is kept as a conflicted copy.
public actor VaultSync {
    /// Maximum number of paths reconciled in one pass. A saved cursor resumes later work.
    public static let catchUpBatchSize = 500

    private let paths: StorePaths
    private let machineStore: MachineIdentityStore
    private let cursorStore: VaultCursorStore
    private let indexStore: SourceIndexStore
    private let indexer = SourceIndexer()

    private var running = false

    public init(paths: StorePaths = .standard) {
        self.paths = paths
        self.machineStore = MachineIdentityStore(paths: paths)
        self.cursorStore = VaultCursorStore(paths: paths)
        self.indexStore = SourceIndexStore(paths: paths)
    }

    public var isRunning: Bool { running }

    // MARK: - Reconcile

    @discardableResult
    public func reconcile(
        link: VaultLink,
        config: AppConfig,
        progress: @Sendable (SyncProgress) -> Void = { _ in }
    ) async -> VaultSyncSummary? {
        guard !running else { return nil }
        running = true
        defer { running = false }

        let machine = machineStore.loadOrCreate()
        var summary = VaultSyncSummary(
            vaultID: link.id,
            vaultName: link.displayName,
            machineName: machine.name,
            phase: .scanning,
            startedAt: Date()
        )
        progress(SyncProgress(phase: .scanning, replicaName: link.displayName))

        let store = VaultStore(root: link.vaultURL)

        // The safety rules that already govern replicas govern the vault too. A vault root that is
        // not there is an unmounted share, and creating it would sync onto the boot volume; a local
        // folder that is not there is a missing volume, not an empty folder.
        //
        // Overlap is checked first because it is the configuration that must never be tolerated:
        // telling someone "the share is not mounted" when the real problem is a vault nested
        // inside the folder it syncs would send them to fix the wrong thing.
        guard !Self.overlaps(link.localURL, link.vaultURL) else {
            return finish(&summary, phase: .failed("The folders overlap"), error: VaultError.foldersOverlap(link.localPath))
        }
        guard Self.isUsableDirectory(link.vaultURL) else {
            return finish(&summary, phase: .failed("The vault is not available"), error: VaultError.vaultUnavailable(link.vaultPath))
        }
        guard Self.isUsableDirectory(link.localURL) else {
            return finish(&summary, phase: .failed("The local folder is not there"), error: VaultError.localFolderUnavailable(link.localPath))
        }

        let identity: VaultIdentity
        do {
            try store.ensureDirectories()
            identity = try store.loadOrCreateIdentity(name: link.displayName)
        } catch {
            return finish(&summary, phase: .failed("The vault could not be prepared"), error: error)
        }
        summary.vaultID = identity.id
        guard identity.formatVersion <= VaultIdentity.currentFormatVersion else {
            return finish(&summary, phase: .failed("The vault is newer than this app"), error: VaultError.newerFormat(identity.formatVersion))
        }

        let loaded = store.loadEntries()
        summary.errors.append(contentsOf: loaded.errors)
        var state = store.state(from: loaded.entries)

        var cursor = cursorStore.load(vaultID: identity.id) ?? VaultCursor(vaultID: identity.id, machineID: machine.id)
        if cursor.machineID != machine.id {
            // The local state belongs to a different machine id: treat this as a first sync rather
            // than merging against a base that described someone else's tree.
            summary.errors.append("Local sync state was written by another machine id; starting from a fresh base")
            cursor = VaultCursor(vaultID: identity.id, machineID: machine.id)
        }
        let firstSync = cursor.applied.isEmpty
        var base = cursor.applied
        let existingJournalKeys = Set(state.files.keys)
        var reserved: Set<String> = []

        // MARK: scan local
        let folder = SourceRoot(id: link.id, name: link.displayName, path: link.localPath)
        // The user's excludes plus NeoDrop's own: `.neodrop-trash` holds content this machine took
        // out of the tree, and publishing our own bookkeeping is never intended.
        let excludes = ExcludeMatcher(patterns: Array(Set(config.excludes + AppConfig.defaultExcludes)))
        let scanned: [ScannedFile]
        do {
            scanned = try Scanner.scan(
                folder: folder,
                excludes: excludes,
                // Vault mode syncs hidden files: a Dropbox-like tool that quietly skipped `.env`
                // would be a trap. The two names below are the exception, always.
                includeHidden: true,
                hardSkips: [VaultStore.metadataDirectoryName, DeleteRecord.trashDirectoryName]
            )
        } catch {
            return finish(&summary, phase: .failed("The local folder could not be read"), error: error)
        }

        let orderedScanned = scanned.sorted { VaultPath.key($0.relativePath) < VaultPath.key($1.relativePath) }
        let previousIndex = indexStore.load()
        let indexed = indexer.refresh(files: orderedScanned, previous: previousIndex)
        summary.errors.append(contentsOf: indexed.errors)
        let localIndexChangedPaths = Set(orderedScanned.compactMap { file -> String? in
            let indexKey = "\(file.sourceID.uuidString)/\(file.relativePath)"
            guard let newEntry = indexed.index.entries[indexKey] else { return nil }
            guard let oldEntry = previousIndex.entries[indexKey],
                  oldEntry.sha256 != newEntry.sha256 else { return nil }
            return VaultPath.key(file.relativePath)
        })

        var local: [String: (file: ScannedFile, sha: String)] = [:]
        for file in orderedScanned {
            let indexKey = "\(file.sourceID.uuidString)/\(file.relativePath)"
            guard let entry = indexed.index.entries[indexKey], !entry.sha256.isEmpty else { continue }
            local[VaultPath.key(file.relativePath)] = (file, entry.sha256)
        }

        // MARK: adopt what was put on the share by hand
        //
        // A file sitting in the live tree that no journal mentions was placed there outside
        // NeoDrop — dragged onto the share, copied in from another app, or restored from a backup.
        // The vault is a browsable folder, so those files belong to the tree: they are adopted
        // here, attributed to this machine, and the ordinary loop hands them to every other
        // machine. A share that silently ignores files dropped into it is not a share.
        //
        // A path this machine holds locally is skipped: the local copy publishes it in the normal
        // way, and a hand-placed copy of something already in the tree is not new information.
        // A path whose newest entry is a *deletion* is adopted all the same, with this moment as
        // its time — the file is physically there, and letting a tombstone keep ignoring it would
        // leave it invisible on every Mac forever.
        let undeletes = PendingUndeleteStore(paths: paths)
        let pendingUndeletes = undeletes.load(linkID: link.id)
        var journal = JournalWriter(seq: store.nextSequence(machineID: machine.id.uuidString))
        var adopted = 0
        for path in store.untrackedFiles(known: existingJournalKeys, excludes: excludes) {
            let key = VaultPath.key(path)
            guard local[key] == nil else { continue }
            let url = store.fileURL(for: path)
            guard let sha = try? Hashing.sha256(ofFileAt: url) else {
                summary.errors.append("\(path): a file in the vault could not be read")
                continue
            }
            let size = FileMeta.size(ofFileAt: url) ?? 0
            journal.add(machine: machine, path: path, kind: .create, size: size, sha: sha, previous: nil)
            state.files[key] = journal.entries[journal.entries.count - 1]
            adopted += 1
        }
        summary.adoptedInVault = adopted

        // MARK: plan
        let allKeys = Set(state.files.keys).union(state.tombstones.keys).union(local.keys).union(base.keys)
        let orderedKeys = allKeys.sorted()
        let cursorStart = cursor.catchUpAfter
        let catchUpKeys = orderedKeys.filter { key in
            guard let cursorStart else { return true }
            return key > cursorStart
        }
        // Paths that need a look the forward walk will not give them.
        //
        // The saved cursor is what makes a pass over a large tree cheap, and it is also what makes
        // a path behind it invisible: until the walk finishes, nothing at or before the cursor is
        // ever visited again. Anything that changed since this machine's last pass therefore has
        // to be named here or it is skipped for good:
        //
        // * what changed in this folder — a local edit is the one change no journal announces;
        // * what changed in the vault on another machine, which the page would walk straight past;
        // * whatever a previous pass could not fit into its batch.
        let dirtyBefore = Set(cursor.catchUpDirtyPaths ?? [])
        let changedLocalKeys = Set(base.keys).filter { local[$0]?.sha != base[$0] }
        let watermark = cursor.catchUpSeenAt
        let changedInVaultKeys = Set(state.files.keys).union(state.tombstones.keys).filter { key in
            guard let watermark else { return false }
            // Only content this machine has not already agreed to: a path it is ahead of (or in
            // conflict over) is not "dirty", it is this machine's own work.
            if let entry = state.files[key] {
                return Self.millis(entry.at) > watermark && entry.sha256 != base[key]
            }
            guard let gone = state.tombstones[key] else { return false }
            // A tombstone says the path is gone, which the base spells as an empty digest.
            return Self.millis(gone.at) > watermark && base[key] != ""
        }
        let dirtyNow = dirtyBefore
            .union(changedLocalKeys)
            .union(localIndexChangedPaths)
            .union(changedInVaultKeys)

        // The forward walk, with room made for the dirty paths it would not reach: those behind
        // the cursor, and those past its cut. Dropping the page's *last* keys is what keeps that
        // safe — the cursor then stops short of them, so the next pass picks them up instead of
        // stepping over them. Never more than half the batch, so a page still moves forward even
        // when a great many paths are dirty.
        let behind = dirtyNow.subtracting(catchUpKeys.prefix(VaultSync.catchUpBatchSize))
        let displaced = min(behind.count, VaultSync.catchUpBatchSize / 2)
        let page = Array(catchUpKeys.prefix(VaultSync.catchUpBatchSize - displaced))
        let filled = behind.sorted().prefix(VaultSync.catchUpBatchSize - page.count)
        let batchKeys = Set(page).union(filled).sorted()
        // A path the vault changed since the last pass is carried one pass further on purpose: a
        // change that lands *while* this pass runs arrives after the journal was read, so the path
        // is re-checked rather than assumed handled. The watermark moves forward, so it clears
        // itself on the next pass instead of accumulating.
        let dirtyAfter = dirtyNow.subtracting(batchKeys).union(changedInVaultKeys)
        let catchUpPending = catchUpKeys.count > page.count || !dirtyAfter.isEmpty || (cursorStart != nil && adopted > 0)
        let deleteStore = DeleteStore(paths: paths)
        reconcileLocalDeleteRecords(link: link, local: local, deleteStore: deleteStore)

        // Deletions a remote machine published, gathered before anything is applied: a batch that
        // would empty this folder is exactly what the bulk guard is for, and refusing is the safe
        // outcome (both sides keep their data and the user is told).
        let remoteDeletions = batchKeys.filter { key in
            state.tombstones[key] != nil && local[key] != nil && base[key] == local[key]?.sha
        }
        var holdRemoteDeletions = false
        if MirrorEngine.exceedsDeletionGuard(
            pending: remoteDeletions.count,
            known: state.fileCount + remoteDeletions.count,
            allowBulkDeletions: config.allowBulkDeletions
        ) {
            holdRemoteDeletions = true
            summary.errors.append(
                "Held back \(remoteDeletions.count) deletion(s) another machine made: that is more than a quarter of this vault. Tick “Allow bulk deletions” in Settings if it was meant."
            )
        }
        let localDeletions = batchKeys.filter { key in
            state.files[key] != nil && local[key] == nil && base[key] == state.files[key]?.sha256 && base[key] != nil
        }
        var holdLocalDeletions = false
        if MirrorEngine.exceedsDeletionGuard(
            pending: localDeletions.count,
            known: max(state.fileCount, base.count),
            allowBulkDeletions: config.allowBulkDeletions
        ) {
            holdLocalDeletions = true
            summary.errors.append(
                "Refused to publish \(localDeletions.count) deletion(s) to the vault: that is more than a quarter of it. Tick “Allow bulk deletions” in Settings if the files really are gone."
            )
        }

        // MARK: execute
        var bytesTotal: Int64 = 0
        for key in batchKeys {
            if let entry = state.files[key], local[key]?.sha != entry.sha256, base[key] != entry.sha256 {
                bytesTotal += entry.size
            }
            if let item = local[key], state.files[key]?.sha256 != item.sha { bytesTotal += item.file.size }
        }

        var doneFiles = 0
        var doneBytes: Int64 = 0
        defer { progress(SyncProgress(phase: .syncing, filesTotal: batchKeys.count, filesDone: batchKeys.count, bytesTotal: bytesTotal, bytesDone: bytesTotal)) }
        summary.catchUpProcessed = batchKeys.count
        summary.catchUpPending = catchUpPending

        for key in batchKeys {
            doneFiles += 1
            progress(SyncProgress(
                phase: .syncing,
                replicaName: link.displayName,
                currentFile: state.files[key]?.path ?? local[key]?.file.relativePath ?? key,
                filesTotal: batchKeys.count,
                filesDone: doneFiles,
                bytesTotal: bytesTotal,
                bytesDone: doneBytes
            ))

            let vaultEntry = state.files[key]
            let tombstone = state.tombstones[key]
            let localItem = local[key]
            let baseSha = base[key]
            let vaultSha = vaultEntry?.sha256
            let localSha = localItem?.sha

            // Both sides have content.
            if let vaultEntry, let localItem {
                if vaultSha == localSha {
                    // Agreed on the content — but a cheap check that the share really still holds
                    // the bytes, because a file deleted or truncated on the share by hand (or by a
                    // dropped connection) would otherwise sit there wrong forever: both sides agree,
                    // so nothing would ever re-send it. This machine has the agreed content, so it
                    // is the one that can put it back.
                    if !Self.hasVaultFile(store: store, path: vaultEntry.path, size: vaultEntry.size) {
                        if Self.repairVaultFile(store: store, path: vaultEntry.path, from: localItem.file.url) {
                            summary.repairs.append(vaultEntry.path)
                        } else {
                            summary.errors.append("\(vaultEntry.path): the vault copy is missing and could not be restored")
                        }
                    } else {
                        summary.upToDate += 1
                    }
                    base[key] = localSha
                    continue
                }
                if baseSha == vaultSha {
                    // Only this machine changed it: publish.
                    if publish(
                        localItem.file, path: vaultEntry.path, sha: localItem.sha,
                        previous: vaultEntry.sha256, vaultEntry: vaultEntry,
                        store: store, link: link, machine: machine, journal: &journal, summary: &summary
                    ) { base[key] = localItem.sha }
                    doneBytes += localItem.file.size
                    continue
                }
                if baseSha == localSha {
                    // Only the vault changed it: apply.
                    if download(path: vaultEntry.path, entry: vaultEntry, store: store, link: link, summary: &summary) {
                        base[key] = vaultEntry.sha256
                    }
                    doneBytes += vaultEntry.size
                    continue
                }
                // Both changed, or this machine met the vault with a folder that already had
                // content: keep both rather than pick one and lose the other.
                resolveConflict(
                    key: key, path: vaultEntry.path, localItem: localItem, vaultEntry: vaultEntry,
                    store: store, link: link, machine: machine, state: state,
                    reserved: &reserved, journal: &journal, base: &base, summary: &summary
                )
                doneBytes += vaultEntry.size + localItem.file.size
                continue
            }

            // Deleted in the vault, still here.
            if let tombstone, let localItem {
                // Unless this machine deliberately put it back: a restore is an instruction to undo
                // the deletion everywhere, while a Mac that merely missed the delete has to respect
                // it. The marker is what tells the two apart (see `PendingUndeleteStore`).
                if pendingUndeletes[key] == localItem.sha {
                    if publish(
                        localItem.file, path: tombstone.path, sha: localItem.sha, previous: nil,
                        vaultEntry: nil, store: store, link: link, machine: machine,
                        journal: &journal, summary: &summary
                    ) {
                        base[key] = localItem.sha
                        undeletes.clear(key, linkID: link.id)
                        summary.undeleted.append(tombstone.path)
                    }
                    doneBytes += localItem.file.size
                    continue
                }
                if baseSha == localItem.sha {
                    if holdRemoteDeletions {
                        summary.upToDate += 1
                        continue
                    }
                    applyRemoteDeletion(
                        path: tombstone.path, entry: tombstone, localItem: localItem,
                        link: link, deleteStore: deleteStore, summary: &summary
                    )
                    base[key] = ""
                    continue
                }
                // This machine changed the file the others deleted. Keep the edit as a conflicted
                // copy and honour the deletion for the original name: nothing is lost either way.
                let conflicted = VaultPath.conflictedName(
                    for: tombstone.path, machineName: machine.name, at: Date(),
                    isTaken: { candidate in
                        FileManager.default.fileExists(atPath: link.localURL.appendingPathComponent(candidate).path)
                            || state.files[VaultPath.key(candidate)] != nil
                            || reserved.contains(VaultPath.key(candidate))
                    }
                )
                reserved.insert(VaultPath.key(conflicted))
                let moved = (try? moveLocal(from: localItem.file.url, to: link.localURL.appendingPathComponent(conflicted))) != nil
                if moved {
                    let conflictedFile = ScannedFile(
                        sourceID: link.id, relativePath: conflicted,
                        url: link.localURL.appendingPathComponent(conflicted),
                        size: localItem.file.size, mtime: localItem.file.mtime
                    )
                    if publish(
                        conflictedFile, path: conflicted, sha: localItem.sha, previous: nil,
                        vaultEntry: nil, store: store, link: link, machine: machine,
                        journal: &journal, summary: &summary
                    ) {
                        base[VaultPath.key(conflicted)] = localItem.sha
                    }
                    base[key] = ""
                    summary.conflicts.append(tombstone.path)
                    summary.remoteDeletionsApplied += 0
                } else {
                    summary.errors.append("\(tombstone.path): could not keep the local edit as a conflicted copy")
                }
                continue
            }

            // In the vault, not here.
            if let vaultEntry, localItem == nil {
                if baseSha == vaultSha {
                    // The file this machine had is gone locally: publish the deletion.
                    if holdLocalDeletions {
                        summary.upToDate += 1
                        continue
                    }
                    if publishDeletion(
                        path: vaultEntry.path, previous: vaultEntry.sha256, state: state,
                        store: store, link: link, machine: machine, journal: &journal, summary: &summary
                    ) {
                        base[key] = ""
                        summary.localDeletionsPublished += 1
                    }
                    continue
                }
                // Never seen here (a seed) or re-created elsewhere.
                if download(path: vaultEntry.path, entry: vaultEntry, store: store, link: link, summary: &summary) {
                    base[key] = vaultEntry.sha256
                }
                doneBytes += vaultEntry.size
                continue
            }

            // Deleted in the vault and already gone here.
            if tombstone != nil, localItem == nil {
                if baseSha != "" { base[key] = "" }
                summary.upToDate += 1
                continue
            }

            // Only here: a new local file (or one whose vault entry vanished entirely).
            if localItem != nil, vaultEntry == nil, tombstone == nil {
                let path = localItem!.file.relativePath
                if publish(
                    localItem!.file, path: path, sha: localItem!.sha, previous: nil,
                    vaultEntry: nil, store: store, link: link, machine: machine,
                    journal: &journal, summary: &summary
                ) {
                    base[key] = localItem!.sha
                }
                doneBytes += localItem!.file.size
                continue
            }
        }

        // Bytes are in place before the journal records them. A crash in between therefore leaves
        // a vault that still names the old version, which the next sync re-publishes — the failure
        // mode is a repeated change, never a lost one.
        do {
            try store.append(journal.entries, machineID: machine.id.uuidString)
        } catch {
            summary.errors.append("Could not write the journal: \(error.localizedDescription)")
        }

        // Retention housekeeping: hand back what no machine can still need, and only after the
        // window has closed.
        let now = Date()
        let keep = store.retainableVersions(from: loaded.entries, within: DeleteRecord.retention, now: now)
        summary.versionsPurged = store.purgeVersions(keeping: keep, olderThan: DeleteRecord.retention, now: now)

        if summary.errors.isEmpty {
            // A marker is only useful while the journal still calls that path deleted.
            undeletes.prune(keeping: Set(state.tombstones.keys), linkID: link.id)
        }

        // Publish the range's durable operations before committing its cursor. If appending the
        // journal fails, preserve the previous checkpoint so the range will be retried.
        // Commit merge-base and checkpoint only when all selected operations succeeded.
        // Otherwise the previous cursor stays intact and this whole batch is safely retried.
        if summary.errors.isEmpty {
            cursor.applied = base
            cursor.catchUpAfter = catchUpPending ? (page.last ?? cursorStart) : nil
            cursor.catchUpDirtyPaths = dirtyAfter.isEmpty ? nil : dirtyAfter.sorted()
            // What the journal held when this pass finished, so the next one can tell what arrived
            // while it was behind without trusting two differently-rounded timestamps.
            cursor.catchUpSeenAt = max(cursor.catchUpSeenAt ?? 0, loaded.entries.map { Self.millis($0.at) }.max() ?? 0)
            cursor.lastSync = now
            do {
                try cursorStore.save(cursor)
                var committedIndex = previousIndex
                for key in batchKeys {
                    guard let file = local[key]?.file else { continue }
                    let indexKey = "\(file.sourceID.uuidString)/\(file.relativePath)"
                    if let entry = indexed.index.entries[indexKey] { committedIndex.entries[indexKey] = entry }
                }
                try indexStore.save(committedIndex)
            } catch {
                summary.errors.append("Could not save sync progress: \(error.localizedDescription)")
            }
        }
        // What the vault holds now: the merged state, adjusted by what this run published. Taken
        // from the journal entries rather than assumed, so the menu number matches the share.
        summary.filesInVault = state.fileCount
            + journal.entries.filter { $0.kind == .create }.count
            - journal.entries.filter { $0.kind == .delete }.count
        summary.catchUpPending = catchUpPending || (!summary.errors.isEmpty && !batchKeys.isEmpty)

        // Deliberately no `pruneEmptyDirectories` here. On a replica an empty directory is
        // leftovers to tidy; the local side of a two-way folder is the folder a person works in,
        // and a folder they just made is not NeoDrop's to remove.
        summary.seeded = firstSync && summary.downloaded > 0
        return finish(&summary, phase: summary.isDegraded ? .failed(summary.errors[0]) : .finished)
    }

    // MARK: - Actions

    /// A journal timestamp as an exact integer, so comparing one against a stored watermark does
    /// not depend on how either was written to disk. The journal keeps milliseconds; this keeps
    /// them too.
    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Keep this machine's retention list honest, the same way the mirror engine does.
    ///
    /// A file that is back in the folder with the digest the record expects was restored — by the
    /// deleted-files view, or by hand — so the deletion is undone and both the record and its
    /// retained bytes go. A record whose bytes have vanished cannot restore anything, and one that
    /// points outside the trash is never acted on. Without this the trash would grow forever,
    /// because nothing else prunes a two-way link's records.
    private func reconcileLocalDeleteRecords(
        link: VaultLink,
        local: [String: (file: ScannedFile, sha: String)],
        deleteStore: DeleteStore
    ) {
        let records = deleteStore.load(replicaID: link.id)
        guard !records.isEmpty else { return }
        let fm = FileManager.default
        let trashRoot = link.localURL.appendingPathComponent(DeleteRecord.trashDirectoryName, isDirectory: true)
        var changed = false
        let kept = records.filter { record in
            let trashURL = record.trashURL(onReplicaRoot: link.localURL)
            guard MirrorEngine.isInside(trashURL, of: trashRoot) else {
                changed = true
                return false
            }
            if let back = local[VaultPath.key(record.relativePath)], !record.sha256.isEmpty, back.sha == record.sha256 {
                if fm.fileExists(atPath: trashURL.path), (try? fm.removeItem(at: trashURL)) == nil { return true }
                changed = true
                return false
            }
            if !fm.fileExists(atPath: trashURL.path) {
                changed = true
                return false
            }
            return true
        }
        if changed { try? deleteStore.save(kept, for: link.id) }
    }

    /// Copy a local file into the live tree and record it. The vendor's existing content is
    /// retained first, so an overwrite is recoverable even though the file was replaced.
    private func publish(
        _ file: ScannedFile,
        path: String,
        sha: String,
        previous: String?,
        vaultEntry: JournalEntry?,
        store: VaultStore,
        link: VaultLink,
        machine: MachineIdentity,
        journal: inout JournalWriter,
        summary: inout VaultSyncSummary
    ) -> Bool {
        let destination = store.fileURL(for: path)
        do {
            // Keep whatever is about to be overwritten. `previous` is the journalled digest; when
            // the path is not in the journal at all — bytes somebody put on the share by hand — it
            // has to be hashed, because losing those bytes with no copy anywhere is not an
            // acceptable price for a tidy journal. One hash, on the rarest of paths.
            if FileManager.default.fileExists(atPath: destination.path) {
                let existing = (previous.flatMap { $0.isEmpty ? nil : $0 }) ?? (try? Hashing.sha256(ofFileAt: destination))
                if let existing, store.retainVersion(from: destination, sha256: existing) { summary.versionsRetained += 1 }
            }
            try AtomicFile.copy(from: file.url, to: destination)
            journal.add(
                machine: machine, path: path,
                kind: vaultEntry == nil ? .create : .update,
                size: file.size, sha: sha, previous: previous
            )
            summary.uploaded += 1
            summary.bytesUp += file.size
            return true
        } catch {
            summary.errors.append("\(path): could not publish (\(error.localizedDescription))")
            return false
        }
    }

    private func publishDeletion(
        path: String,
        previous: String,
        state: VaultState,
        store: VaultStore,
        link: VaultLink,
        machine: MachineIdentity,
        journal: inout JournalWriter,
        summary: inout VaultSyncSummary
    ) -> Bool {
        let destination = store.fileURL(for: path)
        // Keep the bytes before taking the file out of the tree: after this the file is gone from
        // the share, and retained content is the only way back until the window closes.
        if FileManager.default.fileExists(atPath: destination.path) {
            if store.retainVersion(from: destination, sha256: previous) { summary.versionsRetained += 1 }
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            journal.add(machine: machine, path: path, kind: .delete, size: 0, sha: previous, previous: previous)
            return true
        } catch {
            summary.errors.append("\(path): could not remove it from the vault (\(error.localizedDescription))")
            return false
        }
    }

    /// Bring a vault file here. The vault's own copy is checked first: a file deleted from the
    /// share by hand, or left truncated by a dropped connection, is repaired from retained content
    /// rather than downloaded broken.
    private func download(
        path: String,
        entry: JournalEntry,
        store: VaultStore,
        link: VaultLink,
        summary: inout VaultSyncSummary
    ) -> Bool {
        let source = store.fileURL(for: path)
        let destination = link.localURL.appendingPathComponent(path)

        var usable = FileManager.default.fileExists(atPath: source.path)
        if usable, FileMeta.size(ofFileAt: source) != entry.size { usable = false }
        if !usable {
            // Repair the share from the vault's own retained version, if we have it.
            if store.hasVersion(sha256: entry.sha256) {
                do {
                    try AtomicFile.copy(from: store.versionURL(sha256: entry.sha256), to: source)
                    usable = true
                    summary.repairs.append(path)
                } catch {
                    summary.errors.append("\(path): the vault copy is missing and could not be restored")
                    return false
                }
            } else {
                summary.errors.append("\(path): the vault file is missing or the wrong size, and no retained copy exists")
                return false
            }
        }

        do {
            try AtomicFile.copy(from: source, to: destination)
            summary.downloaded += 1
            summary.bytesDown += entry.size
            return true
        } catch {
            summary.errors.append("\(path): could not be written locally (\(error.localizedDescription))")
            return false
        }
    }

    /// Apply a deletion another machine published: the bytes go into this machine's trash with a
    /// record, exactly like a mirrored deletion, so "Deleted Files…" can put them back.
    private func applyRemoteDeletion(
        path: String,
        entry: JournalEntry,
        localItem: (file: ScannedFile, sha: String),
        link: VaultLink,
        deleteStore: DeleteStore,
        summary: inout VaultSyncSummary
    ) {
        let fm = FileManager.default
        let record = DeleteRecord(
            relativePath: path,
            sourcePath: localItem.file.url.path,
            size: localItem.file.size,
            sha256: localItem.sha
        )
        let trashURL = record.trashURL(onReplicaRoot: link.localURL)
        guard MirrorEngine.isInside(trashURL, of: link.localURL.appendingPathComponent(DeleteRecord.trashDirectoryName, isDirectory: true)) else {
            summary.errors.append("\(path): refusing to move a file outside the trash directory")
            return
        }
        // Record before the move: a record with no bytes self-heals on the next sync, while bytes
        // with no record are unreachable forever.
        do {
            var records = deleteStore.load(replicaID: link.id)
            records.removeAll { $0.relativePath == path }
            records.append(record)
            try deleteStore.save(records, for: link.id)
        } catch {
            summary.errors.append("\(path): could not record the deletion for recovery (\(error.localizedDescription))")
            return
        }
        do {
            try fm.createDirectory(at: trashURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: trashURL.path) { try? fm.removeItem(at: trashURL) }
            try fm.moveItem(at: localItem.file.url, to: trashURL)
            summary.remoteDeletionsApplied += 1
        } catch {
            summary.errors.append("\(path): could not move it to the trash (\(error.localizedDescription))")
        }
    }

    /// Both sides changed the same path. The vault keeps the original name — so the other machines
    /// do not churn — and this machine's version is kept beside it as a conflicted copy, local and
    /// published, which is what Dropbox does and the only resolution that loses nothing.
    private func resolveConflict(
        key: String,
        path: String,
        localItem: (file: ScannedFile, sha: String),
        vaultEntry: JournalEntry,
        store: VaultStore,
        link: VaultLink,
        machine: MachineIdentity,
        state: VaultState,
        reserved: inout Set<String>,
        journal: inout JournalWriter,
        base: inout [String: String],
        summary: inout VaultSyncSummary
    ) {
        let conflicted = VaultPath.conflictedName(
            for: path, machineName: machine.name, at: Date(),
            isTaken: { candidate in
                FileManager.default.fileExists(atPath: link.localURL.appendingPathComponent(candidate).path)
                    || state.files[VaultPath.key(candidate)] != nil
                    || reserved.contains(VaultPath.key(candidate))
            }
        )
        reserved.insert(VaultPath.key(conflicted))

        // Keep the losing bytes in the vault's retained versions as well: the conflicted copy is
        // the visible one, this is the belt and braces.
        if store.retainVersion(from: localItem.file.url, sha256: localItem.sha) {
            summary.versionsRetained += 1
        }

        let destination = link.localURL.appendingPathComponent(conflicted)
        guard (try? moveLocal(from: localItem.file.url, to: destination)) != nil else {
            summary.errors.append("\(path): could not keep this machine's version as a conflicted copy")
            return
        }
        let conflictedFile = ScannedFile(
            sourceID: link.id, relativePath: conflicted, url: destination,
            size: localItem.file.size, mtime: localItem.file.mtime
        )
        if publish(
            conflictedFile, path: conflicted, sha: localItem.sha, previous: nil, vaultEntry: nil,
            store: store, link: link, machine: machine, journal: &journal, summary: &summary
        ) {
            base[VaultPath.key(conflicted)] = localItem.sha
        }
        // The original name now holds the vault's version, here as well.
        if download(path: vaultEntry.path, entry: vaultEntry, store: store, link: link, summary: &summary) {
            base[key] = vaultEntry.sha256
        }
        summary.conflicts.append(path)
    }

    private func moveLocal(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: source, to: destination)
    }

    // MARK: - Helpers

    private func finish(_ summary: inout VaultSyncSummary, phase: SyncPhase, error: Error? = nil) -> VaultSyncSummary {
        if let error { summary.errors.append(error.localizedDescription) }
        summary.phase = phase
        summary.finishedAt = Date()
        return summary
    }

    /// Is the share's copy of this path present and the size the journal says it should be?
    /// Size is enough here: this runs on every file on every sync, and hashes are verify's job.
    static func hasVaultFile(store: VaultStore, path: String, size: Int64) -> Bool {
        let url = store.fileURL(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return FileMeta.size(ofFileAt: url) == size
    }

    /// Put the agreed content back on the share. No journal entry: the journal already says this
    /// content is current, so there is nothing to announce — only bytes to restore.
    static func repairVaultFile(store: VaultStore, path: String, from local: URL) -> Bool {
        do {
            try AtomicFile.copy(from: local, to: store.fileURL(for: path))
            return true
        } catch {
            return false
        }
    }

    /// A vault or local folder must be an existing directory. Never create either: an unmounted
    /// share would make the path resolve to the boot volume, and syncing a tree onto the SSD is
    /// the worst thing this app could do.
    static func isUsableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// Refuse a vault inside the local folder or the other way round: the two trees have to be
    /// disjoint or a sync would feed its own output back to itself.
    ///
    /// Canonical, so the same folder reached as `/var/...` and as `/private/var/...` is recognised as
    /// the same folder rather than as a safe pair (`PathIdentity`).
    static func overlaps(_ left: URL, _ right: URL) -> Bool {
        PathIdentity.overlaps(left, right)
    }
}

/// Accumulates the journal lines for one reconcile, so the whole run is one append.
private struct JournalWriter {
    var seq: Int
    var entries: [JournalEntry] = []

    init(seq: Int) { self.seq = seq }

    mutating func add(
        machine: MachineIdentity,
        path: String,
        kind: JournalEntry.Kind,
        size: Int64,
        sha: String,
        previous: String?
    ) {
        entries.append(JournalEntry(
            seq: seq,
            machine: machine.id.uuidString,
            machineName: machine.name,
            path: path,
            kind: kind,
            size: size,
            sha256: sha,
            previousSha256: previous
        ))
        seq += 1
    }
}
