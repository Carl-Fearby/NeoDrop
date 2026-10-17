import XCTest
@testable import NeoDropCore

/// A vault's journals are append-only and grow for the life of the vault, so decoding all of them
/// on every pass costs its history rather than its size. These tests are about the record that
/// makes that stop — and about the ways a cached read can be wrong, which are the only interesting
/// part: a journal that shrank, one that vanished, a tail that was torn mid-append, a line that
/// cannot be decoded, and an index written by a build that meant something else by it.
final class JournalIndexTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("neodrop-journal-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VaultStore(root: root)
        try store.ensureDirectories()
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Helpers

    private func entry(
        _ seq: Int,
        _ machine: String,
        _ path: String,
        sha: String? = nil,
        kind: JournalEntry.Kind = .create,
        at: Date = Date(),
        previous: String? = nil
    ) -> JournalEntry {
        JournalEntry(
            seq: seq, machine: machine, machineName: machine, at: at,
            path: path, kind: kind, size: 3, sha256: sha ?? "sha-\(path)", previousSha256: previous
        )
    }

    /// Put raw lines in a journal, for the cases a well-behaved writer never produces.
    private func writeJournal(_ machine: String, lines: [String]) throws {
        var data = Data()
        for line in lines {
            data.append(Data(line.utf8))
            data.append(0x0a)
        }
        try data.write(to: store.journalURL(machine: machine))
    }

    private func line(_ entry: JournalEntry) throws -> String {
        String(decoding: try JournalCoding.encoder().encode(entry), as: UTF8.self)
    }

    private func appendRaw(_ machine: String, _ raw: String) throws {
        let handle = try FileHandle(forWritingTo: store.journalURL(machine: machine))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(raw.utf8))
    }

    private func totalJournalBytes() -> Int64 {
        store.journalSizes().values.reduce(0, +)
    }

    /// The state a full read gives, which every incremental read has to match exactly.
    private func fullState() -> VaultState {
        store.state(from: store.loadEntries().entries)
    }

    // MARK: - Reading only what is new

    func testTheFirstReadReadsEverythingAndTheNextReadsNothing() throws {
        try store.append([entry(1, "A", "alpha.txt"), entry(2, "A", "beta.txt")], machineID: "A")
        try store.append([entry(1, "B", "gamma.txt")], machineID: "B")
        let whole = totalJournalBytes()

        let first = store.readJournals(cached: nil)

        XCTAssertTrue(first.rebuilt)
        XCTAssertEqual(first.bytesRead, whole)
        XCTAssertEqual(first.entries.count, 3)
        XCTAssertEqual(first.errors, [])
        XCTAssertEqual(first.index.files, fullState().files)

        let second = store.readJournals(cached: first.index)

        XCTAssertFalse(second.rebuilt)
        XCTAssertEqual(second.bytesRead, 0, "a vault that has not moved costs no read at all")
        XCTAssertEqual(second.entries, [])
        XCTAssertEqual(second.index, first.index, "and nothing about the index changes")
    }

    func testOnlyTheAppendedEntryIsReadAndTheStateIsTheSameAsAFullRead() throws {
        for index in 1...50 {
            try store.append([entry(index, "A", String(format: "file-%02d.txt", index), sha: "sha-\(index)")], machineID: "A")
        }
        let first = store.readJournals(cached: nil)

        try store.append([entry(51, "A", "file-51.txt", sha: "sha-51", previous: "sha-50")], machineID: "A")
        let second = store.readJournals(cached: first.index)

        XCTAssertEqual(second.entries.count, 1, "the other fifty entries are not decoded again")
        XCTAssertLessThan(second.bytesRead, first.bytesRead / 10, "and not even read")
        XCTAssertEqual(second.index.files, fullState().files)
        XCTAssertEqual(second.index.nextSequence(machineID: "A"), 52)
    }

    /// The tail is merged into what was known, and the merge has to be the same maximum a full
    /// merge would have taken — including when a batch holds two entries for one path.
    func testAMergeSeesTheNewestEntryForAPathWhicheverOrderTheTailHoldsThemIn() throws {
        let now = Date()
        try writeJournal("A", lines: [
            try line(entry(1, "A", "notes.txt", sha: "v1", at: now.addingTimeInterval(-60))),
            try line(entry(2, "A", "notes.txt", sha: "v2", at: now, previous: "v1")),
            try line(entry(3, "A", "notes.txt", sha: "v3", at: now.addingTimeInterval(-30), previous: "v2")),
        ])

        let read = store.readJournals(cached: nil)

        XCTAssertEqual(read.index.files[VaultPath.key("notes.txt")]?.sha256, "v2",
                       "a wall clock that went backwards must not beat causality")
        XCTAssertEqual(read.index.files, fullState().files)
    }

    func testADeletionInTheTailMovesAPathToTheTombstones() throws {
        try store.append([entry(1, "A", "alpha.txt", sha: "v1")], machineID: "A")
        let first = store.readJournals(cached: nil)
        XCTAssertNotNil(first.index.files["alpha.txt"])

        try store.append([entry(2, "A", "alpha.txt", sha: "v1", kind: .delete)], machineID: "A")
        let second = store.readJournals(cached: first.index)

        XCTAssertNil(second.index.files["alpha.txt"])
        XCTAssertNotNil(second.index.tombstones["alpha.txt"])
        XCTAssertEqual(second.index.tombstones, fullState().tombstones)
    }

    // MARK: - Tails that are not whole

    /// A crash mid-append leaves a last line with no newline. It is ignored, as `loadEntries`
    /// ignores it — but it must also not be *consumed*, or the entry the line would have described
    /// is lost if the line is ever completed.
    func testATornTailIsIgnoredAndStillReadOnceItIsCompleted() throws {
        try store.append([entry(1, "A", "alpha.txt")], machineID: "A")
        let first = store.readJournals(cached: nil)
        let consumed = first.index.consumed["A.jsonl"]

        let whole = try line(entry(2, "A", "beta.txt"))
        let tear = String(whole.prefix(whole.count / 2))
        try appendRaw("A", tear)

        let torn = store.readJournals(cached: first.index)
        XCTAssertEqual(torn.entries, [])
        XCTAssertEqual(torn.errors, [], "a tear is expected after a crash, not corruption")
        XCTAssertEqual(torn.index.consumed["A.jsonl"], consumed, "the torn bytes are not consumed")

        try appendRaw("A", String(whole.dropFirst(whole.count / 2)) + "\n")

        let completed = store.readJournals(cached: torn.index)
        XCTAssertEqual(completed.errors, [])
        XCTAssertEqual(completed.entries.map(\.path), ["beta.txt"])
        XCTAssertEqual(completed.index.files["beta.txt"]?.sha256, "sha-beta.txt")
    }

    /// A line that cannot be decoded is real corruption, and it has to be named by the number it
    /// has in the file — an incremental read cannot count from the start again to find it.
    func testAnUnreadableLineInAMiddleIsReportedWithTheNumberItHasInTheFile() throws {
        try writeJournal("A", lines: [
            try line(entry(1, "A", "alpha.txt")),
            try line(entry(2, "A", "beta.txt")),
            try line(entry(3, "A", "gamma.txt")),
        ])
        let first = store.readJournals(cached: nil)

        try appendRaw("A", "{\"seq\":9,\"machine\":\"torn-by-hand\"}\n")
        try store.append([entry(4, "A", "delta.txt")], machineID: "A")

        let second = store.readJournals(cached: first.index)

        XCTAssertEqual(second.errors, ["journal A.jsonl has an unreadable line 4"])
        XCTAssertEqual(second.entries.map(\.path).sorted(), ["delta.txt"])
    }

    // MARK: - Files that are not what the cache says

    func testAJournalShorterThanWhatWasReadIsReadAgainFromTheStart() throws {
        try store.append([
            entry(1, "A", "alpha.txt"),
            entry(2, "A", "beta.txt"),
            entry(3, "A", "gamma.txt"),
        ], machineID: "A")
        let first = store.readJournals(cached: nil)
        XCTAssertEqual(first.index.files.count, 3)

        // A restored `.neodrop`, or a hand-edit: the file is not the one that was read.
        try writeJournal("A", lines: [try line(entry(1, "A", "alpha.txt"))])

        let after = store.readJournals(cached: first.index)

        XCTAssertTrue(after.rebuilt)
        XCTAssertEqual(after.index.files.keys.sorted(), ["alpha.txt"])
        XCTAssertEqual(after.index.files, fullState().files, "nothing of the old file survives")
    }

    func testAJournalThatDisappearedTakesItsEntriesWithIt() throws {
        try store.append([entry(1, "A", "alpha.txt")], machineID: "A")
        try store.append([entry(1, "B", "beta.txt")], machineID: "B")
        let first = store.readJournals(cached: nil)
        XCTAssertEqual(first.index.files.count, 2)

        try FileManager.default.removeItem(at: store.journalURL(machine: "A"))
        let after = store.readJournals(cached: first.index)

        XCTAssertTrue(after.rebuilt, "a journal that is gone cannot be accounted for incrementally")
        XCTAssertEqual(after.index.files.keys.sorted(), ["beta.txt"])
    }

    func testAJournalThatRewroteItsPrefixIsReadAgain() throws {
        try store.append([entry(1, "A", "alpha.txt", sha: "one"), entry(2, "A", "beta.txt", sha: "two")], machineID: "A")
        let first = store.readJournals(cached: nil)

        // Same shape, different content, and longer than before: an append it is not.
        try writeJournal("A", lines: [
            try line(entry(1, "A", "alpha.txt", sha: "replaced")),
            try line(entry(2, "A", "beta.txt", sha: "two")),
            try line(entry(3, "A", "gamma.txt", sha: "three")),
        ])

        let after = store.readJournals(cached: first.index)

        XCTAssertTrue(after.rebuilt)
        XCTAssertEqual(after.index.files["alpha.txt"]?.sha256, "replaced")
    }

    func testAnIndexFromAnotherBuildIsNotTrusted() throws {
        try store.append([entry(1, "A", "alpha.txt")], machineID: "A")
        var index = JournalIndex(formatVersion: JournalIndex.currentFormatVersion + 1)
        index.files["ghost.txt"] = entry(9, "Z", "ghost.txt")

        let read = store.readJournals(cached: index)

        XCTAssertTrue(read.rebuilt)
        XCTAssertNil(read.index.files["ghost.txt"])
        XCTAssertEqual(read.index.files, fullState().files)
    }

    // MARK: - The sequence and the retention window

    func testTheSequenceFromTheIndexIsTheOneAFullReadWouldGive() throws {
        try store.append([entry(1, "A", "alpha.txt"), entry(2, "A", "beta.txt")], machineID: "A")
        try store.append([entry(1, "B", "gamma.txt")], machineID: "B")
        var index = store.readJournals(cached: nil).index

        try store.append([entry(3, "A", "delta.txt")], machineID: "A")
        index = store.readJournals(cached: index).index

        let all = store.loadEntries().entries
        for machine in ["A", "B"] {
            XCTAssertEqual(index.nextSequence(machineID: machine), store.nextSequence(machineID: machine))
            XCTAssertEqual(index.nextSequence(machineID: machine), VaultSync.nextSequence(in: all, machineID: machine))
        }
        XCTAssertEqual(index.nextSequence(machineID: "never-written"), 1)
    }

    /// A clock that stepped backwards gives a higher sequence an earlier timestamp, so the entry
    /// that wins "newest for this path" can be the lower-numbered one. The next number written must
    /// still be past every sequence the machine has used, or two entries end up sharing one.
    func testTheSequenceAdvancesPastAnEntryThatLostThePathToANewerOne() throws {
        let now = Date()
        try writeJournal("A", lines: [
            try line(entry(5, "A", "alpha.txt", sha: "new", at: now)),
            try line(entry(6, "A", "alpha.txt", sha: "old", at: now.addingTimeInterval(-60))),
        ])

        let read = store.readJournals(cached: nil)

        XCTAssertEqual(read.index.files["alpha.txt"]?.sha256, "new")
        XCTAssertEqual(read.index.nextSequence(machineID: "A"), 7)
        XCTAssertEqual(read.index.nextSequence(machineID: "A"), store.nextSequence(machineID: "A"))
    }

    /// Retention keeps the content any entry inside the window could still be asked for. Entries
    /// older than that can never be, and are the only thing dropped — so the window, and not the
    /// vault's history, is what a pass has to hold.
    func testTheIndexKeepsTheRetentionWindowAndNothingOlder() throws {
        let now = Date()
        let old = now.addingTimeInterval(-DeleteRecord.retention - 86_400)
        try writeJournal("A", lines: [
            try line(entry(1, "A", "old.txt", sha: "old-sha", at: old, previous: "older-sha")),
            try line(entry(2, "A", "new.txt", sha: "new-sha", at: now, previous: "previous-sha")),
        ])

        let read = store.readJournals(cached: nil, now: now)

        XCTAssertEqual(read.index.recent.map(\.sha256).sorted(), ["new-sha"])
        let kept = store.retainableVersions(from: read.index.recent, within: DeleteRecord.retention, now: now)
        XCTAssertEqual(kept, ["new-sha", "previous-sha"])
        XCTAssertEqual(
            kept,
            store.retainableVersions(from: store.loadEntries().entries, within: DeleteRecord.retention, now: now),
            "the same set a full read would have produced"
        )
    }

    /// The old entry is still part of the tree's state; only retention forgets it.
    func testAnEntryOutsideTheWindowStillDecidesTheTreesState() throws {
        let now = Date()
        let old = now.addingTimeInterval(-DeleteRecord.retention - 86_400)
        try writeJournal("A", lines: [
            try line(entry(1, "A", "kept.txt", sha: "old-sha", at: old)),
        ])

        let read = store.readJournals(cached: nil, now: now)

        XCTAssertEqual(read.index.recent, [])
        XCTAssertEqual(read.index.files["kept.txt"]?.sha256, "old-sha")
    }

    // MARK: - On disk

    func testTheIndexOnDiskKeepsMillisecondsOfTheEntriesItHolds() throws {
        let stamp = Date(timeIntervalSince1970: 1_760_000_000.123)
        try store.append([entry(1, "A", "alpha.txt", at: stamp)], machineID: "A")
        let read = store.readJournals(cached: nil)
        let decoded = try XCTUnwrap(read.index.files["alpha.txt"])
        XCTAssertEqual(decoded.at, stamp, "the journal keeps milliseconds, so a decoded entry has them")

        let paths = StorePaths(base: root.appendingPathComponent("state"))
        try paths.ensureDirectories()
        let vaultID = UUID()
        try JournalIndexStore(paths: paths).save(read.index, vaultID: vaultID)
        let loaded = try XCTUnwrap(JournalIndexStore(paths: paths).load(vaultID: vaultID))

        XCTAssertEqual(loaded, read.index)
        XCTAssertEqual(loaded.files["alpha.txt"]?.at, stamp,
                       "whole seconds here would make a cached entry look newer than a later one")
    }

    func testAnIndexForAVaultNeverReadIsNil() throws {
        let paths = StorePaths(base: root.appendingPathComponent("state"))
        XCTAssertNil(JournalIndexStore(paths: paths).load(vaultID: UUID()))
    }
}
