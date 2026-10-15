import XCTest
@testable import NeoDropCore

/// `/var` and `/private/var` are one directory under two names, and the two spellings meet in
/// neither direction on their own. Every path comparison in the engine therefore goes through
/// `PathIdentity`, and this is the test that keeps it that way: the first version of the two-way
/// restore compared raw strings and refused with "the original folder is no longer configured" for a
/// folder that was configured, spelled the other way.
final class PathIdentityTests: XCTestCase {
    func testTheTwoSpellingsOfVarAreOneDirectory() {
        let short = URL(fileURLWithPath: "/var/tmp/neodrop-example")
        let long = URL(fileURLWithPath: "/private/var/tmp/neodrop-example")

        XCTAssertEqual(PathIdentity.canonical(short), PathIdentity.canonical(long))
        XCTAssertTrue(PathIdentity.contains(short, long))
        XCTAssertTrue(PathIdentity.contains(long, short))
        XCTAssertTrue(PathIdentity.overlaps(short, long))
    }

    func testAChildIsInsideItsParentAndNotTheOtherWayRound() {
        let root = URL(fileURLWithPath: "/var/tmp/neodrop-example")
        let child = URL(fileURLWithPath: "/private/var/tmp/neodrop-example/Folder/file.txt")

        XCTAssertTrue(PathIdentity.contains(root, child))
        XCTAssertFalse(PathIdentity.contains(child, root))
    }

    /// A sibling whose name merely starts with the same letters is not inside the folder.
    func testAPrefixThatIsNotAPathBoundaryIsNotInside() {
        let root = URL(fileURLWithPath: "/tmp/neodrop/NAS")
        XCTAssertFalse(PathIdentity.contains(root, URL(fileURLWithPath: "/tmp/neodrop/NAS2/file.txt")))
    }

    /// The unmounted-share case: a path that does not exist still compares, because the tail is left
    /// alone. This is what lets a missing replica read as offline rather than as somewhere else.
    func testANonExistentPathStillCompares() {
        let root = URL(fileURLWithPath: "/Volumes/neodrop-missing-\(UUID().uuidString)/NeoDrop")
        let child = root.appendingPathComponent("Documents/file.txt")

        XCTAssertTrue(PathIdentity.contains(root, child))
        XCTAssertFalse(PathIdentity.contains(root, URL(fileURLWithPath: "/Volumes/something-else")))
    }

    /// A temporary directory is reached through `/var` on macOS; the enumerator hands back
    /// `/private/var`. Anything NeoDrop records about a file it found must compare equal to the
    /// folder the configuration named.
    func testEnumeratorSpellingMatchesTheConfiguredSpelling() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("neodrop-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "x".write(to: root.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        let scanned = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.nextObject() as? URL
        )

        XCTAssertTrue(PathIdentity.contains(root, scanned), "\(scanned.path) should read as inside \(root.path)")
    }
}
