import XCTest
@testable import NeoDropCore

/// The file status report is what a person sees when they ask about one file from Finder, so these
/// tests ask the question the way the menu item does — by absolute path — and check the answer
/// against a real mirror and a real vault on disk.
final class FileStatusTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox(name: "filestatus", replicaCount: 2)
    }

    override func tearDown() {
        sandbox = nil
    }

    private func query(_ config: AppConfig? = nil, paths: StorePaths? = nil) -> FileStatusQuery {
        FileStatusQuery(paths: paths ?? sandbox.storePaths, config: config ?? sandbox.config())
    }

    private func location(_ report: FileStatusReport, _ role: FileStatusRole, name: String? = nil) -> FileLocation? {
        report.locations.first { $0.role == role && (name == nil || $0.name == name) }
    }

    // MARK: - A mirrored file

    func testAProtectedFileNamesEveryCopyItHas() async throws {
        try sandbox.write("alpha", to: "docs/alpha.txt")
        _ = await sandbox.engine().sync(config: sandbox.config())

        let report = query().report(for: sandbox.sourceFile("docs/alpha.txt"))

        XCTAssertTrue(report.covered)
        XCTAssertEqual(report.kind, "file")
        XCTAssertEqual(report.relativePath, "docs/alpha.txt")
        XCTAssertEqual(report.protectedCopies, 3, "this Mac plus two destinations")

        let local = try XCTUnwrap(location(report, .source, name: "Source"))
        XCTAssertTrue(local.present)
        XCTAssertEqual(local.recorded?.kind, "source index")
        XCTAssertEqual(local.recorded?.matches, true)

        for name in ["NAS1", "NAS2"] {
            let copy = try XCTUnwrap(location(report, .replica, name: name), "\(name) should be listed")
            XCTAssertTrue(copy.present)
            XCTAssertEqual(copy.recorded?.kind, "manifest")
            XCTAssertEqual(copy.recorded?.matches, true, "the copy matches what NeoDrop recorded")
            XCTAssertTrue(copy.note.contains("complete copy"), copy.note)
        }

        XCTAssertTrue(report.summary.contains("It is on this Mac and copied to NAS1, NAS2"), report.summary)
    }

    /// The report is about the path, not about this Mac: asking about the NAS copy by its own path
    /// must still describe where the bytes are.
    func testAFileOnlyOnTheNASIsReportedHonestly() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        _ = await sandbox.engine().sync(config: sandbox.config())

        let onShare = sandbox.replicaURLs[0].appendingPathComponent("alpha.txt")
        let report = query().report(for: onShare)

        XCTAssertTrue(report.covered)
        XCTAssertEqual(location(report, .replica, name: "NAS1")?.present, true)
        XCTAssertTrue(report.summary.contains("not on this Mac"), report.summary)
        XCTAssertTrue(report.summary.contains("still in NAS1"), report.summary)
    }

    /// The report has to explain the one file a mirror deliberately leaves alone, and say what to do
    /// about it. "NeoDrop has no record of writing it" is true but leaves the reader nowhere: the
    /// next step is theirs, and it is deleting or moving the file on the share.
    func testAFileTheMirrorRefusedToReplaceIsExplained() async throws {
        try sandbox.write("ours", to: "report.txt")
        let inTheWay = sandbox.replicaURLs[0].appendingPathComponent("report.txt")
        try "theirs".write(to: inTheWay, atomically: true, encoding: .utf8)
        _ = await sandbox.engine().sync(config: sandbox.config())

        let report = query().report(for: inTheWay)
        let replica = try XCTUnwrap(location(report, .replica, name: "NAS1"))
        XCTAssertTrue(replica.present)
        XCTAssertTrue(replica.note.contains("left it alone rather than replace it"), replica.note)
        XCTAssertFalse(replica.note.contains("did not come from this Mac"),
                       "the generic answer is no longer enough: this one has a next step")
    }

    func testAPathOutsideEveryFolderIsSaidToBeUnprotected() throws {
        let report = query().report(for: sandbox.root.appendingPathComponent("elsewhere/notes.txt"))

        XCTAssertFalse(report.covered, "nothing configured contains it")
        XCTAssertTrue(report.locations.isEmpty)
        XCTAssertTrue(report.summary.contains("Not in any NeoDrop folder"), report.summary)
    }

    func testAFolderIsAnsweredAsAFolder() throws {
        let report = query().report(for: sandbox.source)

        XCTAssertTrue(report.covered)
        XCTAssertEqual(report.kind, "folder")
        XCTAssertTrue(report.summary.contains("This is a folder"), report.summary)
    }

    // MARK: - Damage and deletions

    /// A copy that was edited on the share itself is the failure this report exists to surface.
    func testACopyThatChangedOnTheShareIsFlagged() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        _ = await sandbox.engine().sync(config: sandbox.config())
        try sandbox.corruptOnReplica(0, "alpha.txt", with: "something else entirely")

        let report = query().report(for: sandbox.sourceFile("alpha.txt"))
        let damaged = try XCTUnwrap(location(report, .replica, name: "NAS1"))

        XCTAssertEqual(damaged.recorded?.matches, false)
        XCTAssertTrue(damaged.note.contains("no longer matches"), damaged.note)
        XCTAssertTrue(report.summary.contains("⚠︎ NAS1"), report.summary)
        XCTAssertEqual(location(report, .replica, name: "NAS2")?.recorded?.matches, true,
                       "the other destination is still intact")
    }

    func testADeletedFileIsAnsweredFromTheRetainedCopy() async throws {
        try sandbox.write("alpha", to: "docs/alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        try sandbox.delete("docs/alpha.txt")
        _ = await engine.sync(config: sandbox.config())

        let report = query().report(for: sandbox.sourceFile("docs/alpha.txt"))

        XCTAssertTrue(report.covered, "a deleted file is still NeoDrop's business")
        XCTAssertEqual(report.kind, "missing")
        let retained = try XCTUnwrap(location(report, .retainedCopy, name: "NAS1"))
        XCTAssertTrue(retained.present)
        XCTAssertEqual(retained.recorded?.kind, "deletion")
        XCTAssertEqual(retained.recorded?.expiresAt != nil, true, "the recovery window is stated")
        XCTAssertTrue(report.summary.contains("holding a copy until"), report.summary)
        XCTAssertFalse(report.summary.contains("No destination is reachable"),
                       "a retained copy explains where the bytes are: \(report.summary)")
    }

    /// Someone editing or removing a file on the share by hand: NeoDrop's record says it wrote the
    /// file, the share says otherwise, and the report has to admit that rather than count a copy.
    func testACopyRemovedFromTheShareIsNotCountedAsACopy() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        _ = await sandbox.engine().sync(config: sandbox.config())
        try FileManager.default.removeItem(at: sandbox.replicaURLs[0].appendingPathComponent("alpha.txt"))

        let report = query().report(for: sandbox.sourceFile("alpha.txt"))
        let gone = try XCTUnwrap(location(report, .replica, name: "NAS1"))

        XCTAssertFalse(gone.present, "the bytes are not there any more")
        XCTAssertEqual(gone.recorded?.kind, "manifest", "but NeoDrop still remembers writing it")
        XCTAssertTrue(gone.note.contains("gone from the share"), gone.note)
        XCTAssertTrue(report.summary.contains("copied to NAS2"), "the healthy destination is still reported: \(report.summary)")
        XCTAssertFalse(report.summary.contains("NAS1,"), "and the empty one is not: \(report.summary)")
    }

    // MARK: - A two-way folder

    func testAVaultFileIsAnsweredWithItsJournalHistory() async throws {
        let vaultSandbox = try VaultSandbox(name: "filestatus-vault", machineNames: ["Machine A", "Machine B"])

        try vaultSandbox.write("first version", machine: 0, to: "docs/alpha.txt")
        _ = try await vaultSandbox.sync(0)
        // B adopts the folder before changing anything. A file that appears in a folder before that
        // folder's first sync is a conflict by design — NeoDrop cannot know which copy is the edit —
        // and this test is about the ordinary case of one machine editing after both are in step.
        _ = try await vaultSandbox.sync(1)
        try vaultSandbox.write("second version", machine: 1, to: "docs/alpha.txt")
        _ = try await vaultSandbox.sync(1)
        _ = try await vaultSandbox.sync(0)

        let config = AppConfig(vaults: [vaultSandbox.link(0)])
        let report = FileStatusQuery(paths: vaultSandbox.machines[0].state, config: config)
            .report(for: vaultSandbox.machines[0].local.appendingPathComponent("docs/alpha.txt"))

        XCTAssertTrue(report.covered)
        let shared = try XCTUnwrap(location(report, .vault, name: "Shared"))
        XCTAssertTrue(shared.present)
        XCTAssertEqual(shared.recorded?.kind, "journal")
        XCTAssertEqual(shared.recorded?.machineName, "Machine B", "the newest publisher owns this version")
        XCTAssertTrue(shared.note.contains("Published by Machine B"), shared.note)

        XCTAssertEqual(location(report, .workingCopy, name: "Shared")?.present, true)
        XCTAssertFalse(report.history.isEmpty, "the vault's journal is the history")
        XCTAssertEqual(report.history.first?.machineName, "Machine B")
        XCTAssertTrue(report.history.contains { $0.kind == "create" }, "the first publish is remembered")
        XCTAssertTrue(report.summary.contains("copied to Shared"), report.summary)
    }

    /// Deleting on one machine and asking about the path on the other: the vault's journal holds the
    /// tombstone, and the report must say who deleted it rather than "no machine published this".
    func testATombstoneOnTheVaultIsExplained() async throws {
        let vaultSandbox = try VaultSandbox(name: "filestatus-tombstone", machineNames: ["Machine A", "Machine B"])

        try vaultSandbox.write("alpha", machine: 0, to: "alpha.txt")
        _ = try await vaultSandbox.sync(0)
        _ = try await vaultSandbox.sync(1)
        try FileManager.default.removeItem(at: vaultSandbox.machines[1].local.appendingPathComponent("alpha.txt"))
        _ = try await vaultSandbox.sync(1)
        _ = try await vaultSandbox.sync(0)

        let config = AppConfig(vaults: [vaultSandbox.link(0)])
        let report = FileStatusQuery(paths: vaultSandbox.machines[0].state, config: config)
            .report(for: vaultSandbox.machines[0].local.appendingPathComponent("alpha.txt"))

        let shared = try XCTUnwrap(location(report, .vault, name: "Shared"))
        XCTAssertFalse(shared.present)
        XCTAssertTrue(shared.note.contains("Deleted by Machine B"), shared.note)
        XCTAssertTrue(report.history.contains { $0.kind == "delete" }, "the delete is in the history")
    }

    // MARK: - Cost

    /// The report never reads the file's contents, so it must not grow with the file: asking about a
    /// large file has to stay in the same range as asking about a small one.
    func testLargeFilesAreNotHashedToAnswerTheQuestion() async throws {
        try sandbox.writeRandomBytes(to: "big.bin", byteCount: 8 * 1024 * 1024)
        try sandbox.write("small", to: "small.txt")
        _ = await sandbox.engine().sync(config: sandbox.config())

        let started = Date()
        let small = query().report(for: sandbox.sourceFile("small.txt"))
        let smallTime = Date().timeIntervalSince(started)

        let bigStarted = Date()
        let big = query().report(for: sandbox.sourceFile("big.bin"))
        let bigTime = Date().timeIntervalSince(bigStarted)

        XCTAssertTrue(small.covered)
        XCTAssertTrue(big.covered)
        XCTAssertLessThan(bigTime, 2.0, "8 MB must not be read to answer: took \(bigTime)s")
        XCTAssertLessThan(bigTime, max(smallTime, 0.05) * 20,
                          "cost must not scale with the file: small \(smallTime)s vs big \(bigTime)s")
    }
}
