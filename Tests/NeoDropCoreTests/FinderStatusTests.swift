import Foundation
import XCTest
@testable import NeoDropCore
import NeoDropShared

/// The Finder extension answers from the index the app writes, so what matters here is that the index
/// says the right thing for a real folder: after a sync everything is in sync, an edited file is
/// waiting, a destination that is missing a copy is flagged, a broken copy needs attention, and a
/// deleted file's retained copy is marked as held.
final class FinderStatusTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox(name: "finderstatus", replicaCount: 2)
    }

    override func tearDown() {
        sandbox = nil
    }

    private func build(_ config: AppConfig? = nil) -> FinderStatusIndex {
        FinderStatusIndex.build(config: config ?? sandbox.config(), paths: sandbox.storePaths)
    }

    // MARK: - The matching rules

    func testAPathOutsideEveryWatchedFolderGetsNoBadge() {
        let index = FinderStatusIndex(roots: [FinderRoot(path: "/tmp/NeoDropSource", name: "Source", kind: .source)])
        XCTAssertNil(index.badge(for: "/tmp/elsewhere/file.txt"), "not NeoDrop's business, so no icon")
        XCTAssertNil(index.badgeIncludingDescendants(forPath: "/tmp/elsewhere/file.txt"))
    }

    func testTheDefaultInsideAWatchedFolderIsInSync() {
        let index = FinderStatusIndex(roots: [FinderRoot(path: sandbox.source.path, name: "Source", kind: .source)])
        XCTAssertEqual(index.badge(for: sandbox.sourceFile("anything.txt").path), .synced)
        XCTAssertEqual(index.badge(for: sandbox.source.path), .synced, "the folder itself is watched too")
    }

    func testTheLongestMatchingExceptionWins() {
        var index = FinderStatusIndex(roots: [FinderRoot(path: "/tmp/root", name: "Source", kind: .source)])
        index.set(.held, forPath: "/tmp/root/.neodrop-trash")
        index.set(.waiting, forPath: "/tmp/root/.neodrop-trash/notes.txt")

        XCTAssertEqual(index.badge(for: "/tmp/root/.neodrop-trash"), .held)
        XCTAssertEqual(index.badge(for: "/tmp/root/.neodrop-trash/notes.txt"), .waiting,
                       "the more specific entry is the answer")
        XCTAssertEqual(index.badge(for: "/tmp/root/.neodrop-trash/deeper/photo.jpg"), .held,
                       "an entry naming a directory covers what is below it")
    }

    func testAFolderSummarisesItsContents() {
        var index = FinderStatusIndex(roots: [FinderRoot(path: "/tmp/root", name: "Source", kind: .source)])
        index.set(.waiting, forPath: "/tmp/root/Documents/report.txt")

        XCTAssertEqual(index.badge(for: "/tmp/root/Documents"), .synced, "the folder itself is not an exception")
        XCTAssertEqual(index.badgeIncludingDescendants(forPath: "/tmp/root/Documents"), .waiting,
                       "but the folder shows the worst thing inside it")
        XCTAssertEqual(index.badgeIncludingDescendants(forPath: "/tmp/root"), .waiting)
        XCTAssertEqual(index.badgeIncludingDescendants(forPath: "/tmp/root/Photos"), .synced,
                       "an unrelated folder is unaffected")
    }

    func testTheWorstBadgeWinsAndWorkingBeatsEverything() {
        XCTAssertEqual(FinderBadge.worst([.synced, .waiting, .held]), .waiting)
        XCTAssertEqual(FinderBadge.worst([.attention, .working]), .working)
        XCTAssertEqual(FinderBadge.worst([.synced, .ignored]), .ignored)
        XCTAssertNil(FinderBadge.worst([]))
    }

    /// The app and the extension see one directory under two names: the app writes what its
    /// canonicaliser produced, Finder hands the extension the URL the user clicked. `/private/var/…`
    /// and `/var/…` (and `/private/tmp/…`, `/tmp/…`) are the same place. A comparison that failed here
    /// would fail *silently* — the badge would simply never match its own record, and "no badge" looks
    /// exactly like "not NeoDrop's business".
    func testTheTwoSpellingsOfOneDirectoryAreTheSamePath() throws {
        let directory = sandbox.source.appendingPathComponent("spelling/dir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("file.txt")
        try "contents".write(to: file, atomically: true, encoding: .utf8)

        // The sandbox lives under /var/folders/…, whose other spelling is /private/var/folders/…
        let otherSpelling = "/private" + file.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherSpelling), "the fixture must be real")

        var index = FinderStatusIndex(roots: [FinderRoot(path: "/private" + sandbox.source.path,
                                                         name: "Source", kind: .source)])
        index.set(.waiting, forPath: file.path)

        XCTAssertEqual(index.badge(for: file.path), .waiting)
        XCTAssertEqual(index.badge(for: otherSpelling), .waiting, "the other spelling of the same file")
        XCTAssertEqual(index.badgeIncludingDescendants(forPath: "/private" + sandbox.source.path), .waiting,
                       "and the folder above it, asked about in the other spelling")
    }

    func testTheIndexSurvivesARoundTrip() throws {
        var index = FinderStatusIndex(machineName: "Test Mac",
                                      roots: [FinderRoot(path: "/tmp/root", name: "NAS1", kind: .destination)])
        index.set(.attention, forPath: "/tmp/root/Photos/a.jpg")

        let url = sandbox.root.appendingPathComponent("finder-status.json")
        try index.save(to: url)
        let loaded = try XCTUnwrap(FinderStatusIndex.load(from: url))

        XCTAssertEqual(loaded.version, FinderStatusIndex.currentVersion)
        XCTAssertEqual(loaded.machineName, "Test Mac")
        XCTAssertEqual(loaded.roots, index.roots)
        XCTAssertEqual(loaded.exceptions.count, 1)
        XCTAssertEqual(loaded.badge(for: "/tmp/root/Photos/a.jpg"), .attention)
    }

    func testAFutureFormatIsRefusedRatherThanMisread() throws {
        let url = sandbox.root.appendingPathComponent("future.json")
        var index = FinderStatusIndex(roots: [FinderRoot(path: "/tmp/root", name: "x", kind: .source)])
        index.version = FinderStatusIndex.currentVersion + 1
        try index.save(to: url)

        XCTAssertNil(FinderStatusIndex.load(from: url), "a newer writer's file is not decoded on a guess")
    }

    func testNoIndexMeansNoBadgesRatherThanEverythingIsFine() {
        let missing = sandbox.root.appendingPathComponent("never-written.json")
        XCTAssertNil(FinderStatusIndex.load(from: missing))
    }

    // MARK: - The one path both processes meet over

    /// The app and the extension resolve one file from opposite sides of a sandbox: the extension asks
    /// for its own Application Support directory, the app names the extension's container. They have to
    /// agree exactly, and a mismatch is invisible from the outside — the extension reads nothing and
    /// simply draws no badges — so the agreement is asserted rather than left to a comment. It is also
    /// the check that catches a renamed extension bundle identifier.
    func testTheAppPublishesExactlyWhereTheExtensionReads() throws {
        let extensionSide = try XCTUnwrap(FinderStatusIndex.extensionIndexURL(), "no Application Support")
        let appSide = FinderStatusIndex.extensionContainerIndexURL()

        let inside = "/Library/Application Support/\(FinderStatusIndex.badgesDirectoryName)/\(FinderStatusIndex.fileName)"
        XCTAssertTrue(extensionSide.path.hasSuffix(inside),
                      "the extension reads from its own Application Support: \(extensionSide.path)")
        XCTAssertTrue(appSide.path.hasSuffix("/Library/Containers/\(FinderStatusIndex.extensionBundleIdentifier)/Data" + inside),
                      "and the app writes that same file inside the extension's container: \(appSide.path)")
        XCTAssertEqual(appSide.lastPathComponent, extensionSide.lastPathComponent)
    }

    /// Publishing works on a Mac where the badge directory does not exist yet: on first launch the
    /// app is started by the user and Finder gets round to the extension later, so the write has to
    /// carry on regardless. `save` creates the directories it needs.
    ///
    /// A scratch directory stands in for the container here on purpose — the real one is a matter of
    /// signatures rather than of code, and the test below is where that is asserted.
    func testPublishingCreatesTheDirectoryItNeeds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neodrop-badge-\(UUID().uuidString)", isDirectory: true)
        let url = directory
            .appendingPathComponent(FinderStatusIndex.badgesDirectoryName, isDirectory: true)
            .appendingPathComponent(FinderStatusIndex.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let index = FinderStatusIndex(roots: [FinderRoot(path: sandbox.source.path, name: "Source", kind: .source)])
        try index.save(to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "save created the directories and wrote the index into them")
        XCTAssertEqual(FinderStatusIndex.load(from: url)?.roots, index.roots,
                       "and the other side reads back exactly what was published")
    }

    /// The real container, which is where the installed extension actually reads from.
    ///
    /// Measured on macOS 26: since macOS 14 an application data container is protected from
    /// processes outside the team that owns it, so this publish succeeds when the app and the
    /// extension are signed by one team and is refused with a clean permission error when they are
    /// not. An ad-hoc signature has no team at all, which is what a `swift test` run looks like — so
    /// both outcomes are asserted instead of the environment being assumed.
    ///
    /// Falling into the refusal branch is not a defect in the code: the app must carry on either way
    /// (`AppModel.publishFinderStatus` catches this and logs it, because a badge going stale must never
    /// stop a sync), and the half that fixes it is a signature. `scripts/verify.sh` fails a build whose
    /// two bundles are signed by *different* teams, which is the case that can happen by accident.
    func testTheContainerChannelWorksForTheOwningTeamAndIsRefusedOtherwise() throws {
        let url = FinderStatusIndex.extensionContainerIndexURL()
        let index = FinderStatusIndex(roots: [FinderRoot(path: sandbox.source.path, name: "Source", kind: .source)])

        do {
            try index.save(to: url)
            // Only the file is removed: the container directory belongs to macOS and cannot be (and
            // should not be) deleted from here.
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertEqual(FinderStatusIndex.load(from: url)?.roots, index.roots,
                           "a team-signed app publishes into the container and the extension reads it back")
        } catch {
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain,
                           "the refusal is a file error the app can catch and log, not a crash: \(error)")
            XCTAssertEqual(failure.code, NSFileWriteNoPermissionError,
                           "expected the container to refuse this process's signature, got \(failure.code): \(error)")
        }
    }

    /// A file NeoDrop will not replace gets the question mark. It is on a destination, it is not
    /// NeoDrop's, and — because nothing else in the index has an opinion about an untracked path —
    /// this is the only thing that could badge it at all. Without it a hand-placed file looks like a
    /// file nobody asked about, which is the wrong answer to "is this safe?".
    func testAFileNeoDropDidNotWriteIsBadgedAsForeign() async throws {
        try sandbox.write("ours", to: "report.txt")
        let inTheWay = sandbox.replicaURLs[0].appendingPathComponent("report.txt")
        try "theirs".write(to: inTheWay, atomically: true, encoding: .utf8)
        _ = await sandbox.engine().sync(config: sandbox.config())

        let index = build()
        XCTAssertEqual(index.badge(for: inTheWay.path), .foreign)
        XCTAssertEqual(index.badge(for: sandbox.replicaURLs[1]
            .appendingPathComponent("report.txt").path), .synced,
                       "the replica that did receive the file is in sync, as usual")
    }

    // MARK: - What the app publishes

    func testEverythingInSyncPublishesNoExceptions() async throws {
        try sandbox.write("alpha", to: "docs/alpha.txt")
        try sandbox.write("beta", to: "beta.txt")
        _ = await sandbox.engine().sync(config: sandbox.config())

        let index = build()

        XCTAssertEqual(index.roots.count, 3, "one source plus two destinations")
        XCTAssertEqual(index.exceptions, [:] as [String: FinderBadge],
                       "a healthy library has nothing to say, which is what keeps the file small")
        XCTAssertEqual(index.badge(for: sandbox.sourceFile("docs/alpha.txt").path), .synced)
    }

    func testAnEditedFileIsWaitingUntilItIsSynced() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        _ = await sandbox.engine().sync(config: sandbox.config())

        try sandbox.write("alpha changed", to: "alpha.txt")
        XCTAssertEqual(build().badge(for: sandbox.sourceFile("alpha.txt").path), .waiting,
                       "the badge must not claim agreement while an edit is unpublished")

        _ = await sandbox.engine().sync(config: sandbox.config())
        XCTAssertEqual(build().badge(for: sandbox.sourceFile("alpha.txt").path), .synced)
    }

    /// A destination that was never reachable: the file is protected, but not redundantly, and that
    /// difference is exactly what the badge is for.
    func testAFileMissingFromADestinationIsWaiting() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        var config = sandbox.config()
        // Sync with only the first destination available, then add the second.
        config.replicas = [sandbox.replicas()[0]]
        _ = await sandbox.engine().sync(config: config)

        let index = build(sandbox.config())
        XCTAssertEqual(index.badge(for: sandbox.sourceFile("alpha.txt").path), .waiting)
    }

    func testACorruptCopyAsksForAttention() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        try sandbox.corruptOnReplica(0, "alpha.txt", with: "not the same bytes at all")
        // Verify (not repair) so the manifest keeps the failure it found.
        _ = await engine.verify(config: sandbox.config(), repair: false)

        let index = build()
        XCTAssertEqual(index.badge(for: sandbox.sourceFile("alpha.txt").path), .attention)
        XCTAssertEqual(index.badge(for: sandbox.replicaURLs[0].appendingPathComponent("alpha.txt").path), .attention,
                       "and the share's own copy is flagged where it lives")
    }

    func testARetainedCopyIsMarkedAsHeld() async throws {
        try sandbox.write("alpha", to: "docs/alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        try sandbox.delete("docs/alpha.txt")
        _ = await engine.sync(config: sandbox.config())

        let index = build()
        let trash = sandbox.trashURL(0, "docs/alpha.txt")
        XCTAssertEqual(index.badge(for: trash.path), .held)
        XCTAssertEqual(index.badge(for: trash.deletingLastPathComponent().path), .held,
                       "the trash directory is marked once, not once per retained file")
    }

    /// A version kept because a copy replaced it lives in the same place as a deletion, so it gets
    /// the same badge — and the file itself goes back to plain "in sync", because it is.
    func testAReplacedVersionMarksTheHeldCopyWhereItLives() async throws {
        try sandbox.write("first draft", to: "docs/alpha.txt")
        let engine = sandbox.engine()
        _ = await engine.sync(config: sandbox.config())
        try sandbox.write("second draft", to: "docs/alpha.txt")
        _ = await engine.sync(config: sandbox.config())

        let index = build()
        let trash = sandbox.trashURL(0, "docs/alpha.txt")
        XCTAssertEqual(index.badge(for: trash.path), .held, "the kept version is findable where it is kept")
        XCTAssertEqual(index.badge(for: sandbox.sourceFile("docs/alpha.txt").path), .synced,
                       "and the live file is in sync, because its newest version is everywhere")
    }

    func testTheFileBeingWorkedOnRightNowIsMarkedWorking() async throws {
        try sandbox.write("alpha", to: "alpha.txt")
        var progress = SyncProgress(phase: .syncing)
        progress.currentFile = "alpha.txt"

        let index = FinderStatusIndex.build(config: sandbox.config(), paths: sandbox.storePaths, progress: progress)
        XCTAssertEqual(index.badge(for: sandbox.sourceFile("alpha.txt").path), .working)
        XCTAssertEqual(index.exceptions.values.first, .working)
    }

    func testATwoWayFolderIsWatchedOnBothSides() async throws {
        let vaultSandbox = try VaultSandbox(name: "finderstatus-vault", machineNames: ["Machine A", "Machine B"])
        try vaultSandbox.write("alpha", machine: 0, to: "docs/alpha.txt")
        _ = try await vaultSandbox.sync(0)

        let config = AppConfig(vaults: [vaultSandbox.link(0)])
        let index = FinderStatusIndex.build(config: config, paths: vaultSandbox.machines[0].state)

        XCTAssertEqual(index.roots.count, 2, "this Mac's folder and the shared tree on the share")
        XCTAssertEqual(index.badge(for: vaultSandbox.machines[0].local.appendingPathComponent("docs/alpha.txt").path),
                       .synced)
        XCTAssertEqual(index.badge(for: vaultSandbox.vault.appendingPathComponent("docs/alpha.txt").path), .synced,
                       "the shared copy is watched too, so browsing the NAS shows its state")
    }

    func testAnEditInATwoWayFolderIsWaiting() async throws {
        let vaultSandbox = try VaultSandbox(name: "finderstatus-edit", machineNames: ["Machine A"])
        try vaultSandbox.write("alpha", machine: 0, to: "alpha.txt")
        _ = try await vaultSandbox.sync(0)

        let local = vaultSandbox.machines[0].local.appendingPathComponent("alpha.txt")
        let config = AppConfig(vaults: [vaultSandbox.link(0)])
        XCTAssertEqual(FinderStatusIndex.build(config: config, paths: vaultSandbox.machines[0].state).badge(for: local.path),
                       .synced)

        try vaultSandbox.write("a longer version of the file", machine: 0, to: "alpha.txt")
        XCTAssertEqual(FinderStatusIndex.build(config: config, paths: vaultSandbox.machines[0].state).badge(for: local.path),
                       .waiting)
    }

    /// The index is read by Finder while scrolling, so its size is a property worth holding: a
    /// 200-file library with everything in sync must publish nothing at all.
    func testAHealthyLibraryPublishesAnEmptyIndex() async throws {
        for index in 0..<200 {
            try sandbox.write("contents \(index)", to: "folder/file-\(index).txt")
        }
        _ = await sandbox.engine().sync(config: sandbox.config())

        let built = build()
        XCTAssertTrue(built.exceptions.isEmpty)
        XCTAssertLessThan(try JSONEncoder().encode(built).count, 2048,
                          "the published file stays small however many files are protected")
    }
}
