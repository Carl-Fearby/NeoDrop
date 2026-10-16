import XCTest
@testable import NeoDropCore

/// Two machines, one share: the shape of the product, tested as two *separate* installs with their
/// own state directories, their own identities and their own local folders — exactly like two Macs
/// pointed at the same vault.
final class VaultSandbox {
    struct Machine {
        let name: String
        let id: UUID
        let state: StorePaths
        let local: URL
    }

    let root: URL
    /// The share: the live tree plus the hidden `.neodrop/` metadata.
    let vault: URL
    private(set) var machines: [Machine] = []

    init(name: String, machineNames: [String] = ["Machine A", "Machine B", "Machine C"], vaultName: String = "Shared") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("neodrop-vault-\(name)-\(UUID().uuidString)")
        vault = root.appendingPathComponent("NAS/\(vaultName)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        for machineName in machineNames {
            let slug = machineName.replacingOccurrences(of: " ", with: "-")
            let local = root.appendingPathComponent("\(slug)/Folder")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            let state = StorePaths(base: root.appendingPathComponent("\(slug)/state"))
            try state.ensureDirectories()
            // Fix the identity so conflicted copy names are predictable in assertions.
            let identity = MachineIdentity(id: UUID(), name: machineName)
            try MachineIdentityStore(paths: state).save(identity)
            machines.append(Machine(name: machineName, id: identity.id, state: state, local: local))
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func link(_ index: Int) -> VaultLink {
        VaultLink(id: machines[index].id, name: "Shared", vaultPath: vault.path, localPath: machines[index].local.path)
    }

    func engine(_ index: Int) -> VaultSync { VaultSync(paths: machines[index].state) }

    /// The mirror engine on the same state directory: the app uses it for the deleted-files view,
    /// including for deletions a two-way folder applied.
    func engineForMirror(_ index: Int) -> MirrorEngine { MirrorEngine(paths: machines[index].state) }

    func config(allowBulkDeletions: Bool = false) -> AppConfig {
        var config = AppConfig()
        config.allowBulkDeletions = allowBulkDeletions
        return config
    }

    @discardableResult
    func sync(_ index: Int, allowBulkDeletions: Bool = false) async throws -> VaultSyncSummary {
        try unwrap(await engine(index).reconcile(link: link(index), config: config(allowBulkDeletions: allowBulkDeletions)))
    }

    // MARK: - Local folder

    @discardableResult
    func write(_ contents: String, machine: Int, to relativePath: String) throws -> URL {
        let url = machines[machine].local.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func delete(machine: Int, _ relativePath: String) throws {
        try FileManager.default.removeItem(at: machines[machine].local.appendingPathComponent(relativePath))
    }

    func exists(machine: Int, _ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: machines[machine].local.appendingPathComponent(relativePath).path)
    }

    func read(machine: Int, _ relativePath: String) throws -> String {
        try String(contentsOf: machines[machine].local.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every file in a machine's folder, relative.
    ///
    /// Hidden files are included on purpose: vault mode syncs them, so `.env` is as real as
    /// `notes.txt` here. `.neodrop-trash` is bookkeeping and is filtered out below wherever it sits.
    func localFiles(machine: Int) -> [String] {
        files(under: machines[machine].local).filter { !$0.hasPrefix(DeleteRecord.trashDirectoryName + "/") }
    }

    func trashFiles(machine: Int) -> [String] {
        files(under: machines[machine].local.appendingPathComponent(DeleteRecord.trashDirectoryName))
    }

    // MARK: - The share

    func vaultExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: vault.appendingPathComponent(relativePath).path)
    }

    func vaultRead(_ relativePath: String) throws -> String {
        try String(contentsOf: vault.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The live tree on the share: what a person browsing the NAS sees. Hidden files included
    /// (they are part of the tree), `.neodrop/` excluded (it is the vault's own metadata).
    var vaultFiles: [String] {
        files(under: vault).filter {
            !$0.hasPrefix(VaultStore.metadataDirectoryName + "/") && $0 != VaultStore.metadataDirectoryName
        }
    }

    var vaultState: VaultState {
        let store = VaultStore(root: vault)
        return store.state(from: store.loadEntries().entries)
    }

    var retainedVersions: [String] {
        let versions = vault.appendingPathComponent("\(VaultStore.metadataDirectoryName)/versions")
        return ((try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    func journalLines(machine: Int) -> [String] {
        let url = vault.appendingPathComponent("\(VaultStore.metadataDirectoryName)/journals/\(machines[machine].id.uuidString).jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func appendToJournal(machine: Int, raw: String) throws {
        let url = vault.appendingPathComponent("\(VaultStore.metadataDirectoryName)/journals/\(machines[machine].id.uuidString).jsonl")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(raw.utf8))
    }

    private func files(under root: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator where !FileMeta.isDirectory(url) {
            let relative = Scanner.relativePath(of: url, under: root)
            if relative.hasSuffix(".DS_Store") { continue }
            result.append(relative)
        }
        return result.sorted()
    }
}

final class VaultSyncTests: XCTestCase {
    private var sandbox: VaultSandbox!

    override func setUpWithError() throws {
        sandbox = try VaultSandbox(name: "sync")
    }

    override func tearDown() {
        sandbox = nil
    }

    // MARK: - Publishing and seeding

    func testFirstMachinePublishesItsFolderAndCreatesTheVault() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try sandbox.write("nested", machine: 0, to: "Documents/2026/plans.txt")
        try sandbox.write("secret", machine: 0, to: ".env")

        let summary = try await sandbox.sync(0)

        XCTAssertEqual(summary.uploaded, 3)
        XCTAssertEqual(summary.downloaded, 0)
        XCTAssertFalse(summary.isDegraded)
        XCTAssertEqual(summary.phase, .finished)
        XCTAssertEqual(sandbox.vaultFiles, [".env", "Documents/2026/plans.txt", "alpha.txt"])
        XCTAssertEqual(try sandbox.vaultRead("alpha.txt"), "alpha")
        XCTAssertTrue(sandbox.vaultExists("\(VaultStore.metadataDirectoryName)/vault.json"))
        XCTAssertEqual(sandbox.journalLines(machine: 0).count, 3)
        // Hidden files are part of the tree in vault mode: a tool that dropped `.env` would be a trap.
        XCTAssertTrue(sandbox.vaultFiles.contains(".env"))
    }

    func testSecondSyncPublishesNothing() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await sandbox.sync(0)

        let second = try await sandbox.sync(0)

        XCTAssertEqual(second.uploaded, 0)
        XCTAssertEqual(second.downloaded, 0)
        XCTAssertEqual(second.upToDate, 1)
        XCTAssertEqual(sandbox.journalLines(machine: 0).count, 1, "an unchanged file is not re-announced")
    }

    /// The requirement in one test: a new machine gets the content from the share.
    func testNewMachineSeedsItselfFromTheVault() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try sandbox.write("beta", machine: 0, to: "Photos/README.txt")
        try await sandbox.sync(0)

        let seeded = try await sandbox.sync(1)

        XCTAssertTrue(seeded.seeded)
        XCTAssertEqual(seeded.downloaded, 2)
        XCTAssertEqual(seeded.uploaded, 0)
        XCTAssertEqual(try sandbox.read(machine: 1, "alpha.txt"), "alpha")
        XCTAssertEqual(try sandbox.read(machine: 1, "Photos/README.txt"), "beta")
        XCTAssertEqual(sandbox.localFiles(machine: 1), ["Photos/README.txt", "alpha.txt"])
    }

    func testThreeMachinesAllHoldTheSameTree() async throws {
        sandbox = try VaultSandbox(name: "three")
        try sandbox.write("one", machine: 0, to: "one.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)
        try await sandbox.sync(2)

        try sandbox.write("two", machine: 1, to: "two.txt")
        try await sandbox.sync(1)
        try await sandbox.sync(2)
        try await sandbox.sync(0)

        XCTAssertEqual(sandbox.localFiles(machine: 0), sandbox.localFiles(machine: 1))
        XCTAssertEqual(sandbox.localFiles(machine: 1), sandbox.localFiles(machine: 2))
        XCTAssertEqual(sandbox.localFiles(machine: 0), ["one.txt", "two.txt"])
    }

    // MARK: - Converging after changes on either side

    func testEditOnOneMachineReachesTheOther() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)

        try sandbox.write("alpha edited on A", machine: 0, to: "alpha.txt")
        try await sandbox.sync(0)

        let applied = try await sandbox.sync(1)
        XCTAssertEqual(applied.downloaded, 1)
        XCTAssertEqual(try sandbox.read(machine: 1, "alpha.txt"), "alpha edited on A")
    }

    func testEditOnTheOtherMachineComesBack() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)

        try sandbox.write("edited on B", machine: 1, to: "alpha.txt")
        try await sandbox.sync(1)

        let applied = try await sandbox.sync(0)
        XCTAssertEqual(applied.downloaded, 1)
        XCTAssertEqual(try sandbox.read(machine: 0, "alpha.txt"), "edited on B")
        XCTAssertEqual(try sandbox.vaultRead("alpha.txt"), "edited on B")
    }

    /// Regression: with whole-second timestamps two changes made moments apart compared *equal*,
    /// and the merge then ordered them by machine id — so this machine's older content won, the
    /// newer edit was quietly reverted on the share, and nothing reported an error.
    func testBackToBackEditsWithinTheSameSecondAllPropagate() async throws {
        try sandbox.write("v0", machine: 0, to: "notes.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)

        for step in 1...5 {
            try sandbox.write("from B \(step)", machine: 1, to: "notes.txt")
            let published = try await sandbox.sync(1)
            XCTAssertEqual(published.uploaded, 1, "step \(step): B's edit must reach the vault")

            let applied = try await sandbox.sync(0)
            XCTAssertEqual(applied.downloaded, 1, "step \(step): A must take B's edit")
            XCTAssertFalse(applied.downloaded == 0 && !applied.repairs.isEmpty, "step \(step): the share must not be reverted")
            XCTAssertEqual(try sandbox.read(machine: 0, "notes.txt"), "from B \(step)")
            XCTAssertEqual(try sandbox.vaultRead("notes.txt"), "from B \(step)")
            XCTAssertEqual(applied.conflicts, [], "sequential edits are not conflicts")
        }

        for step in 1...5 {
            try sandbox.write("from A \(step)", machine: 0, to: "notes.txt")
            try await sandbox.sync(0)
            let applied = try await sandbox.sync(1)
            XCTAssertEqual(try sandbox.read(machine: 1, "notes.txt"), "from A \(step)")
            XCTAssertEqual(applied.conflicts, [])
        }

        XCTAssertEqual(sandbox.localFiles(machine: 0), sandbox.localFiles(machine: 1))
        XCTAssertEqual(sandbox.vaultFiles, ["notes.txt"], "no conflicted copies were needed")
    }

    /// The tie-break when two entries really do share an instant: the one written on top of the
    /// other's content is the later one, whatever the clocks said.
    func testEntriesOnTopOfEachOtherOrderByCausalityWhenTimestampsTie() {
        let instant = Date(timeIntervalSince1970: 1_760_000_000)
        let original = JournalEntry(
            seq: 1, machine: "aaaa", machineName: "A", at: instant,
            path: "notes.txt", kind: .create, size: 5, sha256: "sha-original"
        )
        let edit = JournalEntry(
            seq: 1, machine: "zzzz", machineName: "Z", at: instant,
            path: "notes.txt", kind: .update, size: 4, sha256: "sha-edit", previousSha256: "sha-original"
        )

        XCTAssertTrue(JournalEntry.precedes(original, edit), "the edit builds on the original, so it is later")
        XCTAssertFalse(JournalEntry.precedes(edit, original))

        let state = VaultStore(root: URL(fileURLWithPath: NSTemporaryDirectory())).state(from: [edit, original])
        XCTAssertEqual(state.files["notes.txt"]?.sha256, "sha-edit", "the edit wins the merge")
    }

    func testNewFileOnEitherMachineAppearsEverywhere() async throws {
        try await sandbox.sync(0)
        try await sandbox.sync(1)

        try sandbox.write("made on B", machine: 1, to: "Documents/from-b.txt")
        try await sandbox.sync(1)
        try await sandbox.sync(0)

        XCTAssertEqual(try sandbox.read(machine: 0, "Documents/from-b.txt"), "made on B")
        XCTAssertTrue(sandbox.vaultExists("Documents/from-b.txt"))
    }

    // MARK: - Conflicts

    func testSimultaneousEditsKeepBothVersionsOnBothMachines() async throws {
        try sandbox.write("original", machine: 0, to: "notes.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)

        // Both machines edit the same file before either sees the other: the case that makes a
        // naive two-way sync destroy data.
        try sandbox.write("version from machine A", machine: 0, to: "notes.txt")
        try sandbox.write("version from machine B", machine: 1, to: "notes.txt")
        try await sandbox.sync(0)

        let conflicted = try await sandbox.sync(1)

        XCTAssertEqual(conflicted.conflicts, ["notes.txt"])
        // B keeps the vault's version under the original name and its own beside it.
        XCTAssertEqual(try sandbox.read(machine: 1, "notes.txt"), "version from machine A")
        let conflictedName = try XCTUnwrap(
            sandbox.vaultFiles.first { $0.contains("conflicted copy") },
            "the losing version should be kept as a conflicted copy"
        )
        XCTAssertTrue(conflictedName.contains("Machine B"), "the copy is named after the machine that lost: \(conflictedName)")
        XCTAssertEqual(try sandbox.read(machine: 1, conflictedName), "version from machine B")
        XCTAssertEqual(try sandbox.vaultRead(conflictedName), "version from machine B")

        // And the machine that won the name learns about the copy, so both sides converge.
        try await sandbox.sync(0)
        XCTAssertEqual(try sandbox.read(machine: 0, conflictedName), "version from machine B")
        XCTAssertEqual(sandbox.localFiles(machine: 0), sandbox.localFiles(machine: 1))
    }

    func testConflictedCopiesDoNotCollideOnRepeat() async throws {
        try sandbox.write("original", machine: 0, to: "notes.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)

        for attempt in 0..<2 {
            try sandbox.write("A attempt \(attempt)", machine: 0, to: "notes.txt")
            try sandbox.write("B attempt \(attempt)", machine: 1, to: "notes.txt")
            try await sandbox.sync(0)
            try await sandbox.sync(1)
        }

        let copies = sandbox.vaultFiles.filter { $0.contains("conflicted copy") }
        XCTAssertEqual(copies.count, 2, "each conflict keeps its own copy: \(copies)")
        XCTAssertEqual(Set(copies).count, 2)
    }

    /// Pointing a fresh machine at a folder that already has files is the ordinary "I already have
    /// this stuff" case. Both sides must survive it.
    func testExistingContentOnANewMachineIsKeptAlongsideTheVaults() async throws {
        try sandbox.write("from the vault", machine: 0, to: "shared.txt")
        try sandbox.write("only in the vault", machine: 0, to: "vault-only.txt")
        try await sandbox.sync(0)

        // Machine B already has a *different* shared.txt and a file the vault has never seen.
        try sandbox.write("already on B", machine: 1, to: "shared.txt")
        try sandbox.write("only on B", machine: 1, to: "b-only.txt")

        let summary = try await sandbox.sync(1)

        XCTAssertEqual(summary.conflicts, ["shared.txt"])
        XCTAssertEqual(try sandbox.read(machine: 1, "shared.txt"), "from the vault")
        XCTAssertEqual(try sandbox.read(machine: 1, "b-only.txt"), "only on B")
        XCTAssertTrue(sandbox.vaultFiles.contains("vault-only.txt"))
        let copy = try XCTUnwrap(sandbox.vaultFiles.first { $0.contains("conflicted copy") })
        XCTAssertEqual(try sandbox.read(machine: 1, copy), "already on B")
    }

    // MARK: - Deletions

    func testDeletionOnOneMachineRemovesItEverywhereAndStaysRecoverable() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try sandbox.write("keep", machine: 0, to: "keep.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)
        let digest = try Hashing.sha256(ofFileAt: sandbox.machines[1].local.appendingPathComponent("alpha.txt"))

        try sandbox.delete(machine: 0, "alpha.txt")
        let published = try await sandbox.sync(0)

        XCTAssertEqual(published.localDeletionsPublished, 1)
        XCTAssertFalse(sandbox.vaultExists("alpha.txt"), "the share's live tree no longer has it")
        XCTAssertEqual(sandbox.retainedVersions, [digest], "its bytes are retained, not destroyed")

        let applied = try await sandbox.sync(1)

        XCTAssertEqual(applied.remoteDeletionsApplied, 1)
        XCTAssertFalse(sandbox.exists(machine: 1, "alpha.txt"))
        XCTAssertEqual(sandbox.trashFiles(machine: 1), ["alpha.txt"], "machine B kept its copy in the trash")
        XCTAssertEqual(try String(contentsOf: sandbox.machines[1].local
            .appendingPathComponent("\(DeleteRecord.trashDirectoryName)/alpha.txt"), encoding: .utf8), "alpha")
        XCTAssertTrue(sandbox.exists(machine: 1, "keep.txt"), "everything else is untouched")

        // A deletion is not undone by the machine that still has the file: the tombstone wins.
        let again = try await sandbox.sync(1)
        XCTAssertEqual(again.uploaded, 0)
        XCTAssertFalse(sandbox.vaultExists("alpha.txt"))
        XCTAssertEqual(again.errors, [])
    }

    func testDeletingAHiddenFilePropagatesToo() async throws {
        try sandbox.write("secret", machine: 0, to: ".env")
        try await sandbox.sync(0)
        try await sandbox.sync(1)
        try sandbox.delete(machine: 0, ".env")

        try await sandbox.sync(0)
        try await sandbox.sync(1)

        XCTAssertFalse(sandbox.exists(machine: 1, ".env"))
        XCTAssertEqual(sandbox.trashFiles(machine: 1), [".env"])
    }

    /// A file the others deleted but this machine edited in the meantime must not be lost.
    func testEditedFileDeletedElsewhereIsKeptAsAConflictedCopy() async throws {
        try sandbox.write("original", machine: 0, to: "notes.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)

        try sandbox.delete(machine: 0, "notes.txt")
        try await sandbox.sync(0)
        try sandbox.write("B edited it after the delete", machine: 1, to: "notes.txt")

        let summary = try await sandbox.sync(1)

        XCTAssertEqual(summary.conflicts, ["notes.txt"])
        XCTAssertFalse(sandbox.exists(machine: 1, "notes.txt"), "the deletion still applies to the original name")
        let copy = try XCTUnwrap(sandbox.vaultFiles.first { $0.contains("conflicted copy") })
        XCTAssertEqual(try sandbox.read(machine: 1, copy), "B edited it after the delete")
        XCTAssertEqual(try sandbox.vaultRead(copy), "B edited it after the delete")
    }

    func testDeletionGuardRefusesToPublishAWholeFolderDisappearing() async throws {
        for index in 0..<40 { try sandbox.write("payload \(index)", machine: 0, to: "file-\(index).txt") }
        try await sandbox.sync(0)
        for index in 0..<40 { try sandbox.delete(machine: 0, "file-\(index).txt") }

        let refused = try await sandbox.sync(0)

        XCTAssertEqual(refused.localDeletionsPublished, 0)
        XCTAssertTrue(refused.isDegraded)
        XCTAssertTrue(refused.errors.contains { $0.contains("Refused to publish") }, refused.errors.joined(separator: "; "))
        XCTAssertEqual(sandbox.vaultFiles.count, 40, "the share still holds every file")

        // Allowed explicitly, the same run goes through.
        let allowed = try await sandbox.sync(0, allowBulkDeletions: true)
        XCTAssertEqual(allowed.localDeletionsPublished, 40)
        XCTAssertEqual(sandbox.vaultFiles, [])
        XCTAssertEqual(sandbox.retainedVersions.count, 40, "every one of them is recoverable")
    }

    func testRemoteBulkDeletionIsHeldBackOnTheReceivingMachine() async throws {
        for index in 0..<40 { try sandbox.write("payload \(index)", machine: 0, to: "file-\(index).txt") }
        try await sandbox.sync(0)
        try await sandbox.sync(1)
        for index in 0..<40 { try sandbox.delete(machine: 0, "file-\(index).txt") }
        try await sandbox.sync(0, allowBulkDeletions: true)

        let held = try await sandbox.sync(1)

        XCTAssertEqual(held.remoteDeletionsApplied, 0)
        XCTAssertTrue(held.errors.contains { $0.contains("Held back") }, held.errors.joined(separator: "; "))
        XCTAssertEqual(sandbox.localFiles(machine: 1).count, 40, "nothing was removed from this machine")

        let applied = try await sandbox.sync(1, allowBulkDeletions: true)
        XCTAssertEqual(applied.remoteDeletionsApplied, 40)
        XCTAssertEqual(sandbox.localFiles(machine: 1), [])
        XCTAssertEqual(sandbox.trashFiles(machine: 1).count, 40, "and all forty are in this machine's trash")
    }

    // MARK: - The share is just files

    func testVaultStaysBrowsableAndRepairsItselfFromAMachineThatHasTheBytes() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try sandbox.write("nested", machine: 0, to: "Documents/plans.txt")
        try await sandbox.sync(0)

        // The share is the live tree: real files, real folders, no encoding.
        XCTAssertEqual(try sandbox.vaultRead("Documents/plans.txt"), "nested")
        XCTAssertEqual(sandbox.vaultFiles, ["Documents/plans.txt", "alpha.txt"])

        // Someone deletes a file straight off the share. Both sides "agree" on the content, so
        // without the cheap size check this would never be noticed by a sync again.
        try FileManager.default.removeItem(at: sandbox.vault.appendingPathComponent("alpha.txt"))
        let repaired = try await sandbox.sync(0)

        XCTAssertEqual(repaired.repairs, ["alpha.txt"])
        XCTAssertTrue(sandbox.vaultExists("alpha.txt"))
        XCTAssertEqual(try sandbox.vaultRead("alpha.txt"), "alpha")
    }

    /// The vault is a folder on the share, so a person may put a file in it with Finder. It has to
    /// reach every machine — a share that silently ignores what is dropped into it is not a share.
    func testFilePlacedInTheVaultByHandIsAdoptedAndReachesEveryMachine() async throws {
        try sandbox.write("from A", machine: 0, to: "a.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)

        // Someone drops a folder of files straight onto the share.
        let dropped = sandbox.vault.appendingPathComponent("From Finder/hand-typed.txt")
        try FileManager.default.createDirectory(at: dropped.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "typed straight onto the NAS".write(to: dropped, atomically: true, encoding: .utf8)

        let adoptee = try await sandbox.sync(1)
        XCTAssertEqual(adoptee.adoptedInVault, 1)
        XCTAssertEqual(adoptee.downloaded, 1, "the machine that adopted it takes it too")
        XCTAssertEqual(try sandbox.read(machine: 1, "From Finder/hand-typed.txt"), "typed straight onto the NAS")

        let firstMachine = try await sandbox.sync(0)
        XCTAssertEqual(firstMachine.adoptedInVault, 0, "only one machine adopts it; everyone else receives it")
        XCTAssertEqual(try sandbox.read(machine: 0, "From Finder/hand-typed.txt"), "typed straight onto the NAS")
        XCTAssertEqual(sandbox.localFiles(machine: 0), sandbox.localFiles(machine: 1))

        // And it is adopted once, not announced again on every sync.
        let again = try await sandbox.sync(1)
        XCTAssertEqual(again.adoptedInVault, 0)
        XCTAssertEqual(again.uploaded, 0)
    }

    /// A file put back on the share at a path the journal says was deleted is new content, not a
    /// resurrected tombstone — and it must not sit there invisible forever.
    func testFilePlacedOnTheShareAtADeletedPathIsAdopted() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)
        try sandbox.delete(machine: 0, "alpha.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)

        // Somebody copies the old file back onto the share by hand.
        try "restored from a backup".write(
            to: sandbox.vault.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8
        )

        let summary = try await sandbox.sync(1)

        XCTAssertEqual(summary.adoptedInVault, 1)
        XCTAssertEqual(try sandbox.read(machine: 1, "alpha.txt"), "restored from a backup")
        // The bytes that *were* deleted are still in this machine's trash and still listed as
        // recoverable: the hand-placed file is different content, so nothing has been undone.
        XCTAssertEqual(sandbox.trashFiles(machine: 1), ["alpha.txt"])
        XCTAssertEqual(try String(contentsOf: sandbox.machines[1].local
            .appendingPathComponent("\(DeleteRecord.trashDirectoryName)/alpha.txt"), encoding: .utf8), "alpha")

        try await sandbox.sync(0)
        XCTAssertEqual(try sandbox.read(machine: 0, "alpha.txt"), "restored from a backup")
    }

    /// A hand-placed file must not be overwritten by a machine that happens to have its own version
    /// of that path but no journal entry for it: the bytes on the share are kept as a version.
    func testHandPlacedFileIsRetainedWhenAMachinePublishesOverIt() async throws {
        try sandbox.write("mine", machine: 0, to: "notes.txt")
        // The same path exists on the share with different content and no journal entry at all.
        try "theirs".write(to: sandbox.vault.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let summary = try await sandbox.sync(0)

        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(summary.versionsRetained, 1, "the bytes that were there are recoverable")
        XCTAssertEqual(try sandbox.vaultRead("notes.txt"), "mine")
        XCTAssertEqual(sandbox.retainedVersions, [try Hashing.sha256(of: "theirs")])
    }

    /// A folder the person just made in their working copy is not NeoDrop's to remove.
    func testAnEmptyFolderInTheWorkingCopyIsLeftAlone() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await sandbox.sync(0)
        let empty = sandbox.machines[0].local.appendingPathComponent("Just made this")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        try await sandbox.sync(0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
    }

    /// A deletion another Mac published moves the file into this machine's trash, and the app's
    /// recovery path has to be able to put it back — restoring it *and* republishing it, so the
    /// undelete reaches every machine rather than only this one.
    func testADeletionFromAnotherMachineIsRestorableAndTheUndeleteIsPublished() async throws {
        try sandbox.write("alpha", machine: 0, to: "Documents/alpha.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)
        let digest = try Hashing.sha256(ofFileAt: sandbox.machines[1].local.appendingPathComponent("Documents/alpha.txt"))

        // The other machine deletes it: this one applies the deletion into its trash.
        try sandbox.delete(machine: 0, "Documents/alpha.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)
        XCTAssertFalse(sandbox.exists(machine: 1, "Documents/alpha.txt"))
        XCTAssertEqual(sandbox.trashFiles(machine: 1), ["Documents/alpha.txt"])

        // The recovery path the app uses: the mirror engine's restore, which must accept this
        // machine's working copy as a destination even though it is not a one-way source folder.
        var config = sandbox.config()
        config.vaults = [sandbox.link(1)]
        let restored = try await sandbox.engineForMirror(1).restore(relativePath: "Documents/alpha.txt", config: config)

        XCTAssertTrue(PathIdentity.contains(sandbox.machines[1].local.appendingPathComponent("Documents"), restored))
        XCTAssertEqual(try sandbox.read(machine: 1, "Documents/alpha.txt"), "alpha")
        XCTAssertEqual(try Hashing.sha256(ofFileAt: restored), digest)
        XCTAssertEqual(sandbox.trashFiles(machine: 1), [], "the retained copy is given back")

        // And the next sync publishes it as new content, so the other machine gets it back too — the
        // restore is an undelete, not a copy kept beside a deletion that still stands.
        let published = try await sandbox.sync(1)
        XCTAssertEqual(published.uploaded, 1)
        XCTAssertEqual(published.undeleted, ["Documents/alpha.txt"])
        XCTAssertEqual(published.conflicts, [], "a restore is not a conflict")
        XCTAssertEqual(published.adoptedInVault, 0, "this machine wrote it, so it is not an adoption")
        XCTAssertEqual(sandbox.vaultFiles.filter { $0.contains("conflicted copy") }, [])
        try await sandbox.sync(0)
        XCTAssertEqual(try sandbox.read(machine: 0, "Documents/alpha.txt"), "alpha")
        XCTAssertEqual(sandbox.localFiles(machine: 0), sandbox.localFiles(machine: 1))
    }

    func testVaultFileTruncatedOnTheShareIsRestoredFromRetainedContent() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await sandbox.sync(0)
        // Machine B has it too, then the share's copy is truncated by a dropped connection.
        try await sandbox.sync(1)
        try "alp".write(to: sandbox.vault.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)

        let summary = try await sandbox.sync(0)
        XCTAssertEqual(summary.repairs, ["alpha.txt"])
        XCTAssertEqual(try sandbox.vaultRead("alpha.txt"), "alpha")
    }

    // MARK: - Journalling

    func testLongOfflineCatchUpResumesInBoundedBatchesAndConverges() async throws {
        let total = VaultSync.catchUpBatchSize + 23
        for index in 0..<total {
            try sandbox.write("payload \(index)", machine: 0, to: String(format: "file-%04d.txt", index))
        }
        let firstPublisherPass = try await sandbox.sync(0)
        XCTAssertTrue(firstPublisherPass.catchUpPending)
        let publisherRemainder = try await sandbox.sync(0)
        XCTAssertFalse(publisherRemainder.catchUpPending)

        let firstPass = try await sandbox.sync(1)
        XCTAssertEqual(firstPass.catchUpProcessed, VaultSync.catchUpBatchSize)
        XCTAssertTrue(firstPass.catchUpPending)
        XCTAssertEqual(sandbox.localFiles(machine: 1).count, VaultSync.catchUpBatchSize)

        // Recreate the engine to prove the page boundary is durable, not actor memory.
        let resumed = try await sandbox.sync(1)
        XCTAssertEqual(resumed.catchUpProcessed, 23, resumed.errors.joined(separator: "; "))
        XCTAssertFalse(resumed.catchUpPending)
        XCTAssertEqual(sandbox.localFiles(machine: 1).count, total)
        XCTAssertEqual(Set(sandbox.localFiles(machine: 1)), Set(sandbox.localFiles(machine: 0)))
        let vaultID = try XCTUnwrap(VaultStore(root: sandbox.vault).loadIdentity()?.id)
        let cursor = try XCTUnwrap(VaultCursorStore(paths: sandbox.machines[1].state).load(vaultID: vaultID))
        XCTAssertNil(cursor.catchUpAfter)
    }

    func testInterruptedCatchUpRetriesMissingVaultContentWithoutSkippingCheckpoint() async throws {
        let count = VaultSync.catchUpBatchSize + 23
        for index in 0..<count {
            try sandbox.write("payload \(index)", machine: 0, to: String(format: "file-%04d.txt", index))
        }
        let publisherFirstPass = try await sandbox.sync(0)
        XCTAssertTrue(publisherFirstPass.catchUpPending)
        let publisherRemainder = try await sandbox.sync(0)
        XCTAssertFalse(publisherRemainder.catchUpPending)

        let firstBatch = try await sandbox.sync(1)
        XCTAssertTrue(firstBatch.catchUpPending)
        XCTAssertEqual(sandbox.localFiles(machine: 1).count, VaultSync.catchUpBatchSize)
        let vaultID = try XCTUnwrap(VaultStore(root: sandbox.vault).loadIdentity()?.id)
        let cursorStore = VaultCursorStore(paths: sandbox.machines[1].state)
        let firstCursor = try XCTUnwrap(cursorStore.load(vaultID: vaultID))
        XCTAssertEqual(firstCursor.catchUpAfter, "file-0499.txt")

        // While B is behind the page cursor, A updates an unvisited file. B must retain the dirty
        // path checkpoint even after advancing the current page, then reconcile that path later.
        try sandbox.write("edited on A", machine: 0, to: "file-0500.txt")
        let published = try await sandbox.sync(0)
        XCTAssertEqual(published.uploaded, 1)
        let publisherRemainderAfterEdit = try await sandbox.sync(0)
        XCTAssertFalse(publisherRemainderAfterEdit.catchUpPending)

        let resumed = try await sandbox.sync(1)
        XCTAssertEqual(resumed.catchUpProcessed, 23)
        XCTAssertTrue(resumed.catchUpPending)
        XCTAssertEqual(try sandbox.read(machine: 1, "file-0500.txt"), "edited on A")
        let heldCursor = try XCTUnwrap(cursorStore.load(vaultID: vaultID))
        XCTAssertEqual(heldCursor.catchUpAfter, "file-0522.txt")
        XCTAssertEqual(heldCursor.catchUpDirtyPaths, ["file-0500.txt"])

        let retry = try await sandbox.sync(1)
        XCTAssertTrue(retry.errors.isEmpty, retry.errors.joined(separator: "; "))
        XCTAssertFalse(retry.catchUpPending)
        XCTAssertEqual(sandbox.localFiles(machine: 1).count, count)
        let finalCursor = try XCTUnwrap(cursorStore.load(vaultID: vaultID))
        XCTAssertNil(finalCursor.catchUpAfter)
    }

    /// A relaunch in the middle of a catch-up has to pick the walk up where the file left it.
    ///
    /// Every `sandbox.sync` builds a new engine, which is what a launch does, so these passes prove
    /// what the *cursor on disk* says rather than what an actor remembers. The app takes passes in a
    /// loop until the cursor clears (`AppModel.maxCatchUpPasses`), so that is what this does: the
    /// second pass must not lose the paths it had not read, and must not re-read the ones it had.
    /// That difference is the entire reason for keeping a cursor, and neither half of it is visible
    /// from a summary that only counted work.
    func testRelaunchingMidCatchUpResumesFromTheCursorWithoutRedoingTheWork() async throws {
        let total = VaultSync.catchUpBatchSize + 23
        for index in 0..<total {
            try sandbox.write("payload \(index)", machine: 0, to: String(format: "file-%04d.txt", index))
        }
        try await sandbox.sync(0)
        try await sandbox.sync(0)

        let firstRun = try await sandbox.sync(1)
        XCTAssertEqual(firstRun.downloaded, VaultSync.catchUpBatchSize)
        XCTAssertTrue(firstRun.catchUpPending)
        XCTAssertEqual(sandbox.localFiles(machine: 1).count, VaultSync.catchUpBatchSize)
        XCTAssertEqual(sandbox.journalLines(machine: 1).count, 0,
                       "applying another machine's content is not this machine publishing")

        // Quit and start again: a fresh engine, the same state directory.
        let resumed = try await sandbox.sync(1)
        XCTAssertEqual(resumed.downloaded, 23, "only the paths the cursor had not reached")
        XCTAssertEqual(resumed.upToDate, 0, "the paths before the cursor were not walked again")
        XCTAssertEqual(resumed.uploaded, 0, "and were not republished")
        XCTAssertEqual(resumed.errors, [])
        XCTAssertFalse(resumed.catchUpPending, "the walk is finished")
        XCTAssertEqual(sandbox.localFiles(machine: 1).count, total)
        XCTAssertEqual(sandbox.localFiles(machine: 1), sandbox.localFiles(machine: 0))

        // The bytes that moved are the remainder and nothing else: the 500 files the first pass
        // applied were left alone rather than hashed and written again.
        let remainderBytes = (VaultSync.catchUpBatchSize..<total).reduce(Int64(0)) { running, index in
            running + Int64("payload \(index)".utf8.count)
        }
        XCTAssertEqual(resumed.bytesDown, remainderBytes,
                       "moved \(resumed.bytesDown) bytes for a 23-file remainder")
        XCTAssertGreaterThan(resumed.bytesDown, 0, "the remainder really did move")

        // An idle pass afterwards moves nothing and pages nothing: a tree in agreement is settled
        // in one pass rather than re-walked a page at a time (see testASyncWithNothingToDoSettles
        // InOnePass), and every path still counts as agreed.
        let settled = try await sandbox.sync(1)
        XCTAssertEqual(settled.downloaded, 0)
        XCTAssertEqual(settled.uploaded, 0)
        XCTAssertEqual(settled.catchUpProcessed, 0, "nothing to walk, so nothing is paged")
        XCTAssertEqual(settled.upToDate, total)
        XCTAssertFalse(settled.catchUpPending)
        XCTAssertEqual(sandbox.localFiles(machine: 1).count, total)
        let vaultID = try XCTUnwrap(VaultStore(root: sandbox.vault).loadIdentity()?.id)
        let cursorStore = VaultCursorStore(paths: sandbox.machines[1].state)
        let settledCursor = try XCTUnwrap(cursorStore.load(vaultID: vaultID))
        XCTAssertNil(settledCursor.catchUpAfter)
        XCTAssertNotNil(settledCursor.catchUpJournalBytes, "the settled pass records what it saw")
    }

    /// A deletion is the other thing a cursor can walk past, and the more dangerous one: a file the
    /// page never revisits is a file the user deleted on one Mac that stays on the other for ever.
    /// One deletion behind the cursor (a path this machine has already applied) and one ahead of it
    /// (a path it has not reached) both have to land on this machine's next pass.
    func testADeletionBehindThePageCursorIsAppliedOnTheNextPass() async throws {
        let total = VaultSync.catchUpBatchSize + 23
        for index in 0..<total {
            try sandbox.write("payload \(index)", machine: 0, to: String(format: "file-%04d.txt", index))
        }
        try await sandbox.sync(0)
        try await sandbox.sync(0)

        let firstBatch = try await sandbox.sync(1)
        XCTAssertEqual(firstBatch.downloaded, VaultSync.catchUpBatchSize)
        XCTAssertEqual(sandbox.localFiles(machine: 1).count, VaultSync.catchUpBatchSize)
        let vaultID = try XCTUnwrap(VaultStore(root: sandbox.vault).loadIdentity()?.id)
        let cursorStore = VaultCursorStore(paths: sandbox.machines[1].state)
        XCTAssertEqual(try XCTUnwrap(cursorStore.load(vaultID: vaultID)).catchUpAfter, "file-0499.txt")

        // A deletes one file B already has (behind its cursor) and one it never reached (ahead of
        // it). Both are gone from the share, and both ways of being deleted have to reach B.
        let digest = try Hashing.sha256(ofFileAt: sandbox.machines[1].local.appendingPathComponent("file-0010.txt"))
        try sandbox.delete(machine: 0, "file-0010.txt")
        try sandbox.delete(machine: 0, "file-0500.txt")
        let published = try await sandbox.sync(0)
        XCTAssertEqual(published.localDeletionsPublished, 2)
        XCTAssertFalse(sandbox.vaultExists("file-0010.txt"))
        XCTAssertFalse(sandbox.vaultExists("file-0500.txt"))

        let resumed = try await sandbox.sync(1)
        XCTAssertEqual(resumed.remoteDeletionsApplied, 1,
                       "only the one this machine actually held: the other it had never downloaded")
        XCTAssertFalse(sandbox.exists(machine: 1, "file-0010.txt"))
        XCTAssertFalse(sandbox.exists(machine: 1, "file-0500.txt"))
        XCTAssertEqual(sandbox.trashFiles(machine: 1), ["file-0010.txt"])
        let trashed = DeleteRecord(relativePath: "file-0010.txt", sourcePath: "", size: 0, sha256: "")
            .trashURL(onReplicaRoot: sandbox.machines[1].local)
        XCTAssertEqual(try Hashing.sha256(ofFileAt: trashed), digest,
                       "the bytes are kept, so the deletion is recoverable on this machine too")

        // The page from the cursor covered everything left in the tree, and the deletion behind it
        // took a seat in the same batch — there was room, because a short page leaves room. Both
        // deletions are then carried one pass further, because the vault changed them while this
        // machine was mid-walk and a change that lands then is re-checked rather than assumed.
        let held = try XCTUnwrap(cursorStore.load(vaultID: vaultID))
        XCTAssertEqual(held.catchUpAfter, "file-0522.txt", "the page reached the end of the tree")
        XCTAssertEqual(held.catchUpDirtyPaths, ["file-0010.txt", "file-0500.txt"])
        XCTAssertTrue(resumed.catchUpPending)

        let settled = try await sandbox.sync(1)
        XCTAssertFalse(settled.catchUpPending)
        XCTAssertEqual(settled.remoteDeletionsApplied, 0, "an applied deletion is not applied again")
        XCTAssertEqual(settled.errors, [])
        XCTAssertNil(try XCTUnwrap(cursorStore.load(vaultID: vaultID)).catchUpAfter)
        XCTAssertEqual(sandbox.localFiles(machine: 1), sandbox.localFiles(machine: 0))
        XCTAssertEqual(sandbox.localFiles(machine: 1).count, total - 2)
    }

    /// The pattern the app uses: take bounded passes and fold them into one summary until the
    /// cursor clears. A folder of 2,000 files has to be *reported* as 2,000 files, not as whatever
    /// the last page happened to hold — the menu and the log are one sync to the user.
    func testFoldingThePassesOfOneSyncReportsTheWholeSync() async throws {
        let total = VaultSync.catchUpBatchSize + 5
        for index in 0..<total {
            try sandbox.write("payload \(index)", machine: 0, to: String(format: "file-%04d.txt", index))
        }

        let engine = sandbox.engine(0)
        var summary = try unwrap(await engine.reconcile(link: sandbox.link(0), config: sandbox.config()))
        var passes = 1
        while summary.catchUpPending {
            let next = try unwrap(await engine.reconcile(link: sandbox.link(0), config: sandbox.config()))
            summary.absorb(next)
            passes += 1
            XCTAssertLessThan(passes, 10, "a bounded walk must finish a 505-path tree in two passes")
        }

        XCTAssertEqual(passes, 2)
        XCTAssertEqual(summary.catchUpProcessed, total)
        XCTAssertEqual(summary.uploaded, total, "the folded summary counts the whole sync")
        XCTAssertEqual(summary.filesInVault, total)
        XCTAssertEqual(summary.errors, [])
        XCTAssertEqual(sandbox.vaultFiles.count, total)
    }

    func testTornJournalLineIsIgnoredAndTheChangeIsRepublished() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await sandbox.sync(0)

        // A crash mid-append: the last line is truncated JSON.
        try sandbox.appendToJournal(machine: 0, raw: "{\"seq\":99,\"machine\":\"x\"")

        let loaded = VaultStore(root: sandbox.vault).loadEntries()
        XCTAssertEqual(loaded.errors, [], "a torn tail is expected after a crash, not corruption")
        XCTAssertEqual(loaded.entries.count, 1)

        let after = try await sandbox.sync(0)
        XCTAssertEqual(after.errors, [])
        XCTAssertEqual(after.upToDate, 1)
        XCTAssertEqual(try sandbox.vaultRead("alpha.txt"), "alpha")
    }

    /// The sequence a pass writes into the journal has to be the one the journal would have given
    /// it. It is derived from the entries the pass already read rather than from a second full read
    /// of every journal — the most expensive thing a pass does, done twice, growing with the
    /// vault's history rather than its size.
    func testTheSequenceComesFromTheEntriesThePassAlreadyRead() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)
        try sandbox.write("beta", machine: 0, to: "beta.txt")
        try sandbox.write("gamma", machine: 1, to: "gamma.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)

        let store = VaultStore(root: sandbox.vault)
        let entries = store.loadEntries().entries
        for machine in sandbox.machines {
            let mine = entries.filter { $0.machine == machine.id.uuidString }.map(\.seq).sorted()
            if !mine.isEmpty {
                XCTAssertEqual(mine, Array(1...mine.count), "per-machine sequences stay consecutive")
            }
            XCTAssertEqual(
                VaultSync.nextSequence(in: entries, machineID: machine.id.uuidString),
                store.nextSequence(machineID: machine.id.uuidString),
                "the derived sequence must match what re-reading the journal answers"
            )
        }
    }

    func testBytesOnTheShareWithoutAJournalLineAreAnnouncedByTheNextSync() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        // Bytes copied to the share but the process died before the journal write — the failure
        // mode the ordering exists for. It must resolve to "publish again", never to a lost file.
        let destination = sandbox.vault.appendingPathComponent("alpha.txt")
        try "alpha".write(to: destination, atomically: true, encoding: .utf8)

        let summary = try await sandbox.sync(0)

        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(sandbox.journalLines(machine: 0).count, 1)
        XCTAssertEqual(sandbox.vaultState.files.count, 1)
    }

    func testJournalsFromBothMachinesMergeIntoOneTree() async throws {
        try sandbox.write("from A", machine: 0, to: "a.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)
        try sandbox.write("from B", machine: 1, to: "b.txt")
        try await sandbox.sync(1)

        XCTAssertEqual(sandbox.journalLines(machine: 0).count, 1, "a.txt only")
        XCTAssertEqual(sandbox.journalLines(machine: 1).count, 1, "b.txt only")
        XCTAssertTrue(sandbox.journalLines(machine: 1).allSatisfy { $0.contains("\"machine\"") })
        let state = sandbox.vaultState
        XCTAssertEqual(Set(state.files.values.map(\.path)), ["a.txt", "b.txt"])
        XCTAssertEqual(Set(state.files.values.map(\.machine)), [sandbox.machines[0].id.uuidString, sandbox.machines[1].id.uuidString])
    }

    // MARK: - Safety

    func testMissingLocalFolderIsRefusedRatherThanCreated() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await sandbox.sync(0)
        // An unmounted volume looks exactly like this. Creating the folder would sync onto the SSD.
        try FileManager.default.removeItem(at: sandbox.machines[1].local)

        let summary = try await sandbox.sync(1)

        XCTAssertFalse(Self.fileExists(sandbox.machines[1].local.path), "the folder must not be recreated")
        XCTAssertTrue(summary.isDegraded)
        XCTAssertTrue(summary.errors.contains { $0.contains("does not exist") }, summary.errors.joined(separator: "; "))
    }

    func testMissingVaultIsRefusedRatherThanCreated() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try FileManager.default.removeItem(at: sandbox.vault)

        let summary = try await sandbox.sync(0)

        XCTAssertTrue(summary.isDegraded)
        XCTAssertTrue(summary.errors.contains { $0.contains("not available") }, summary.errors.joined(separator: "; "))
    }

    func testVaultInsideTheLocalFolderIsRefused() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        var link = sandbox.link(0)
        link.vaultPath = sandbox.machines[0].local.appendingPathComponent("nested-vault").path

        let summary = try unwrap(await sandbox.engine(0).reconcile(link: link, config: sandbox.config()))

        XCTAssertTrue(summary.isDegraded)
        XCTAssertTrue(summary.errors.contains { $0.contains("overlap") }, summary.errors.joined(separator: "; "))
    }

    func testTrashAndMetadataAreNeverPublished() async throws {
        try sandbox.write("alpha", machine: 0, to: "alpha.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)
        // A deletion puts a copy in machine B's trash; that bookkeeping must not travel.
        try sandbox.delete(machine: 0, "alpha.txt")
        try await sandbox.sync(0)
        try await sandbox.sync(1)

        XCTAssertTrue(sandbox.trashFiles(machine: 1).contains("alpha.txt"))
        XCTAssertFalse(sandbox.vaultFiles.contains { $0.contains(DeleteRecord.trashDirectoryName) })

        // And the machine holding a trashed copy does not republish it as a live file.
        let after = try await sandbox.sync(1)
        XCTAssertEqual(after.uploaded, 0)
        XCTAssertFalse(sandbox.vaultExists("alpha.txt"))
    }

    private static func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
