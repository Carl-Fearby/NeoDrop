import XCTest
@testable import NeoDropCore

/// The user can deliberately resolve a foreign copy from the recovery page, but the default sync
/// rule remains unchanged: nothing is replaced until the user sees the exact share bytes, confirms,
/// and those bytes still match that confirmation when the request arrives.
final class ForeignCopyResolutionTests: XCTestCase {
    private var sandbox: Sandbox!
    private var engine: MirrorEngine!

    override func setUpWithError() throws {
        sandbox = try Sandbox(name: "foreign-resolution", replicaCount: 2)
        engine = sandbox.engine()
    }

    override func tearDown() {
        sandbox = nil
        engine = nil
    }

    private func stageForeign(_ contents: String = "placed by hand", at relativePath: String = "docs/report.txt") async throws -> String {
        let destination = sandbox.replicaURLs[0].appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: destination, atomically: true, encoding: .utf8)
        try sandbox.write("source version", to: relativePath)
        let summary = try unwrap(await engine.sync(config: sandbox.config()))
        XCTAssertEqual(summary.replicas[0].foreign, 1)
        return try Hashing.sha256(ofFileAt: destination)
    }

    func testConflictIsListedWithTheBytesAndSourcePathShownToTheUser() async throws {
        let digest = try await stageForeign()

        let entries = await engine.listForeignCopies(config: sandbox.config())

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.relativePath, "docs/report.txt")
        XCTAssertEqual(entry.replicaID, sandbox.replicaModels[0].id)
        XCTAssertEqual(entry.replicaName, "NAS1")
        XCTAssertEqual(entry.absolutePath, sandbox.replicaURLs[0].appendingPathComponent("docs/report.txt").path)
        XCTAssertEqual(entry.sourcePath, sandbox.sourceFile("docs/report.txt").path)
        XCTAssertEqual(entry.size, Int64("placed by hand".utf8.count))
        XCTAssertEqual(entry.sha256, digest)
        XCTAssertTrue(entry.replaceable)
        XCTAssertNil(entry.unavailableReason)
    }

    func testExplicitReplaceRetainsShareBytesAndCopiesSourceVersion() async throws {
        let digest = try await stageForeign()
        let maybeEntry = await engine.listForeignCopies(config: sandbox.config()).first
        let entry = try XCTUnwrap(maybeEntry)

        let destination = try await engine.replaceForeignCopy(
            relativePath: entry.relativePath,
            replicaID: entry.replicaID,
            expectedForeignSHA256: digest,
            config: sandbox.config()
        )

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "source version")
        XCTAssertEqual(try sandbox.trashContents(0, entry.relativePath), "placed by hand")
        let retained = try XCTUnwrap(sandbox.record(0, entry.relativePath))
        XCTAssertEqual(retained.reason, .replaced)
        XCTAssertEqual(retained.sha256, digest)
        XCTAssertEqual(retained.size, Int64("placed by hand".utf8.count))
        let manifest = ManifestStore(paths: sandbox.storePaths).load(replicaID: sandbox.replicaModels[0].id)
        XCTAssertEqual(manifest.entries[entry.relativePath]?.sha256, try sandbox.sourceDigest(entry.relativePath))
        XCTAssertFalse(manifest.foreignPaths.contains(entry.relativePath))

        let unresolved = await engine.listForeignCopies(config: sandbox.config())
        XCTAssertTrue(unresolved.isEmpty, "the file's question-mark exception is gone")
    }

    func testChangedShareBytesAfterListingAreRefusedAndNotTouched() async throws {
        let digest = try await stageForeign()
        let relativePath = "docs/report.txt"
        try sandbox.corruptOnReplica(0, relativePath, with: "changed after the dialog")

        do {
            _ = try await engine.replaceForeignCopy(
                relativePath: relativePath,
                replicaID: sandbox.replicaModels[0].id,
                expectedForeignSHA256: digest,
                config: sandbox.config()
            )
            XCTFail("the server must not replace bytes different from the ones the user saw")
        } catch let error as NeoDropError {
            guard case .foreignCopyChanged = error else {
                return XCTFail("expected a stale-conflict refusal, got \(error)")
            }
        }

        XCTAssertEqual(try sandbox.contentsOnReplica(0, relativePath), "changed after the dialog")
        XCTAssertFalse(sandbox.trashExists(0, relativePath), "the changed bytes are not moved behind the user's back")
    }

    func testDisabledReplicaConflictsAreVisibleButNotReplaceable() async throws {
        _ = try await stageForeign()
        var config = sandbox.config()
        config.replicas[0].enabled = false

        let entries = await engine.listForeignCopies(config: config)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertFalse(entry.replaceable)
        XCTAssertEqual(entry.unavailableReason, "Destination is offline or disabled")

        do {
            _ = try await engine.replaceForeignCopy(
                relativePath: entry.relativePath,
                replicaID: entry.replicaID,
                expectedForeignSHA256: entry.sha256 ?? String(repeating: "a", count: 64),
                config: config
            )
            XCTFail("disabled replicas are not eligible for a destructive action")
        } catch let error as NeoDropError {
            guard case .foreignCopyUnavailable = error else {
                return XCTFail("expected disabled-replica refusal, got \(error)")
            }
        }
    }

    func testAPathTraversalCannotResolveAForeignConflict() async throws {
        let escaped = sandbox.root.appendingPathComponent("outside.txt")
        try "do not touch".write(to: escaped, atomically: true, encoding: .utf8)

        do {
            _ = try await engine.replaceForeignCopy(
                relativePath: "../../outside.txt",
                replicaID: sandbox.replicaModels[0].id,
                expectedForeignSHA256: String(repeating: "a", count: 64),
                config: sandbox.config()
            )
            XCTFail("paths from HTTP requests cannot escape the replica")
        } catch let error as NeoDropError {
            guard case .foreignCopyUnavailable = error else {
                return XCTFail("expected a safe refusal, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: escaped, encoding: .utf8), "do not touch")
    }

    func testDirectoryConflictIsVisibleButNeverOfferedForReplace() async throws {
        let relativePath = "docs/report.txt"
        let path = sandbox.replicaURLs[0].appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try "inside directory".write(to: path.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try sandbox.write("source version", to: relativePath)
        let summary = try unwrap(await engine.sync(config: sandbox.config()))
        XCTAssertEqual(summary.replicas[0].foreign, 1)

        let entries = await engine.listForeignCopies(config: sandbox.config())
        let entry = try XCTUnwrap(entries.first)
        XCTAssertFalse(entry.replaceable)
        XCTAssertEqual(entry.unavailableReason, "The conflict is no longer a regular file on the share")
        XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("keep.txt"), encoding: .utf8), "inside directory")
    }

    func testAnOfflineConflictIsListedButDisabled() async throws {
        let digest = try await stageForeign()
        let away = sandbox.root.appendingPathComponent("NAS1-away")
        try FileManager.default.moveItem(at: sandbox.root.appendingPathComponent("NAS1"), to: away)
        defer { try? FileManager.default.moveItem(at: away, to: sandbox.root.appendingPathComponent("NAS1")) }

        let entries = await engine.listForeignCopies(config: sandbox.config())
        let entry = try XCTUnwrap(entries.first)
        XCTAssertFalse(entry.replaceable)
        XCTAssertNil(entry.sha256, "the offline destination's bytes are not read")
        XCTAssertEqual(entry.unavailableReason, "Destination is offline or disabled")

        do {
            _ = try await engine.replaceForeignCopy(
                relativePath: entry.relativePath,
                replicaID: entry.replicaID,
                expectedForeignSHA256: digest,
                config: sandbox.config()
            )
            XCTFail("an offline share cannot be deliberately overwritten")
        } catch let error as NeoDropError {
            guard case .foreignCopyUnavailable = error else {
                return XCTFail("expected offline refusal, got \(error)")
            }
        }
    }
}
