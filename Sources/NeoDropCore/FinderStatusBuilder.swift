import Foundation
import NeoDropShared

extension FinderStatusIndex {
    /// Build the index the Finder extension reads, from what NeoDrop already knows.
    ///
    /// This is written where the engine's own records are: the source index, the per-destination
    /// manifests, the deletion records and the vault journals. Nothing is hashed and no tree is
    /// walked — the only file system calls are one `stat` per protected file (to notice an edit the
    /// sync has not published yet) and one per vault path. That is what keeps a green tick honest as
    /// soon as a file changes rather than after the next sync.
    ///
    /// The result holds *exceptions*: a path is only in it when its badge is not the default, so a
    /// healthy library produces a file with an empty dictionary in it, whatever its size.
    public static func build(
        config: AppConfig,
        paths: StorePaths,
        progress: SyncProgress? = nil,
        now: Date = Date()
    ) -> FinderStatusIndex {
        var index = FinderStatusIndex(
            generatedAt: now,
            machineName: MachineIdentityStore(paths: paths).loadOrCreate().name
        )

        let sourceIndex = SourceIndexStore(paths: paths).load()
        let manifests = Dictionary(
            uniqueKeysWithValues: config.replicas.map { ($0.id, ManifestStore(paths: paths).load(replicaID: $0.id)) }
        )
        let enabledReplicas = config.enabledReplicas
        let sourceCount = config.sources.count

        for source in config.sources {
            index.roots.append(FinderRoot(path: source.path, name: source.displayName, kind: .source))
        }
        for link in config.vaults {
            index.roots.append(FinderRoot(path: link.localPath, name: link.displayName, kind: .vaultLocal))
            index.roots.append(FinderRoot(path: link.vaultPath,
                                          name: "\(link.displayName) (share)",
                                          kind: .destination))
        }
        for replica in config.replicas {
            index.roots.append(FinderRoot(path: replica.path, name: replica.displayName, kind: .destination))
        }

        let byID = Dictionary(uniqueKeysWithValues: config.sources.map { ($0.id, $0) })

        // MARK: - Protected local files

        for (key, entry) in sourceIndex.entries {
            // Keyed "sourceID/relativePath"; the id is a UUID so its hyphens make the split safe.
            guard let separator = key.firstIndex(of: "/") else { continue }
            let sourceID = String(key[key.startIndex..<separator])
            let relativePath = String(key[key.index(after: separator)...])
            guard let uuid = UUID(uuidString: sourceID), let source = byID[uuid], !relativePath.isEmpty else { continue }

            let localURL = source.url.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }

            let namespaced = Scanner.namespaced(relativePath: relativePath, source: source, sourceCount: sourceCount)

            // An edit that no sync has published yet: the record still describes the previous bytes.
            let size = FileMeta.size(ofFileAt: localURL)
            let mtime = FileMeta.modificationDate(ofFileAt: localURL)
            if size != entry.size || !Self.sameInstant(mtime, entry.mtime) {
                index.merge(.waiting, forPath: localURL.path)
                continue
            }

            for replica in enabledReplicas {
                guard let manifest = manifests[replica.id] else { continue }
                let destination = replica.url.appendingPathComponent(namespaced)
                if manifest.corruptPaths.contains(namespaced) {
                    index.merge(.attention, forPath: localURL.path)
                } else if let written = manifest.entries[namespaced] {
                    if written.sha256 != entry.sha256 {
                        // The destination holds different bytes: either this machine has not
                        // published the edit or the destination's copy was replaced. Either way the
                        // badge should not claim agreement.
                        index.merge(.waiting, forPath: localURL.path)
                    } else if !FileManager.default.fileExists(atPath: destination.path) {
                        index.merge(.attention, forPath: localURL.path)
                    }
                } else {
                    // Never copied there: a new file, a destination that was offline, or a
                    // destination that was added after the last sync.
                    index.merge(.waiting, forPath: localURL.path)
                }
            }
        }

        // MARK: - Destinations

        for replica in config.replicas {
            let manifest = manifests[replica.id] ?? Manifest(replicaID: replica.id)
            for corrupt in manifest.corruptPaths {
                index.merge(.attention, forPath: replica.url.appendingPathComponent(corrupt).path)
            }
            // Something sitting where the mirror wants a file, which NeoDrop will not replace. This
            // is the last word on it — the file is not tracked, so nothing else in the index has an
            // opinion about it, and a question mark is exactly what it deserves.
            for foreign in manifest.foreignPaths {
                index.merge(.foreign, forPath: replica.url.appendingPathComponent(foreign).path)
            }

            // One entry per destination, not per retained file: an exception may name a directory and
            // then covers everything below it, which is what keeps a long trash list out of the file.
            let records = DeleteStore(paths: paths).load(replicaID: replica.id)
            if !records.isEmpty {
                index.merge(.held, forPath: replica.url
                    .appendingPathComponent(DeleteRecord.trashDirectoryName, isDirectory: true).path)
            }
        }

        // MARK: - Two-way folders

        for link in config.vaults {
            let store = VaultStore(root: link.vaultURL)
            let state = store.state(from: store.loadEntries().entries)
            let localRoot = link.localURL
            for (_, entry) in state.files {
                let localURL = localRoot.appendingPathComponent(entry.path)
                guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
                // A two-way folder has no manifest: the vault's journal is the record, and an edit is
                // one whose size no longer matches it. A same-size edit is invisible here, exactly as
                // it is in the file-status report — the reconcile is what publishes it either way.
                if FileMeta.size(ofFileAt: localURL) != entry.size {
                    index.merge(.waiting, forPath: localURL.path)
                }
                if !FileManager.default.fileExists(atPath: store.fileURL(for: entry.path).path) {
                    // The share's copy is gone: the next reconcile puts it back, but until then this
                    // Mac is the only place the file exists.
                    index.merge(.attention, forPath: localURL.path)
                }
            }
        }

        // MARK: - What is being worked on right now

        if let progress, let current = progress.currentFile, !current.isEmpty {
            // The engine reports the path it is working on, relative to whatever root it is working
            // in, so it is matched against every root rather than assumed to be a source.
            for root in index.roots {
                let candidate = URL(fileURLWithPath: root.path).appendingPathComponent(current).path
                if FileManager.default.fileExists(atPath: candidate) {
                    index.merge(.working, forPath: candidate)
                }
            }
        }

        return index
    }

    /// Write it where the extension looks.
    public func write(to paths: StorePaths) throws {
        try paths.ensureDirectories()
        try save(to: paths.finderStatusURL)
    }

    public static func load(from paths: StorePaths) -> FinderStatusIndex? {
        FinderStatusIndex.load(from: paths.finderStatusURL)
    }

    /// The stored record loses sub-second precision on its way through JSON (the shared encoder
    /// writes whole seconds) while the file system keeps it, so a strict comparison would report every
    /// file this machine wrote as edited — and "waiting to sync" on a file that is in sync is the one
    /// badge that must never lie.
    private static func sameInstant(_ left: Date?, _ right: Date) -> Bool {
        guard let left else { return false }
        return abs(left.timeIntervalSince(right)) < 1
    }
}
