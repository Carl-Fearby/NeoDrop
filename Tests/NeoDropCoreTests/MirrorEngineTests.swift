import XCTest
@testable import NeoDropCore

final class MirrorEngineTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox(name: "engine", replicaCount: 2)
    }

    override func tearDown() {
        sandbox = nil
    }

    // MARK: - First mirror

    func testFirstSyncCopiesEveryFileToEveryReplica() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        try sandbox.write("beta", to: "folder/beta.txt")

        let engine = sandbox.engine()
        let summary = try unwrap(await engine.sync(config: sandbox.config()))

        XCTAssertEqual(summary.phase, .finished)
        XCTAssertEqual(summary.replicas.count, 2)
        XCTAssertEqual(summary.filesCopied, 4, "two files onto two replicas")
        XCTAssertEqual(summary.failures, 0)
        XCTAssertFalse(summary.isDegraded)
        XCTAssertEqual(summary.healthyReplicaCount, 2)

        for index in 0..<2 {
            XCTAssertEqual(try sandbox.contentsOnReplica(index, "alpha.txt"), "alpha")
            XCTAssertEqual(try sandbox.contentsOnReplica(index, "folder/beta.txt"), "beta")
        }
    }

    /// The whole point: both replicas must hold byte-identical copies.
    func testBothReplicasHoldIdenticalContent() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        try sandbox.writeRandomBytes(to: "binary/blob.bin", byteCount: 300_000)

        _ = await sandbox.engine().sync(config: sandbox.config())
        let contents = try sandbox.mirrorContents()

        XCTAssertEqual(contents["NAS1"], contents["NAS2"])
        XCTAssertEqual(contents["NAS1"]?.keys.sorted(), ["alpha.txt", "binary/blob.bin"])
    }

    func testSecondSyncCopiesNothingWhenNothingChanged() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        try sandbox.write("beta", to: "folder/beta.txt")

        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        let second = try unwrap(await engine.sync(config: sandbox.config()))

        XCTAssertEqual(second.filesCopied, 0)
        XCTAssertEqual(second.filesChanged, 0)
        XCTAssertEqual(second.replicas.reduce(0) { $0 + $1.upToDate }, 4)
    }

    func testOnlyChangedFilesAreRecopied() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        try sandbox.write("beta", to: "beta.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        try sandbox.write("alpha-changed", to: "alpha.txt")
        let second = try unwrap(await engine.sync(config: sandbox.config()))

        // One file changed, re-copied to both replicas.
        XCTAssertEqual(second.filesCopied, 2)
        for index in 0..<2 {
            XCTAssertEqual(try sandbox.contentsOnReplica(index, "alpha.txt"), "alpha-changed")
        }
    }

    func testNewFilesAreAddedIncrementally() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        try sandbox.write("new", to: "later/new.txt")
        let second = try unwrap(await engine.sync(config: sandbox.config()))

        XCTAssertEqual(second.filesCopied, 2)
        XCTAssertTrue(sandbox.fileExistsOnReplica(0, "later/new.txt"))
        XCTAssertTrue(sandbox.fileExistsOnReplica(1, "later/new.txt"))
    }

    // MARK: - Deletions

    func testDeletionsAreMirrored() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        try sandbox.write("beta", to: "beta.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        try sandbox.delete("alpha.txt")
        let second = try unwrap(await engine.sync(config: sandbox.config()))

        XCTAssertEqual(second.filesDeleted, 2)
        XCTAssertFalse(sandbox.fileExistsOnReplica(0, "alpha.txt"))
        XCTAssertFalse(sandbox.fileExistsOnReplica(1, "alpha.txt"))
        XCTAssertTrue(sandbox.fileExistsOnReplica(0, "beta.txt"))
    }

    func testDeletionsAreKeptWhenMirroringIsDisabled() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        var config = sandbox.config()
        config.mirrorDeletions = false

        let engine = sandbox.engine()
        _ = await engine.sync(config: config)
        try sandbox.delete("alpha.txt")

        let second = try unwrap(await engine.sync(config: config))
        XCTAssertEqual(second.filesDeleted, 0)
        XCTAssertTrue(sandbox.fileExistsOnReplica(0, "alpha.txt"), "an archive replica keeps the file")
    }

    /// NeoDrop must never delete files it did not write, so a replica can share a volume.
    func testForeignFilesOnReplicaAreUntouched() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()

        let foreign = sandbox.replicaURLs[0].appendingPathComponent("someone-elses-file.txt")
        try "not ours".write(to: foreign, atomically: true, encoding: .utf8)

        _ = await engine.sync(config: sandbox.config())
        try sandbox.delete("alpha.txt")
        _ = await engine.sync(config: sandbox.config())

        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertFalse(sandbox.fileExistsOnReplica(0, "alpha.txt"))
    }

    /// A mirror that already holds the source's exact bytes is NeoDrop's own copy with a lost
    /// manifest: a reset, a new Mac pointed at an existing share, a state directory restored from a
    /// backup. Adopting what is there is what makes the clean-install instructions true — the next
    /// sync recognises the files instead of uploading a whole library over the network again.
    func testAFileAlreadyOnTheShareWithTheSourcesBytesIsAdoptedInsteadOfUploaded() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        _ = try await unwrap(await sandbox.engine().sync(config: sandbox.config()))

        // A second Mac: the same folders, and no state of its own.
        let freshPaths = StorePaths(base: sandbox.root.appendingPathComponent("fresh-state"))
        try freshPaths.ensureDirectories()
        let fresh = MirrorEngine(paths: freshPaths)

        let untouched = sandbox.replicaURLs[0].appendingPathComponent("alpha.txt")
        let before = try FileMeta.modificationDate(ofFileAt: untouched)
        let summary = try await unwrap(await fresh.sync(config: sandbox.config()))

        XCTAssertEqual(summary.filesAdopted, 2, "both replicas already held the file")
        XCTAssertEqual(summary.filesCopied, 0, "nothing needed uploading")
        XCTAssertEqual(summary.filesAdopted > 0 && summary.filesCopied == 0, true)
        XCTAssertEqual(try sandbox.contentsOnReplica(0, "alpha.txt"), "alpha")
        XCTAssertEqual(try FileMeta.modificationDate(ofFileAt: untouched), before,
                       "the file on the share was not rewritten")

        // And the next sync treats it as its own: up to date, nothing copied, no exceptions.
        let second = try await unwrap(await fresh.sync(config: sandbox.config()))
        XCTAssertEqual(second.filesCopied, 0)
        XCTAssertEqual(second.replicas.map(\.foreign), [0, 0])
        XCTAssertEqual(second.replicas.map(\.upToDate), [1, 1])
    }

    /// The one operation in the engine that could destroy a file existing nowhere else: something is
    /// at a path the mirror wants, and NeoDrop has no record of ever writing it. It is left exactly
    /// as it is — byte for byte — reported, and badged; the path becomes NeoDrop's the moment the
    /// file is out of the way, which is the user's decision to make.
    func testAFileNeoDropDidNotWriteIsNeverReplaced() async throws {
        try sandbox.write("ours", to: "report.txt")
        let theirs = "somebody else's afternoon of work"
        let inTheWay = sandbox.replicaURLs[0].appendingPathComponent("report.txt")
        try theirs.write(to: inTheWay, atomically: true, encoding: .utf8)

        let engine = sandbox.engine()
        let first = try await unwrap(await engine.sync(config: sandbox.config()))

        XCTAssertEqual(try sandbox.contentsOnReplica(0, "report.txt"), theirs,
                       "another file at the same path is not NeoDrop's to replace")
        XCTAssertEqual(first.replicas[0].foreign, 1)
        XCTAssertEqual(first.replicas[1].copied, 1, "the other replica still mirrors the source")
        XCTAssertTrue(first.replicas[0].errors.contains { $0.contains("report.txt") },
                      "and the run says which file it left alone")
        XCTAssertTrue(first.filesCopied > 0 || first.filesAdopted > 0)

        let manifest = ManifestStore(paths: sandbox.storePaths).load(replicaID: sandbox.replicaModels[0].id)
        XCTAssertEqual(manifest.foreignPaths, ["report.txt"], "recorded, so the badge can name it")
        XCTAssertNil(manifest.entries["report.txt"], "and not claimed as NeoDrop's")

        // Another sync does not change its mind about somebody else's file.
        let second = try await unwrap(await engine.sync(config: sandbox.config()))
        XCTAssertEqual(try sandbox.contentsOnReplica(0, "report.txt"), theirs)
        XCTAssertEqual(second.replicas[0].foreign, 1)

        // Once it is gone, the mirror takes the path — and forgets the exception.
        try FileManager.default.removeItem(at: inTheWay)
        _ = try await unwrap(await engine.sync(config: sandbox.config()))
        XCTAssertEqual(try sandbox.contentsOnReplica(0, "report.txt"), "ours")
        XCTAssertEqual(ManifestStore(paths: sandbox.storePaths)
            .load(replicaID: sandbox.replicaModels[0].id).foreignPaths, [])
    }

    /// Manifests gain keys as the engine grows, and `ManifestStore.load` cannot tell an older file
    /// from a damaged one: both come back empty, which on a share means uploading everything again.
    /// A manifest written before `foreignPaths` existed therefore has to load with its entries intact.
    func testAManifestFromAnOlderBuildKeepsItsEntries() throws {
        let replica = sandbox.replicaModels[0]
        let json = """
        {
          "replicaID": "\(replica.id.uuidString)",
          "entries": { "alpha.txt": { "size": 5, "mtime": "2026-01-01T00:00:00Z", "sha256": "abc",
                                     "writtenAt": "2026-01-01T00:00:00Z" } },
          "lastSync": "2026-01-01T00:00:00Z",
          "corruptPaths": ["beta.txt"]
        }
        """
        let url = sandbox.storePaths.manifestURL(for: replica.id)
        try Data(json.utf8).write(to: url)

        let loaded = ManifestStore(paths: sandbox.storePaths).load(replicaID: replica.id)
        XCTAssertEqual(loaded.entries.count, 1, "the entries survived the missing key")
        XCTAssertEqual(loaded.entries["alpha.txt"]?.sha256, "abc")
        XCTAssertEqual(loaded.corruptPaths, ["beta.txt"])
        XCTAssertEqual(loaded.foreignPaths, [], "and the new key is simply empty")
    }

    /// The guard that matters most: a source that has been renamed, unplugged or re-pointed must
    /// not cause the mirror to be emptied.
    func testBulkDeletionIsRefusedByDefault() async throws {
        for index in 0..<40 { try sandbox.write("payload \(index)", to: "file-\(index).txt") }
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        // The whole source is gone now, as if the wrong folder were picked.
        for index in 0..<40 { try sandbox.delete("file-\(index).txt") }

        let summary = try unwrap(await engine.sync(config: sandbox.config()))
        XCTAssertEqual(summary.filesDeleted, 0, "removing 40 of 40 mirrored files must be refused")
        XCTAssertTrue(summary.isDegraded, "the refusal has to be visible, not silent")
        XCTAssertTrue(summary.replicas.allSatisfy { report in
            report.errors.contains { $0.contains("Refused to remove") }
        })
        for index in 0..<40 {
            XCTAssertTrue(sandbox.fileExistsOnReplica(1, "file-\(index).txt"), "the NAS must still hold file-\(index).txt")
        }
    }

    func testBulkDeletionProceedsWhenExplicitlyAllowed() async throws {
        for index in 0..<40 { try sandbox.write("payload \(index)", to: "file-\(index).txt") }
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        for index in 0..<40 { try sandbox.delete("file-\(index).txt") }

        var config = sandbox.config()
        config.allowBulkDeletions = true
        let summary = try unwrap(await engine.sync(config: config))

        XCTAssertEqual(summary.filesDeleted, 80)
        XCTAssertFalse(summary.isDegraded)
        XCTAssertEqual(try sandbox.mirrorContents().values.map(\.count), [0, 0])
    }

    /// A source that cannot be read at all (unmounted, deleted, permissions) must freeze
    /// deletions rather than interpret "nothing found" as "everything was deleted".
    func testUnreadableSourceBlocksDeletions() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        try sandbox.write("beta", to: "beta.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        // The source vanishes, e.g. an external volume was unplugged.
        try FileManager.default.moveItem(at: sandbox.source, to: sandbox.root.appendingPathComponent("Source-Away"))
        defer { try? FileManager.default.moveItem(
            at: sandbox.root.appendingPathComponent("Source-Away"), to: sandbox.source
        ) }

        let summary = try unwrap(await engine.sync(config: sandbox.config()))
        XCTAssertEqual(summary.filesDeleted, 0)
        XCTAssertTrue(sandbox.fileExistsOnReplica(0, "alpha.txt"))
        XCTAssertTrue(sandbox.fileExistsOnReplica(1, "beta.txt"))
        XCTAssertTrue(summary.replicas.allSatisfy { report in
            report.errors.contains { $0.contains("Deletions skipped") }
        })
    }

    /// An empty source is legitimate: the user really did delete everything.
    func testEmptySourceStillMirrorsTheEmptiness() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        try sandbox.delete("alpha.txt")

        let summary = try unwrap(await engine.sync(config: sandbox.config()))
        XCTAssertEqual(summary.filesDeleted, 2)
        XCTAssertFalse(sandbox.fileExistsOnReplica(0, "alpha.txt"))
        XCTAssertFalse(summary.isDegraded)
    }

    func testEmptiedDirectoriesArePruned() async throws {
        try sandbox.write("deep", to: "a/b/c/deep.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        try sandbox.delete("a/b/c/deep.txt")

        _ = await engine.sync(config: sandbox.config())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sandbox.replicaURLs[0].appendingPathComponent("a/b/c").path
        ), "the emptied leaf directory should be cleaned up")
    }

    // MARK: - Verification

    func testVerifyReportsHealthyReplicas() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        let verified = try unwrap(await engine.verify(config: sandbox.config(), repair: false))
        XCTAssertEqual(verified.replicas.count, 2)
        for report in verified.replicas {
            XCTAssertEqual(report.status, .online)
            XCTAssertEqual(report.corrupt, 0)
            XCTAssertEqual(report.upToDate, 1)
        }
    }

    func testVerifyDetectsSilentCorruption() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        // Same length, different bytes: a size check alone would call this healthy.
        try sandbox.corruptOnReplica(0, "alpha.txt", with: "omega")

        let verified = try unwrap(await engine.verify(config: sandbox.config(), repair: false))
        let bad = try XCTUnwrap(verified.replicas.first { $0.id == sandbox.replicas()[0].id })
        XCTAssertEqual(bad.corrupt, 1)
        XCTAssertEqual(bad.status, .degraded)
        XCTAssertFalse(verified.isDegraded == false, "a corrupt replica must degrade the summary")
    }

    func testVerifyDetectsTruncation() async throws {
        try sandbox.write("long contents here", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        try sandbox.corruptOnReplica(1, "alpha.txt", with: "long")

        let verified = try unwrap(await engine.verify(config: sandbox.config(), repair: false))
        let bad = try XCTUnwrap(verified.replicas.first { $0.id == sandbox.replicas()[1].id })
        XCTAssertEqual(bad.corrupt, 1)
    }

    func testVerifyDetectsMissingFile() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        try FileManager.default.removeItem(at: sandbox.replicaURLs[0].appendingPathComponent("alpha.txt"))

        let verified = try unwrap(await engine.verify(config: sandbox.config(), repair: false))
        XCTAssertEqual(verified.replicas.first { $0.id == sandbox.replicas()[0].id }?.corrupt, 1)
    }

    // MARK: - Repair

    func testRepairRestoresCorruptFileFromSource() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        try sandbox.corruptOnReplica(0, "alpha.txt", with: "omega")

        let repaired = try unwrap(await engine.verify(config: sandbox.config(), repair: true))
        let report = try XCTUnwrap(repaired.replicas.first { $0.id == sandbox.replicas()[0].id })

        XCTAssertEqual(report.repaired, 1)
        XCTAssertEqual(report.corrupt, 0, "nothing should still be wrong after a successful repair")
        XCTAssertEqual(report.status, .online)
        XCTAssertEqual(try sandbox.contentsOnReplica(0, "alpha.txt"), "alpha")
        XCTAssertEqual(try sandbox.mirrorContents()["NAS1"], try sandbox.mirrorContents()["NAS2"])
    }

    /// The interesting case: the source is gone, so the only good copy is the other NAS.
    func testRepairFallsBackToAnotherReplicaWhenSourceIsGone() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        var config = sandbox.config()
        config.mirrorDeletions = false  // keep the manifest entry around

        try sandbox.delete("alpha.txt")
        try sandbox.corruptOnReplica(0, "alpha.txt", with: "omega")

        let repaired = try unwrap(await engine.verify(config: config, repair: true))
        let report = try XCTUnwrap(repaired.replicas.first { $0.id == sandbox.replicas()[0].id })

        XCTAssertEqual(report.repaired, 1)
        XCTAssertEqual(try sandbox.contentsOnReplica(0, "alpha.txt"), "alpha", "rebuilt from the healthy replica")
    }

    func testRepairCannotSucceedWhenEveryCopyIsBad() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        try sandbox.delete("alpha.txt")
        try sandbox.corruptOnReplica(0, "alpha.txt", with: "omega")
        try sandbox.corruptOnReplica(1, "alpha.txt", with: "omega")

        let repaired = try unwrap(await engine.verify(config: sandbox.config(), repair: true))
        XCTAssertTrue(repaired.replicas.allSatisfy { $0.failed == 1 })
        XCTAssertTrue(repaired.isDegraded)
        XCTAssertTrue(repaired.replicas.contains { report in
            report.errors.contains { $0.contains("no healthy copy") }
        })
    }

    func testVerifyRestoresAWholeWipedReplica() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        try sandbox.write("beta", to: "nested/beta.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        // Simulate a NAS that was reformatted: contents gone, manifests still know what was there.
        for url in try FileManager.default.contentsOfDirectory(at: sandbox.replicaURLs[0], includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }

        let repaired = try unwrap(await engine.verify(config: sandbox.config(), repair: true))
        let report = try XCTUnwrap(repaired.replicas.first { $0.id == sandbox.replicas()[0].id })
        XCTAssertEqual(report.repaired, 2)
        XCTAssertEqual(try sandbox.mirrorContents()["NAS1"], try sandbox.mirrorContents()["NAS2"])
    }

    // MARK: - Offline replicas

    func testOfflineReplicaIsReportedNotFatal() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        var config = sandbox.config()

        // Point the second replica at a path that does not exist, as if the share were unmounted.
        config.replicas[1].path = "/Volumes/neodrop-not-mounted-\(UUID().uuidString)/NeoDrop"

        let summary = try unwrap(await sandbox.engine().sync(config: config))
        let offline = try XCTUnwrap(summary.replicas.first { $0.id == config.replicas[1].id })
        let online = try XCTUnwrap(summary.replicas.first { $0.id == config.replicas[0].id })

        XCTAssertEqual(offline.status, .offline)
        XCTAssertEqual(offline.failed, 1)
        XCTAssertTrue(offline.errors.contains { $0.contains("not available") })
        XCTAssertEqual(online.status, .online)
        XCTAssertEqual(summary.healthyReplicaCount, 1)
        XCTAssertTrue(summary.isDegraded, "one replica down means reduced protection")
    }

    /// An unmounted share must never be created, because the same path on the boot volume would
    /// silently become the destination and quietly waste the real copy.
    func testEngineNeverCreatesAMissingReplicaRoot() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        var config = sandbox.config()
        let ghost = sandbox.root.appendingPathComponent("NotMounted/NeoDrop")
        config.replicas = [Replica(name: "Ghost", path: ghost.path)]

        let summary = try unwrap(await sandbox.engine().sync(config: config))
        XCTAssertEqual(summary.replicas.first?.status, .offline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghost.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghost.deletingLastPathComponent().path))
    }

    func testOneOfflineReplicaDoesNotBlockTheHealthyOne() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        var config = sandbox.config()
        config.replicas[1].path = "/Volumes/neodrop-missing-\(UUID().uuidString)"
        config.replicas[1].enabled = false

        let summary = try unwrap(await sandbox.engine().sync(config: config))
        XCTAssertEqual(summary.replicas.count, 1, "disabled replicas are skipped entirely")
        XCTAssertFalse(summary.isDegraded)
        XCTAssertEqual(try sandbox.contentsOnReplica(0, "alpha.txt"), "alpha")
    }

    // MARK: - Multiple sources

    func testMultipleSourcesAreNamespacedOnReplicas() async throws {
        let second = sandbox.root.appendingPathComponent("SourceTwo")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try "second".write(to: second.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try sandbox.write("first", to: "notes.txt")

        var config = sandbox.config()
        config.sources.append(SourceRoot(name: "SourceTwo", path: sandbox.root.appendingPathComponent("SourceTwo").path))

        let summary = try unwrap(await sandbox.engine().sync(config: config))
        XCTAssertEqual(summary.filesCopied, 4)
        XCTAssertEqual(try sandbox.contentsOnReplica(0, "Source/notes.txt"), "first")
        XCTAssertEqual(try sandbox.contentsOnReplica(0, "SourceTwo/notes.txt"), "second")
    }

    // MARK: - Progress and inspection

    func testProgressIsReported() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        try sandbox.write("beta", to: "beta.txt")

        let counter = ProgressCounter()
        _ = await sandbox.engine().sync(config: sandbox.config()) { progress in
            counter.record(progress)
        }

        let phases = counter.phases
        XCTAssertTrue(phases.contains(.scanning), "scanning should be announced: \(phases)")
        XCTAssertTrue(phases.contains(.syncing) || phases.contains(.finished))
    }

    func testInspectReportsStatusWithoutSyncing() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        let snapshots = await engine.inspect(config: sandbox.config())
        XCTAssertEqual(snapshots.count, 2)
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.files, 1)
            XCTAssertEqual(snapshot.bytes, 5)
        }

        // With the share gone the snapshot must say so rather than claiming health.
        var config = sandbox.config()
        config.replicas[0].path = "/Volumes/neodrop-gone-\(UUID().uuidString)"
        let offline = await engine.inspect(config: config)
        XCTAssertEqual(offline.first { $0.id == config.replicas[0].id }?.status, .offline)
    }

    func testSourceStatsCountFilesAndFlagMissingSources() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        try sandbox.write("beta", to: "nested/beta.txt")
        var config = sandbox.config()
        config.sources.append(SourceRoot(name: "Gone", path: "/tmp/neodrop-nope-\(UUID().uuidString)"))

        let stats = await sandbox.engine().sourceStats(config: config)
        XCTAssertEqual(stats.fileCount, 2)
        XCTAssertEqual(stats.missingSources, ["Gone"])
    }

    func testExcludesAreHonouredDuringSync() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        try sandbox.write("junk", to: ".DS_Store")

        let summary = try unwrap(await sandbox.engine().sync(config: sandbox.config()))
        XCTAssertEqual(summary.filesCopied, 2)
        XCTAssertFalse(sandbox.fileExistsOnReplica(0, ".DS_Store"))
    }

    /// Overlapping syncs must never duplicate work: one of them may be refused outright, and a
    /// second that does run must find everything already current.
    func testOverlappingSyncsNeverDuplicateWork() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        let config = sandbox.config()

        async let first = engine.sync(config: config)
        async let second = engine.sync(config: config)
        let results = await [first, second]

        let completed = results.compactMap { $0 }
        XCTAssertFalse(completed.isEmpty, "at least one sync must complete")
        XCTAssertEqual(completed.reduce(0) { $0 + $1.filesCopied }, 2, "one file onto two replicas, exactly once")
        XCTAssertEqual(try sandbox.mirrorContents()["NAS1"], try sandbox.mirrorContents()["NAS2"])
    }

    /// A replica path that exists but is a plain file (a stale mount point, a half-created share)
    /// must be treated as unavailable rather than written into.
    func testReplicaPathThatIsAFileIsOffline() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let collision = sandbox.root.appendingPathComponent("NotADirectory")
        try "i am a file".write(to: collision, atomically: true, encoding: .utf8)

        var config = sandbox.config()
        config.replicas = [Replica(name: "Collision", path: collision.path)]

        let summary = try unwrap(await sandbox.engine().sync(config: config))
        XCTAssertEqual(summary.replicas.first?.status, .offline)
        XCTAssertEqual(try String(contentsOf: collision, encoding: .utf8), "i am a file", "the file must be left alone")
    }

    func testEmptySourceCopiesNothingButStaysHealthy() async throws {
        let summary = try unwrap(await sandbox.engine().sync(config: sandbox.config()))
        XCTAssertEqual(summary.filesCopied, 0)
        XCTAssertEqual(summary.replicas.count, 2)
        XCTAssertEqual(summary.replicas.first?.status, .online)
    }

    func testLargeBinaryFilesSurviveTheRoundTrip() async throws {
        let digest = try sandbox.writeRandomBytes(to: "big/random.bin", byteCount: 2_500_000)
        _ = await sandbox.engine().sync(config: sandbox.config())

        for index in 0..<2 {
            XCTAssertEqual(try Hashing.sha256(ofFileAt: sandbox.replicaURLs[index].appendingPathComponent("big/random.bin")), digest)
        }
    }

    func testUnicodeAndAwkwardFileNames() async throws {
        try sandbox.write("unicode", to: "café/naïve — file (1).txt")
        try sandbox.write("spaces", to: "dir with spaces/file's name.txt")
        try sandbox.write("emoji", to: "📁/🗂️.txt")

        _ = await sandbox.engine().sync(config: sandbox.config())

        for relativePath in ["café/naïve — file (1).txt", "dir with spaces/file's name.txt", "📁/🗂️.txt"] {
            XCTAssertTrue(sandbox.fileExistsOnReplica(0, relativePath), "missing \(relativePath)")
            XCTAssertTrue(sandbox.fileExistsOnReplica(1, relativePath), "missing \(relativePath)")
        }
    }

    func testDisablingAReplicaStopsWritingToIt() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        var config = sandbox.config()
        config.replicas[1].enabled = false

        _ = await sandbox.engine().sync(config: config)
        XCTAssertTrue(sandbox.fileExistsOnReplica(0, "alpha.txt"))
        XCTAssertFalse(sandbox.fileExistsOnReplica(1, "alpha.txt"))
    }

    func testReEnablingAReplicaBackfillsIt() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        var config = sandbox.config()
        config.replicas[1].enabled = false
        _ = await sandbox.engine().sync(config: config)

        config.replicas[1].enabled = true
        let summary = try unwrap(await sandbox.engine().sync(config: config))
        XCTAssertEqual(summary.replicas.count, 2)
        XCTAssertTrue(sandbox.fileExistsOnReplica(1, "alpha.txt"), "a re-enabled NAS is rebuilt from the source")
    }

    func testManifestSurvivesReloadingTheEngine() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        _ = await sandbox.engine().sync(config: sandbox.config())

        // A brand-new engine with the same store paths must know the replicas are already current.
        let second = try unwrap(await sandbox.engine().sync(config: sandbox.config()))
        XCTAssertEqual(second.filesCopied, 0)
    }
}

/// Collects progress updates from a @Sendable closure.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SyncPhase] = []

    func record(_ progress: SyncProgress) {
        lock.lock()
        recorded.append(progress.phase)
        lock.unlock()
    }

    var phases: [SyncPhase] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
