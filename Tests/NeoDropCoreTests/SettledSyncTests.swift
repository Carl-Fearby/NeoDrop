import XCTest
@testable import NeoDropCore

/// A sync that has nothing to do should cost nothing much.
///
/// It used to walk the whole tree in pages of `catchUpBatchSize`, and every pass re-scanned the
/// folder and walked the share again: measured on a 5,000-path vault that was ten passes and
/// sixteen seconds for a sync that changed nothing, every fifteen minutes. These tests are the
/// conditions under which that walk may be skipped — and, more importantly, the conditions under
/// which it may *not*: a share that lost bytes, something dropped into it by hand, a change
/// published elsewhere, a change made here.
final class SettledSyncTests: XCTestCase {
    private var sandbox: VaultSandbox!

    override func setUpWithError() throws {
        sandbox = try VaultSandbox(name: "settled")
    }

    override func tearDown() {
        sandbox = nil
    }

    /// Run one sync the way the app does: keep taking passes while a cursor says more is due, and
    /// fold them into one summary (what the menu and the log then report as one sync).
    @discardableResult
    private func settle(_ machine: Int) async throws -> (passes: Int, summary: VaultSyncSummary) {
        var passes = 1
        var summary = try await sandbox.sync(machine)
        while summary.catchUpPending {
            let next = try await sandbox.sync(machine)
            summary.absorb(next)
            passes += 1
            XCTAssertLessThan(passes, 20, "a bounded walk must finish")
        }
        return (passes, summary)
    }

    /// Take passes until a machine is genuinely settled — a pass that walked nothing to find.
    ///
    /// One is not enough after a machine has published: its own append left the journal bigger than
    /// the record it keeps of it, so the next pass walks, records what it saw, and only the pass
    /// after *that* settles. That is deliberate (a change missed by trusting a stale record would be
    /// missed for ever), and it is the cost of settling at all.
    @discardableResult
    private func settleFully(_ machine: Int) async throws -> VaultSyncSummary {
        var last: VaultSyncSummary?
        for _ in 0..<5 {
            let outcome = try await settle(machine)
            last = outcome.summary
            if outcome.summary.catchUpProcessed == 0 { return outcome.summary }
        }
        XCTFail("the tree never settled")
        return try unwrap(last)
    }

    /// A tree both machines have caught up with and settled into.
    @discardableResult
    private func caughtUp(total: Int = 3) async throws -> Int {
        for index in 0..<total {
            try sandbox.write("payload \(index)", machine: 0, to: String(format: "file-%04d.txt", index))
        }
        try await settle(0)
        try await settle(1)
        try await settleFully(0)
        try await settleFully(1)
        return total
    }

    // MARK: - Settling at all

    func testASyncWithNothingToDoSettlesInOnePass() async throws {
        let total = try await caughtUp(total: VaultSync.catchUpBatchSize + 23)
        let journalBefore = sandbox.journalLines(machine: 1)

        let (passes, settled) = try await settle(1)

        XCTAssertEqual(passes, 1, "an idle sync is one pass, not one per page")
        XCTAssertEqual(settled.catchUpProcessed, 0, "nothing was walked")
        XCTAssertFalse(settled.catchUpPending)
        XCTAssertEqual(settled.upToDate, total, "and every path still counts as agreed")
        XCTAssertEqual(settled.uploaded, 0)
        XCTAssertEqual(settled.downloaded, 0)
        XCTAssertEqual(settled.errors, [])
        XCTAssertEqual(settled.phase, .finished)
        XCTAssertEqual(sandbox.journalLines(machine: 1), journalBefore, "a settled pass announces nothing")
        XCTAssertEqual(settled.journalBytesRead, 0,
                       "and it decodes nothing: the whole history is not read again to say so")
    }

    /// The bound the index exists for: a journal grows with the vault's history, so reading all of
    /// it every pass is work that gets worse the longer a vault is used. A pass now reads what was
    /// appended since the last one, which for a publish on another machine is one line.
    func testAPassReadsWhatWasAppendedRatherThanTheWholeHistory() async throws {
        try await caughtUp(total: VaultSync.catchUpBatchSize + 23)
        let whole = totalJournalBytes()
        XCTAssertGreaterThan(whole, 1_000, "the history has to be worth not reading")

        try sandbox.write("changed on A", machine: 0, to: "file-0500.txt")
        try await settle(0)

        let (_, applied) = try await settle(1)

        XCTAssertEqual(applied.downloaded, 1)
        XCTAssertGreaterThan(applied.journalBytesRead, 0, "the entry that announced the change is read")
        XCTAssertLessThan(applied.journalBytesRead, whole / 20,
                          "and of \(whole) bytes of history, only that entry")
    }

    private func totalJournalBytes() -> Int64 {
        let journals = sandbox.vault.appendingPathComponent("\(VaultStore.metadataDirectoryName)/journals")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: journals.path)) ?? []
        return names.reduce(0) { total, name in
            let url = journals.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// The record that makes settling possible has to be written by the settled pass itself, or the
    /// next sync walks again — which is exactly the trap this change fell into first: the walk wrote
    /// the journal sizes and the settled pass did not, so settling never happened twice.
    func testSettlingRepeatsUntilSomethingMoves() async throws {
        let total = try await caughtUp(total: VaultSync.catchUpBatchSize + 23)

        for round in 1...3 {
            let (passes, settled) = try await settle(1)
            XCTAssertEqual(passes, 1, "round \(round) took more than one pass")
            XCTAssertEqual(settled.catchUpProcessed, 0, "round \(round) walked the tree")
            XCTAssertEqual(settled.upToDate, total, "round \(round) lost track of the tree")
        }
    }

    func testASettledPassKeepsTheStateItWasGiven() async throws {
        try await caughtUp()
        let vaultID = try XCTUnwrap(VaultStore(root: sandbox.vault).loadIdentity()?.id)
        let cursorStore = VaultCursorStore(paths: sandbox.machines[1].state)
        let before = try XCTUnwrap(cursorStore.load(vaultID: vaultID))

        try await settle(1)

        let after = try XCTUnwrap(cursorStore.load(vaultID: vaultID))
        XCTAssertEqual(after.applied, before.applied, "the merge base is not disturbed by settling")
        XCTAssertNil(after.catchUpAfter)
        XCTAssertNil(after.catchUpDirtyPaths)
        XCTAssertEqual(after.catchUpJournalBytes, VaultStore(root: sandbox.vault).journalSizes(),
                       "what the pass saw, recorded — this is what lets the next one settle")
    }

    // MARK: - What settling must not swallow

    /// The journal cannot say whether the share still holds its bytes, so a settled pass asks — and
    /// a truncated copy is still put back. This is the promise that makes a cheap sync acceptable.
    func testASettledPassStillRepairsATruncatedShareFile() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await settle(0)
        try await settle(1)
        // A published that file, so it needs a pass before it can settle at all; that state is what
        // this test is about.
        let sitting = try await settleFully(0)
        XCTAssertEqual(sitting.catchUpProcessed, 0, "A is settled before the share loses its bytes")

        try "alp".write(to: sandbox.vault.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)

        let (passes, repaired) = try await settle(0)

        XCTAssertEqual(passes, 1)
        XCTAssertEqual(repaired.catchUpProcessed, 0, "still settled: a repair is not a walk")
        XCTAssertEqual(repaired.repairs, ["alpha.txt"])
        XCTAssertEqual(try sandbox.vaultRead("alpha.txt"), "alpha")
        XCTAssertEqual(repaired.errors, [])
        XCTAssertEqual(sandbox.journalLines(machine: 0).count, 1, "a repair is not a journal entry")
    }

    /// A file dropped onto the share by hand is work, so the pass that finds it is not settled —
    /// otherwise a share would quietly stop noticing what people put in it.
    func testAFileDroppedOntoTheShareIsStillAdopted() async throws {
        try await caughtUp()
        try "hand".write(to: sandbox.vault.appendingPathComponent("by-hand.txt"), atomically: true, encoding: .utf8)

        let (_, adopted) = try await settle(0)
        XCTAssertEqual(adopted.adoptedInVault, 1)

        let (_, other) = try await settle(1)
        XCTAssertEqual(try sandbox.read(machine: 1, "by-hand.txt"), "hand")
        XCTAssertEqual(other.adoptedInVault, 0, "only the machine that noticed it claims it")
    }

    /// A change published on another machine moves the journal, which is what makes settling safe.
    func testAPublishOnAnotherMachineBringsTheWalkBack() async throws {
        try await caughtUp(total: VaultSync.catchUpBatchSize + 23)
        try sandbox.write("changed on A", machine: 0, to: "file-0500.txt")
        try await settle(0)

        let (_, applied) = try await settle(1)

        XCTAssertEqual(applied.downloaded, 1)
        XCTAssertEqual(try sandbox.read(machine: 1, "file-0500.txt"), "changed on A")
        XCTAssertFalse(applied.catchUpPending)
    }

    func testALocalChangeBringsTheWalkBackToo() async throws {
        try await caughtUp()

        try sandbox.write("edited on B", machine: 1, to: "file-0001.txt")
        let (_, published) = try await settle(1)
        XCTAssertEqual(published.uploaded, 1)
        XCTAssertEqual(try sandbox.vaultRead("file-0001.txt"), "edited on B")

        // A file nobody has seen before counts as a change as well.
        try sandbox.write("brand new", machine: 1, to: "brand-new.txt")
        let (_, added) = try await settle(1)
        XCTAssertEqual(added.uploaded, 1)
        XCTAssertEqual(try sandbox.vaultRead("brand-new.txt"), "brand new")
    }

    /// A settled pass writes the merge base out of what the vault says, so the next change has to be
    /// read against that base — a remote deletion whose path this machine still holds is exactly the
    /// case where a wrong base would publish the file back instead of moving it to the trash.
    func testASettledBaseStillRecognisesARemoteDeletion() async throws {
        let total = try await caughtUp()
        try await settle(1)

        try sandbox.delete(machine: 0, "file-0002.txt")
        try await settle(0)

        let (_, applied) = try await settle(1)

        XCTAssertEqual(applied.remoteDeletionsApplied, 1)
        XCTAssertFalse(sandbox.exists(machine: 1, "file-0002.txt"))
        XCTAssertEqual(sandbox.trashFiles(machine: 1), ["file-0002.txt"], "and the bytes are kept")
        XCTAssertEqual(sandbox.localFiles(machine: 1).count, total - 1)
    }

    func testAFreshMachineNeverSettlesItself() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await settle(0)

        let (_, seeded) = try await settle(1)

        XCTAssertTrue(seeded.seeded)
        XCTAssertEqual(seeded.downloaded, 1, "a machine with no record of the tree walks it")
        XCTAssertEqual(try sandbox.read(machine: 1, "alpha.txt"), "alpha")
    }
}
