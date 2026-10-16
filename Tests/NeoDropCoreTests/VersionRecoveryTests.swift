import XCTest
@testable import NeoDropCore

/// A mirror replaces what it wrote whenever the source changes: an edit, a rename onto the same
/// path, an export that overwrites. With no version control behind it that version would afterwards
/// exist nowhere, so the sync keeps the bytes it is about to write over — the same retention a
/// deletion gets, the same page to get them back, and the same rule that nothing is ever lost
/// silently.
final class VersionRecoveryTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox(name: "versions", replicaCount: 2)
    }

    override func tearDown() {
        sandbox = nil
    }

    /// Edit the source file and sync it, the way an ordinary edit reaches the mirror.
    @discardableResult
    private func edit(_ contents: String, to engine: MirrorEngine, at relativePath: String = "notes.txt") async throws -> SyncSummary {
        try sandbox.write(contents, to: relativePath)
        return try unwrap(await engine.sync(config: sandbox.config()))
    }

    /// Mirror one version first: every test here needs a file NeoDrop wrote before it replaces it.
    private func syncFirstDraft(_ engine: MirrorEngine, relativePath: String = "notes.txt") async throws {
        try sandbox.write("first draft", to: relativePath)
        _ = await engine.sync(config: sandbox.config())
    }

    // MARK: - Keeping the version that a copy replaces

    func testAnEditedFileKeepsItsPreviousVersionOnEveryDestination() async throws {
        let engine = sandbox.engine()
        try await syncFirstDraft(engine)
        let first = try sandbox.sourceDigest("notes.txt")

        let summary = try await edit("second draft", to: engine)

        XCTAssertEqual(summary.filesCopied, 2, "both destinations take the new bytes")
        XCTAssertEqual(summary.versionsKept, 2, "and both keep what they replaced")
        for index in 0..<2 {
            XCTAssertEqual(try sandbox.contentsOnReplica(index, "notes.txt"), "second draft")
            XCTAssertEqual(try sandbox.trashContents(index, "notes.txt"), "first draft",
                           "the replaced version is retained, not destroyed")
            let record = try XCTUnwrap(sandbox.record(index, "notes.txt"))
            XCTAssertEqual(record.reason, .replaced)
            XCTAssertEqual(record.sha256, first, "the record verifies the previous version")
            XCTAssertEqual(record.size, 11)
            XCTAssertEqual(record.sourcePath, sandbox.sourceFile("notes.txt").path)
            XCTAssertFalse(record.isExpired)
        }

        let entries = await engine.listDeletions(config: sandbox.config())
        XCTAssertEqual(entries.count, 1, "the previous version is offered for recovery")
        XCTAssertEqual(entries[0].reason, .replaced)
        XCTAssertEqual(entries[0].sha256, first)
        XCTAssertTrue(entries[0].restorable)
        XCTAssertEqual(entries[0].copies.map(\.replicaName), ["NAS1", "NAS2"])
    }

    func testRestoringAPreviousVersionPutsTheOlderBytesBack() async throws {
        let engine = sandbox.engine()
        try await syncFirstDraft(engine)
        try await edit("second draft", to: engine)
        let second = try sandbox.sourceDigest("notes.txt")

        let destination = try await engine.restore(relativePath: "notes.txt", config: sandbox.config())
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "first draft",
                       "the earlier version is back in the source folder")

        // The next sync publishes it. What it replaces this time is the newer version, which is the
        // symmetry that makes the whole thing safe: whichever version is not in the source is in a
        // trash directory, never nowhere.
        _ = await engine.sync(config: sandbox.config())
        for index in 0..<2 {
            XCTAssertEqual(try sandbox.contentsOnReplica(index, "notes.txt"), "first draft")
            XCTAssertEqual(try sandbox.trashContents(index, "notes.txt"), "second draft")
            XCTAssertEqual(sandbox.record(index, "notes.txt")?.sha256, second)
            XCTAssertEqual(sandbox.record(index, "notes.txt")?.reason, .replaced)
        }
    }

    func testOnlyTheNewestPreviousVersionIsKept() async throws {
        let engine = sandbox.engine()
        try sandbox.write("v1", to: "notes.txt")
        _ = await engine.sync(config: sandbox.config())
        try await edit("v2", to: engine)
        try await edit("v3", to: engine)

        XCTAssertEqual(try sandbox.contentsOnReplica(0, "notes.txt"), "v3")
        XCTAssertEqual(try sandbox.trashContents(0, "notes.txt"), "v2", "the version replaced last")
        XCTAssertEqual(sandbox.records(0).filter { $0.relativePath == "notes.txt" }.count, 1,
                       "one retained version per path, not a growing history")
    }

    // MARK: - What a restore refuses to do

    func testRestoringIsRefusedWhenTheNewerVersionHasNotReachedAShare() async throws {
        let engine = sandbox.engine()
        try await syncFirstDraft(engine)
        try await edit("second draft", to: engine)
        // An edit no sync has published yet: the newest work, and it exists on this Mac alone.
        try sandbox.write("third draft, unpublished", to: "notes.txt")

        do {
            _ = try await engine.restore(relativePath: "notes.txt", config: sandbox.config())
            XCTFail("restoring would have thrown away the only copy of the newest edit")
        } catch let error as NeoDropError {
            guard case .restoreWouldLoseNewerWork = error else {
                return XCTFail("expected the unsynced newer version to be named, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: sandbox.sourceFile("notes.txt"), encoding: .utf8),
                       "third draft, unpublished", "the newest edit is untouched")
        XCTAssertEqual(try sandbox.trashContents(0, "notes.txt"), "first draft",
                       "and the version being restored is still retained, so this can be retried")
        XCTAssertNotNil(sandbox.record(0, "notes.txt"))
    }

    func testRestoringIsRefusedWhileEveryShareIsUnmounted() async throws {
        let engine = sandbox.engine()
        try await syncFirstDraft(engine)
        try await edit("second draft", to: engine)

        // Both shares go away. Nothing can be read from them, so nothing can be said to be safe.
        for index in 0..<2 {
            try FileManager.default.moveItem(at: sandbox.root.appendingPathComponent("NAS\(index + 1)"),
                                            to: sandbox.root.appendingPathComponent("NAS\(index + 1)-away"))
        }
        defer {
            for index in 0..<2 {
                try? FileManager.default.moveItem(at: sandbox.root.appendingPathComponent("NAS\(index + 1)-away"),
                                                  to: sandbox.root.appendingPathComponent("NAS\(index + 1)"))
            }
        }

        do {
            _ = try await engine.restore(relativePath: "notes.txt", config: sandbox.config())
            XCTFail("no copy could be verified, so nothing may be written")
        } catch is NeoDropError {
            // The refusal is the point; which of the two errors it is depends on the order the
            // destinations are tried, and both mean the file was left alone.
        }

        XCTAssertEqual(try String(contentsOf: sandbox.sourceFile("notes.txt"), encoding: .utf8),
                       "second draft", "the file that is there is not written over")
    }

    // MARK: - A file changed on the share is somebody's work, not a version to bury

    func testASameSizeEditOnTheShareIsNotReplaced() async throws {
        let engine = sandbox.engine()
        try await syncFirstDraft(engine)
        // Same size as what NeoDrop recorded, edited straight on NAS1 — the case the cheap size
        // check cannot see, and the one where overwriting would destroy an edit made on the share.
        try sandbox.corruptOnReplica(0, "notes.txt", with: "FIRST DRAFT")

        let summary = try await edit("second draft", to: engine)

        XCTAssertEqual(try sandbox.contentsOnReplica(0, "notes.txt"), "FIRST DRAFT",
                       "the share's file is left exactly as it is")
        XCTAssertFalse(sandbox.trashExists(0, "notes.txt"), "and nothing about it is recorded")
        XCTAssertNil(sandbox.record(0, "notes.txt"))
        XCTAssertEqual(try sandbox.contentsOnReplica(1, "notes.txt"), "second draft",
                       "the other destination mirrors the edit as usual")
        XCTAssertEqual(summary.failures, 1, "the refusal is reported, not silent")
        XCTAssertTrue(
            summary.replicas[0].errors.contains { $0.contains("is not the version NeoDrop wrote") },
            "the report says why that copy was left alone: \(summary.replicas[0].errors)"
        )
    }

    /// Verify & Repair is explicit permission to repair a bad copy, but it must not quietly destroy
    /// the bytes that were there. They may be a hand edit on the share; retaining their digest and
    /// content before repair keeps that edit recoverable too.
    func testVerifyRepairRetainsShareEditedBytesBeforeRepair() async throws {
        let engine = sandbox.engine()
        try await syncFirstDraft(engine)
        try sandbox.corruptOnReplica(0, "notes.txt", with: "hand edit on share")
        let editedDigest = try Hashing.sha256(ofFileAt: sandbox.replicaURLs[0].appendingPathComponent("notes.txt"))

        let summary = try unwrap(await engine.verify(config: sandbox.config(), repair: true))

        XCTAssertEqual(try sandbox.contentsOnReplica(0, "notes.txt"), "first draft",
                       "repair restores the source-authored version")
        XCTAssertEqual(try sandbox.trashContents(0, "notes.txt"), "hand edit on share",
                       "but the unknown bytes on the share are kept first")
        let record = try XCTUnwrap(sandbox.record(0, "notes.txt"))
        XCTAssertEqual(record.reason, .replaced)
        XCTAssertEqual(record.sha256, editedDigest, "the record names the bytes actually retained")
        XCTAssertEqual(record.size, Int64("hand edit on share".utf8.count))
        XCTAssertEqual(summary.replicas[0].repaired, 1)
        XCTAssertEqual(summary.replicas[0].replaced, 1)
    }

    /// A folder where a file belongs is not a version of the file either — and the copy that
    /// would land there deletes the whole folder to put a file in its place, so it is refused.
    func testAFolderWhereAFileBelongsIsLeftAlone() async throws {
        let engine = sandbox.engine()
        try await syncFirstDraft(engine)
        let destination = sandbox.replicaURLs[0].appendingPathComponent("notes.txt")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        // Not empty: an empty folder on a replica is pruned away as leftover scaffolding, which
        // would hide the case this test is about.
        try "kept by hand".write(to: destination.appendingPathComponent("inside.txt"),
                                 atomically: true, encoding: .utf8)

        let summary = try await edit("second draft", to: engine)

        XCTAssertTrue(FileMeta.isDirectory(destination), "the folder is not replaced by a file")
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("inside.txt"), encoding: .utf8),
            "kept by hand",
            "nor is anything inside it"
        )
        XCTAssertEqual(try sandbox.contentsOnReplica(1, "notes.txt"), "second draft",
                       "the other destination mirrors the edit as usual")
        XCTAssertNil(sandbox.record(0, "notes.txt"))
        XCTAssertEqual(summary.replicas[0].failed, 1)
        XCTAssertTrue(summary.replicas[0].errors.contains { $0.contains("a folder is sitting") },
                      "the report says what is in the way: \(summary.replicas[0].errors)")
    }

    // MARK: - Expiry, and records written by an older build

    func testAReplacedVersionIsPurgedWithItsBytes() async throws {
        let engine = sandbox.engine()
        try await syncFirstDraft(engine)
        try await edit("second draft", to: engine)

        for index in 0..<2 {
            let aged = sandbox.records(index).map { record in
                DeleteRecord(relativePath: record.relativePath, sourcePath: record.sourcePath,
                             size: record.size, sha256: record.sha256,
                             deletedAt: Date().addingTimeInterval(-(DeleteRecord.retention + 60)),
                             reason: record.reason)
            }
            try sandbox.writeRecords(aged, index: index)
        }

        let purged = await engine.purgeExpiredDeletions(config: sandbox.config())

        XCTAssertEqual(purged, 2, "one expired version on each destination")
        for index in 0..<2 {
            XCTAssertFalse(sandbox.trashExists(index, "notes.txt"))
            XCTAssertNil(sandbox.record(index, "notes.txt"))
            XCTAssertEqual(try sandbox.contentsOnReplica(index, "notes.txt"), "second draft",
                           "the live file is untouched by the purge")
        }
    }

    /// A records file an older build wrote has no `reason` key. Decoding must not fail: a store that
    /// cannot be read is a store whose retained bytes nothing would ever find again.
    func testARecordFromAnOlderBuildStillLoads() throws {
        let url = sandbox.deleteStore.URL(for: sandbox.replicaModels[0].id)
        let legacy = """
        [
          {
            "deletedAt" : "2026-01-02T03:04:05Z",
            "expiresAt" : "2026-02-01T03:04:05Z",
            "id" : "\(UUID().uuidString)",
            "relativePath" : "Documents/old.txt",
            "sha256" : "abc123",
            "size" : 42,
            "sourcePath" : "/tmp/old.txt"
          }
        ]
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let records = sandbox.deleteStore.load(replicaID: sandbox.replicaModels[0].id)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].relativePath, "Documents/old.txt")
        XCTAssertEqual(records[0].sha256, "abc123")
        XCTAssertEqual(records[0].size, 42)
        XCTAssertEqual(records[0].sourcePath, "/tmp/old.txt")
        XCTAssertEqual(records[0].reason, .deleted, "a missing reason is a deletion, the only kind that existed")
    }
}
