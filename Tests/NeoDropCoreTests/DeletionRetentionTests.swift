import XCTest
@testable import NeoDropCore

/// Deletions are recorded, not performed: the bytes move into `.neodrop-trash/` on every
/// destination and stay there for 30 days, so the user can get a file back after deleting it.
final class DeletionRetentionTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox(name: "retention", replicaCount: 2)
    }

    override func tearDown() {
        sandbox = nil
    }

    /// Mirror a file, then delete it from the source: the bytes must still be on both replicas,
    /// under the trash directory, with a record that says where they came from.
    private func deleteAndSync(_ relativePath: String, contents: String = "alpha") async throws -> MirrorEngine {
        try sandbox.write(contents, to: relativePath)
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        try sandbox.delete(relativePath)
        _ = await engine.sync(config: sandbox.config())
        return engine
    }

    // MARK: - Recording

    func testDeletedFileIsRetainedInsteadOfDestroyed() async throws {
        // The digest of the file as it was, before the deletion takes it out of the source.
        try sandbox.write("alpha", to: "alpha.txt")
        let digest = try sandbox.sourceDigest("alpha.txt")
        _ = try await deleteAndSync("alpha.txt")

        for index in 0..<2 {
            XCTAssertFalse(sandbox.fileExistsOnReplica(index, "alpha.txt"), "the live copy is gone")
            XCTAssertTrue(sandbox.trashExists(index, "alpha.txt"), "the bytes are kept, not deleted")
            XCTAssertEqual(try sandbox.trashContents(index, "alpha.txt"), "alpha")
        }

        let record = try XCTUnwrap(sandbox.record(0, "alpha.txt"))
        XCTAssertEqual(record.sha256, digest, "the record verifies a restore against the deleted file's digest")
        XCTAssertEqual(record.size, 5)
        XCTAssertEqual(record.sourcePath, sandbox.sourceFile("alpha.txt").path)
        XCTAssertEqual(
            record.expiresAt.timeIntervalSince(record.deletedAt),
            DeleteRecord.retention,
            accuracy: 1,
            "the recovery window is the advertised 30 days"
        )
        XCTAssertFalse(record.isExpired)
        XCTAssertEqual(sandbox.record(1, "alpha.txt")?.sha256, digest, "every destination records it")
    }

    func testNestedPathIsRetainedAtTheSameRelativePath() async throws {
        _ = try await deleteAndSync("Documents/2026/plans.txt", contents: "nested")

        XCTAssertTrue(sandbox.trashExists(0, "Documents/2026/plans.txt"))
        XCTAssertEqual(try sandbox.trashContents(1, "Documents/2026/plans.txt"), "nested")
    }

    /// A deletion that never happened must not leave a record behind.
    func testNoRecordsWhenNothingWasDeleted() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        XCTAssertTrue(sandbox.records(0).isEmpty)
        let entries = await engine.listDeletions(config: sandbox.config())
        XCTAssertEqual(entries.count, 0)
    }

    // MARK: - The list the web view shows

    func testListAggregatesBothDestinationsIntoOneEntry() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let digest = try sandbox.sourceDigest("alpha.txt")
        let engine = try await deleteAndSync("alpha.txt")
        try sandbox.write("beta", to: "beta.txt")
        _ = await engine.sync(config: sandbox.config())
        try sandbox.delete("beta.txt")
        _ = await engine.sync(config: sandbox.config())

        // Age alpha's record so "newest first" is a real ordering rather than a tie broken by
        // path: two deletions in the same second are genuinely unordered.
        for index in 0..<2 {
            let aged = sandbox.records(index).map { record -> DeleteRecord in
                guard record.relativePath == "alpha.txt" else { return record }
                return DeleteRecord(relativePath: record.relativePath, sourcePath: record.sourcePath,
                                    size: record.size, sha256: record.sha256,
                                    deletedAt: record.deletedAt.addingTimeInterval(-7200))
            }
            try sandbox.writeRecords(aged, index: index)
        }

        let entries = await engine.listDeletions(config: sandbox.config())

        XCTAssertEqual(entries.map(\.relativePath), ["beta.txt", "alpha.txt"], "newest deletion first")
        let entry = try XCTUnwrap(entries.first { $0.relativePath == "alpha.txt" })
        XCTAssertEqual(entry.sha256, digest)
        XCTAssertEqual(entry.size, 5)
        XCTAssertEqual(entry.sourcePath, sandbox.sourceFile("alpha.txt").path)
        XCTAssertTrue(entry.restorable)
        XCTAssertEqual(entry.copies.map(\.replicaName), ["NAS1", "NAS2"])
        XCTAssertTrue(entry.copies.allSatisfy(\.available))
    }

    func testEntryIsNotRestorableWhileEveryDestinationIsUnreachable() async throws {
        let engine = try await deleteAndSync("alpha.txt")
        // Both shares go away, e.g. the network dropped. The records must survive untouched.
        try FileManager.default.moveItem(at: sandbox.root.appendingPathComponent("NAS1"),
                                        to: sandbox.root.appendingPathComponent("NAS1-away"))
        try FileManager.default.moveItem(at: sandbox.root.appendingPathComponent("NAS2"),
                                        to: sandbox.root.appendingPathComponent("NAS2-away"))
        defer {
            try? FileManager.default.moveItem(at: sandbox.root.appendingPathComponent("NAS1-away"),
                                              to: sandbox.root.appendingPathComponent("NAS1"))
            try? FileManager.default.moveItem(at: sandbox.root.appendingPathComponent("NAS2-away"),
                                              to: sandbox.root.appendingPathComponent("NAS2"))
        }

        let entries = await engine.listDeletions(config: sandbox.config())
        XCTAssertEqual(entries.count, 1, "the entry is still listed — the copies are not gone, just unreachable")
        XCTAssertFalse(entries[0].restorable)
        XCTAssertTrue(entries[0].copies.allSatisfy { !$0.available })
    }

    // MARK: - Restore

    func testRestorePutsTheFileBackInItsOriginalFolder() async throws {
        let engine = try await deleteAndSync("Documents/2026/plans.txt", contents: "nested")

        let destination = try await engine.restore(relativePath: "Documents/2026/plans.txt", config: sandbox.config())

        XCTAssertEqual(destination, sandbox.sourceFile("Documents/2026/plans.txt"))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "nested")
        for index in 0..<2 {
            XCTAssertFalse(sandbox.trashExists(index, "Documents/2026/plans.txt"), "the retained copy is given back")
            XCTAssertTrue(sandbox.records(index).isEmpty, "the record is cleared once it is restored")
        }
        let entries = await engine.listDeletions(config: sandbox.config())
        XCTAssertEqual(entries.count, 0)
    }

    func testRestoredFileIsMirroredAgainOnTheNextSync() async throws {
        let engine = try await deleteAndSync("alpha.txt")
        _ = try await engine.restore(relativePath: "alpha.txt", config: sandbox.config())

        let summary = try unwrap(await engine.sync(config: sandbox.config()))

        XCTAssertEqual(summary.filesCopied, 2, "the file is copied back to both replicas")
        XCTAssertEqual(try sandbox.contentsOnReplica(0, "alpha.txt"), "alpha")
        XCTAssertEqual(try sandbox.contentsOnReplica(1, "alpha.txt"), "alpha")
        XCTAssertEqual(try sandbox.mirrorContents()["NAS1"], try sandbox.mirrorContents()["NAS2"])
    }

    func testRestoreFallsBackToTheOtherDestination() async throws {
        let engine = try await deleteAndSync("alpha.txt")
        // The first destination loses its retained copy: the other one still has verified bytes.
        try sandbox.removeTrash(0, "alpha.txt")

        let destination = try await engine.restore(relativePath: "alpha.txt", config: sandbox.config())

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "alpha")
        XCTAssertFalse(sandbox.trashExists(1, "alpha.txt"))
    }

    /// The rule the rest of the engine follows: never overwrite the user's data.
    func testRestoreRefusesToOverwriteADifferentFile() async throws {
        let engine = try await deleteAndSync("alpha.txt")
        try sandbox.write("a completely different file", to: "alpha.txt")

        do {
            _ = try await engine.restore(relativePath: "alpha.txt", config: sandbox.config())
            XCTFail("restoring over a different file must fail")
        } catch let error as NeoDropError {
            guard case .restoreConflict = error else {
                return XCTFail("expected a conflict, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: sandbox.sourceFile("alpha.txt"), encoding: .utf8),
                       "a completely different file", "the new file is untouched")
        XCTAssertTrue(sandbox.trashExists(0, "alpha.txt"), "the retained copy is still there")
        XCTAssertNotNil(sandbox.record(0, "alpha.txt"))
    }

    func testRestoreIsAQuietSuccessWhenTheFileIsAlreadyBack() async throws {
        let engine = try await deleteAndSync("alpha.txt")
        // Something else already restored it — a manual copy, or another machine's sync.
        try sandbox.write("alpha", to: "alpha.txt")

        let destination = try await engine.restore(relativePath: "alpha.txt", config: sandbox.config())

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "alpha")
        XCTAssertFalse(sandbox.trashExists(0, "alpha.txt"), "the redundant copy is given back")
        XCTAssertTrue(sandbox.records(0).isEmpty)
    }

    func testRestoreRefusesWhenTheOriginalFolderIsNoLongerConfigured() async throws {
        let engine = try await deleteAndSync("alpha.txt")
        var config = sandbox.config()
        config.sources = []

        do {
            _ = try await engine.restore(relativePath: "alpha.txt", config: config)
            XCTFail("there is nowhere to restore to")
        } catch let error as NeoDropError {
            guard case .restoreSourceUnavailable = error else {
                return XCTFail("expected the source to be reported as unavailable, got \(error)")
            }
        }

        XCTAssertTrue(sandbox.trashExists(0, "alpha.txt"), "a refused restore keeps the bytes")
        XCTAssertNotNil(sandbox.record(0, "alpha.txt"))
    }

    func testRestoreOfSomethingNeverDeletedFails() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())

        do {
            _ = try await engine.restore(relativePath: "alpha.txt", config: sandbox.config())
            XCTFail("nothing was deleted, so there is nothing to restore")
        } catch let error as NeoDropError {
            guard case .retainedCopyUnavailable = error else {
                return XCTFail("expected an unavailable copy, got \(error)")
            }
        }
    }

    // MARK: - Expiry

    func testExpiredRecordIsPurgedWithItsBytes() async throws {
        let engine = try await deleteAndSync("old.txt", contents: "old")
        try sandbox.write("fresh", to: "fresh.txt")
        _ = await engine.sync(config: sandbox.config())
        try sandbox.delete("fresh.txt")
        _ = await engine.sync(config: sandbox.config())

        // Age only the first deletion past its window.
        for index in 0..<2 {
            let aged = sandbox.records(index).map { record -> DeleteRecord in
                guard record.relativePath == "old.txt" else { return record }
                let deletedAt = Date().addingTimeInterval(-(DeleteRecord.retention + 60))
                return DeleteRecord(relativePath: record.relativePath, sourcePath: record.sourcePath,
                                    size: record.size, sha256: record.sha256, deletedAt: deletedAt)
            }
            try sandbox.writeRecords(aged, index: index)
        }

        let purged = await engine.purgeExpiredDeletions(config: sandbox.config())

        XCTAssertEqual(purged, 2, "one expired deletion on each destination")
        for index in 0..<2 {
            XCTAssertFalse(sandbox.trashExists(index, "old.txt"), "the expired bytes are given back")
            XCTAssertNil(sandbox.record(index, "old.txt"))
            XCTAssertTrue(sandbox.trashExists(index, "fresh.txt"), "a live deletion is never touched")
            XCTAssertNotNil(sandbox.record(index, "fresh.txt"))
        }
        let entries = await engine.listDeletions(config: sandbox.config())
        XCTAssertEqual(entries.map(\.relativePath), ["fresh.txt"])
    }

    func testPurgeLeavesUnreachableDestinationsAlone() async throws {
        _ = try await deleteAndSync("alpha.txt")
        for index in 0..<2 {
            let aged = sandbox.records(index).map { record in
                DeleteRecord(relativePath: record.relativePath, sourcePath: record.sourcePath,
                             size: record.size, sha256: record.sha256,
                             deletedAt: Date().addingTimeInterval(-(DeleteRecord.retention + 60)))
            }
            try sandbox.writeRecords(aged, index: index)
        }

        // NAS1 is unmounted. Its copies are still on the share, so the record must stay.
        try FileManager.default.moveItem(at: sandbox.root.appendingPathComponent("NAS1"),
                                        to: sandbox.root.appendingPathComponent("NAS1-away"))
        defer {
            try? FileManager.default.moveItem(at: sandbox.root.appendingPathComponent("NAS1-away"),
                                              to: sandbox.root.appendingPathComponent("NAS1"))
        }

        let purged = await MirrorEngine(paths: sandbox.storePaths)
            .purgeExpiredDeletions(config: sandbox.config())

        XCTAssertEqual(purged, 1, "only the reachable destination is purged")
        XCTAssertNotNil(sandbox.record(0, "alpha.txt"), "the unmounted share keeps its record")
        XCTAssertNil(sandbox.record(1, "alpha.txt"))
    }

    func testExpiredEntriesLeaveTheList() async throws {
        let engine = try await deleteAndSync("alpha.txt")
        for index in 0..<2 {
            let aged = sandbox.records(index).map { record in
                DeleteRecord(relativePath: record.relativePath, sourcePath: record.sourcePath,
                             size: record.size, sha256: record.sha256,
                             deletedAt: Date().addingTimeInterval(-(DeleteRecord.retention + 60)))
            }
            try sandbox.writeRecords(aged, index: index)
        }

        let entries = await engine.listDeletions(config: sandbox.config())
        XCTAssertEqual(entries.count, 0, "a row whose restore button cannot work is not shown")
    }

    // MARK: - Reconciling records against reality

    func testRecordIsDroppedWhenTheFileReturnsToTheSource() async throws {
        let engine = try await deleteAndSync("alpha.txt")
        // Restored by something other than this app's restore path, byte for byte.
        try sandbox.write("alpha", to: "alpha.txt")

        let summary = try unwrap(await engine.sync(config: sandbox.config()))

        XCTAssertEqual(summary.filesCopied, 2, "the file is mirrored again")
        for index in 0..<2 {
            XCTAssertNil(sandbox.record(index, "alpha.txt"), "the deletion is no longer a deletion")
            XCTAssertFalse(sandbox.trashExists(index, "alpha.txt"))
        }
    }

    func testRecordIsKeptWhenTheFileComesBackWithDifferentContent() async throws {
        let engine = try await deleteAndSync("alpha.txt")
        // A new file that happens to share the name is not the file that was deleted, so the
        // retained copy stays recoverable.
        try sandbox.write("a different file entirely", to: "alpha.txt")
        _ = await engine.sync(config: sandbox.config())

        XCTAssertNotNil(sandbox.record(0, "alpha.txt"))
        XCTAssertTrue(sandbox.trashExists(0, "alpha.txt"))
        XCTAssertEqual(try sandbox.trashContents(0, "alpha.txt"), "alpha")
        let entries = await engine.listDeletions(config: sandbox.config())
        XCTAssertEqual(entries.count, 1)
    }

    func testRecordIsDroppedWhenItsRetainedBytesVanish() async throws {
        let engine = try await deleteAndSync("alpha.txt")
        try sandbox.removeTrash(0, "alpha.txt")

        _ = await engine.sync(config: sandbox.config())

        XCTAssertNil(sandbox.record(0, "alpha.txt"), "a record that cannot restore anything is dead weight")
        XCTAssertNotNil(sandbox.record(1, "alpha.txt"), "the other destination still has the bytes")
        XCTAssertEqual(try sandbox.trashContents(1, "alpha.txt"), "alpha")
    }

    /// Records live in a JSON file the user can edit. One that points outside the trash directory
    /// must never be able to make the engine delete or write anything, anywhere.
    func testRecordThatEscapesTheTrashDirectoryIsNeverActedOn() async throws {
        _ = try await deleteAndSync("alpha.txt")

        let escapePath = sandbox.root.appendingPathComponent("escape.txt")
        try "not neodrop's to touch".write(to: escapePath, atomically: true, encoding: .utf8)
        let escaped = DeleteRecord(
            relativePath: "../../escape.txt",
            sourcePath: sandbox.sourceFile("../../escape.txt").path,
            size: 24,
            sha256: try Hashing.sha256(ofFileAt: escapePath),
            deletedAt: Date().addingTimeInterval(-(DeleteRecord.retention + 60))
        )
        var records = sandbox.records(0)
        records.append(escaped)
        try sandbox.writeRecords(records, index: 0)

        let engine = sandbox.engine()
        let purged = await engine.purgeExpiredDeletions(config: sandbox.config())

        XCTAssertTrue(FileManager.default.fileExists(atPath: escapePath.path),
                      "a record cannot point the purge at a file outside the trash directory")
        XCTAssertEqual(purged, 0, "the escaping record is not counted as purged")
        XCTAssertNil(sandbox.record(0, "../../escape.txt"), "and the bogus record is discarded")
        XCTAssertNotNil(sandbox.record(0, "alpha.txt"), "the real record is untouched")

        do {
            _ = try await engine.restore(relativePath: "../../escape.txt", config: sandbox.config())
            XCTFail("an escaping record must not be restorable")
        } catch is NeoDropError {
            // Either "no verified copy" or "no destination": both refuse without writing.
        }
        XCTAssertEqual(try String(contentsOf: escapePath, encoding: .utf8), "not neodrop's to touch")
    }

    // MARK: - Behaviour the settings must keep working

    func testArchiveDestinationsKeepTheirFilesInsteadOfRecording() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        var config = sandbox.config()
        config.mirrorDeletions = false

        let engine = sandbox.engine()
        _ = await engine.sync(config: config)
        try sandbox.delete("alpha.txt")
        _ = await engine.sync(config: config)

        XCTAssertTrue(sandbox.fileExistsOnReplica(0, "alpha.txt"), "an archive replica keeps the file")
        XCTAssertTrue(sandbox.records(0).isEmpty, "nothing was deleted, so there is nothing to recover")
        let entries = await engine.listDeletions(config: config)
        XCTAssertEqual(entries.count, 0)
    }

    /// Bulk deletions are the dangerous case, and they still have to be recoverable when the user
    /// has explicitly allowed them.
    func testBulkDeletionIsFullyRecoverable() async throws {
        for index in 0..<40 { try sandbox.write("payload \(index)", to: "file-\(index).txt") }
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        for index in 0..<40 { try sandbox.delete("file-\(index).txt") }

        var config = sandbox.config()
        config.allowBulkDeletions = true
        _ = await engine.sync(config: config)

        let entries = await engine.listDeletions(config: config)
        XCTAssertEqual(entries.count, 40, "every one of them is offered for recovery")
        XCTAssertTrue(entries.allSatisfy(\.restorable))

        for index in 0..<40 {
            _ = try await engine.restore(relativePath: "file-\(index).txt", config: config)
        }
        for index in 0..<40 {
            XCTAssertEqual(try String(contentsOf: sandbox.sourceFile("file-\(index).txt"), encoding: .utf8),
                           "payload \(index)", "every file is back in the source folder")
        }
        // Restoring puts the file back in the source; the mirror catches up on the next sync.
        _ = await engine.sync(config: config)
        for index in 0..<40 {
            XCTAssertEqual(try sandbox.contentsOnReplica(0, "file-\(index).txt"), "payload \(index)")
        }
        let remaining = await engine.listDeletions(config: config)
        XCTAssertEqual(remaining.count, 0)
    }
}
