import Foundation
import XCTest
@testable import NeoDropCore

/// The measured failure these hold: with a disk image mounted at a scratch mount point, the app
/// mirrored a source into it; after the image was ejected, an empty folder was left at that path and
/// the next sync mirrored the whole source *again*, this time onto the boot disk. Nothing in the
/// old code objected — the folder existed, which is all `isUsableDirectory` asked.
final class VolumeGuardTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("neodrop-volguard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Every path resolves to `volume`; `boot` is the boot disk's identifier.
    private func guardEverywhere(on volume: String, boot: String = "boot",
                                 mountRoots: [String] = []) -> VolumeGuard {
        VolumeGuard(
            identifier: { _ in volume },
            bootIdentifier: { _ in boot },
            mountRoots: mountRoots
        )
    }

    private func folder(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The verdict

    func testAMountPointWithNothingMountedIsRefused() throws {
        let mountRoot = try folder("Volumes")
        let mounted = mountRoot.appendingPathComponent("NAS1")
        try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: true)

        let guardUnderTest = guardEverywhere(on: "boot", mountRoots: [mountRoot.path])
        XCTAssertEqual(guardUnderTest.verdict(for: mounted), .folderOnBootDisk)
    }

    func testAGenuineLocalFolderOnTheBootDiskIsAllowed() throws {
        let local = try folder("LocalBackup")
        XCTAssertEqual(guardEverywhere(on: "boot").verdict(for: local), .available,
                       "a replica that really is a folder on the internal disk is a supported setup, not a mistake")
    }

    func testAFolderOnAnotherVolumeIsAllowed() throws {
        let mounted = try folder("NAS1")
        XCTAssertEqual(guardEverywhere(on: "nas1").verdict(for: mounted), .available)
    }

    func testAMissingFolderIsMissing() throws {
        let gone = scratch.appendingPathComponent("never-created")
        XCTAssertEqual(guardEverywhere(on: "boot").verdict(for: gone), .missing)
    }

    func testARecordedShareThatIsNowTheBootDiskIsRefusedAnywhere() throws {
        // No mount root covers this path — a disk image at a custom mount point, say. The recorded
        // volume is the only evidence that a share used to be here, and it is enough.
        let path = try folder("custom-mountpoint")
        let guardUnderTest = guardEverywhere(on: "boot")
        XCTAssertEqual(
            guardUnderTest.verdict(for: path, lastVolumeIdentifier: "disk-image-volume"),
            .folderOnBootDisk
        )
    }

    func testALocalFolderThatWasAlwaysLocalStaysAllowed() throws {
        let local = try folder("LocalBackup")
        XCTAssertEqual(
            guardEverywhere(on: "boot").verdict(for: local, lastVolumeIdentifier: "boot"),
            .available,
            "an empty local folder that was never a share must still be filled"
        )
    }

    // MARK: - The engine

    /// A share that has never been synced: an empty folder sits where it belongs, and the only
    /// evidence is the path being under a mount root.
    func testSyncWritesNothingIntoTheFolderLeftAtAnUnmountedShare() async throws {
        let sandbox = try Sandbox(name: "volguard-fresh", replicaCount: 1)
        try sandbox.write("alpha", to: "alpha.txt")

        let mountRoot = sandbox.replicaURLs[0].deletingLastPathComponent()
        let engine = MirrorEngine(
            paths: sandbox.storePaths,
            volumes: guardEverywhere(on: "boot", mountRoots: [mountRoot.path])
        )

        let summary = await engine.sync(config: sandbox.config())
        XCTAssertEqual(summary?.replicas.first?.status, .offline)
        XCTAssertFalse(sandbox.fileExistsOnReplica(0, "alpha.txt"),
                       "nothing may be written into a folder standing in for an unmounted share")
        let message = summary?.replicas.first?.errors.joined(separator: " ") ?? ""
        XCTAssertTrue(message.contains("boot disk"), "the report has to say which volume it refused: \(message)")
    }

    /// A share that synced yesterday and is gone today, at a path no mount root covers. The manifest
    /// remembers the volume, so the empty folder is recognised for what it is — then the share comes
    /// back and the sync catches up on what it missed.
    func testAShareThatIsGoneIsRefusedAndCatchesUpWhenItReturns() async throws {
        let sandbox = try Sandbox(name: "volguard-recorded", replicaCount: 1)
        try sandbox.write("alpha", to: "alpha.txt")

        let mounted = guardEverywhere(on: "share-volume")
        let engine = MirrorEngine(paths: sandbox.storePaths, volumes: mounted)
        _ = await engine.sync(config: sandbox.config())
        XCTAssertTrue(sandbox.fileExistsOnReplica(0, "alpha.txt"))
        let manifest = ManifestStore(paths: sandbox.storePaths).load(replicaID: sandbox.replicaModels[0].id)
        XCTAssertEqual(manifest.volumeIdentifier, "share-volume", "the replica records where its bytes went")

        // The share is gone; a folder was left at its path. No mount root covers this path, so the
        // recorded volume is the only thing that can catch it.
        try sandbox.write("beta", to: "beta.txt")
        let stale = MirrorEngine(paths: sandbox.storePaths, volumes: guardEverywhere(on: "boot"))
        let refused = await stale.sync(config: sandbox.config())
        XCTAssertEqual(refused?.replicas.first?.status, .offline)
        XCTAssertFalse(sandbox.fileExistsOnReplica(0, "beta.txt"))
        XCTAssertTrue(sandbox.fileExistsOnReplica(0, "alpha.txt"),
                      "the copy already on the share must be left exactly as it was")

        // The share comes back, and the file it missed lands.
        let back = MirrorEngine(paths: sandbox.storePaths, volumes: guardEverywhere(on: "share-volume"))
        let recovered = await back.sync(config: sandbox.config())
        XCTAssertEqual(recovered?.replicas.first?.status, .online)
        XCTAssertTrue(sandbox.fileExistsOnReplica(0, "beta.txt"))
    }

    /// The refusal must not leak into the destructive side of the app: an unmounted share keeps its
    /// retained copies instead of having them purged or restored onto the boot disk.
    func testAnUnmountedShareKeepsItsRetainedCopies() async throws {
        let sandbox = try Sandbox(name: "volguard-retention", replicaCount: 1)
        try sandbox.write("alpha", to: "alpha.txt")
        let engine = MirrorEngine(paths: sandbox.storePaths, volumes: guardEverywhere(on: "share-volume"))
        _ = await engine.sync(config: sandbox.config())

        try sandbox.delete("alpha.txt")
        _ = await engine.sync(config: sandbox.config())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sandbox.replicaURLs[0].appendingPathComponent(".neodrop-trash/alpha.txt").path
        ), "the deletion should be retained on the share")

        let stale = MirrorEngine(paths: sandbox.storePaths, volumes: guardEverywhere(on: "boot"))
        let destinations = await stale.deleteDestinations(config: sandbox.config())
        XCTAssertEqual(destinations.first?.isAvailable, false,
                       "recovery must not offer a restore onto a folder that is not the share")
    }
}
