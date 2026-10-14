import XCTest
@testable import NeoDropCore

final class ScannerTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox(name: "scanner", replicaCount: 0)
    }

    override func tearDown() {
        sandbox = nil
    }

    func testScansNestedFilesWithRelativePaths() throws {
        try sandbox.write("root", to: "root.txt")
        try sandbox.write("deep", to: "a/b/c/deep.txt")

        let files = try Scanner.scan(source: sandbox.sourceRoot, excludes: ExcludeMatcher(patterns: []))
        let paths = Set(files.map(\.relativePath))

        XCTAssertEqual(paths, ["root.txt", "a/b/c/deep.txt"])
        XCTAssertEqual(files.first(where: { $0.relativePath == "root.txt" })?.size, 4)
    }

    func testExcludesMatchFileNamesAndPaths() throws {
        try sandbox.write("keep", to: "keep.txt")
        try sandbox.write("junk", to: ".DS_Store")
        try sandbox.write("temp", to: "draft.tmp")
        try sandbox.write("ignored", to: "Archive/old.txt")

        let matcher = ExcludeMatcher(patterns: [".DS_Store", "*.tmp", "Archive/*"])
        let paths = Set(try Scanner.scan(source: sandbox.sourceRoot, excludes: matcher).map(\.relativePath))
        XCTAssertEqual(paths, ["keep.txt"])
    }

    func testExcludedDirectoryIsNotDescended() throws {
        try sandbox.write("keep", to: "keep.txt")
        try sandbox.write("hidden", to: "node_modules/pkg/index.js")
        try sandbox.write("also", to: "node_modules/pkg/deep/thing.js")

        let matcher = ExcludeMatcher(patterns: ["node_modules"])
        let paths = try Scanner.scan(source: sandbox.sourceRoot, excludes: matcher).map(\.relativePath)
        XCTAssertEqual(paths, ["keep.txt"])
    }

    func testSymlinksAreSkipped() throws {
        try sandbox.write("real", to: "real.txt")
        try FileManager.default.createSymbolicLink(
            at: sandbox.source.appendingPathComponent("link.txt"),
            withDestinationURL: sandbox.source.appendingPathComponent("real.txt")
        )

        let paths = try Scanner.scan(source: sandbox.sourceRoot, excludes: ExcludeMatcher(patterns: [])).map(\.relativePath)
        XCTAssertEqual(paths, ["real.txt"])
    }

    func testMissingSourceThrows() throws {
        let missing = SourceRoot(name: "Gone", path: "/tmp/neodrop-does-not-exist-\(UUID().uuidString)")
        XCTAssertThrowsError(try Scanner.scan(source: missing, excludes: ExcludeMatcher(patterns: []))) { error in
            XCTAssertTrue(error is ScannerError)
        }
    }

    func testSourceIndexReusesHashesUntilMetadataChanges() throws {
        try sandbox.write("one", to: "one.txt")
        try sandbox.write("two", to: "two.txt")

        let scanned = try Scanner.scan(source: sandbox.sourceRoot, excludes: ExcludeMatcher(patterns: []))
        let indexer = SourceIndexer()
        let first = indexer.refresh(files: scanned, previous: SourceIndex())
        XCTAssertEqual(first.hashed, 2)
        XCTAssertEqual(first.reused, 0)

        // Nothing changed: every digest comes from the cache, no re-reading.
        let second = indexer.refresh(files: scanned, previous: first.index)
        XCTAssertEqual(second.hashed, 0)
        XCTAssertEqual(second.reused, 2)

        // Touch one file's contents; only that one is re-hashed.
        try sandbox.write("one-changed-with-different-length", to: "one.txt")
        let rescanned = try Scanner.scan(source: sandbox.sourceRoot, excludes: ExcludeMatcher(patterns: []))
        let third = indexer.refresh(files: rescanned, previous: first.index)
        XCTAssertEqual(third.hashed, 1)
        XCTAssertEqual(third.reused, 1)
    }

    /// A rewrite that keeps the same size must still be detected, or a stale digest would hide
    /// a changed file forever.
    func testSameSizeRewriteIsDetectedByModificationDate() throws {
        try sandbox.write("aaaa", to: "same.txt")
        let scanned = try Scanner.scan(source: sandbox.sourceRoot, excludes: ExcludeMatcher(patterns: []))
        let indexer = SourceIndexer()
        let first = indexer.refresh(files: scanned, previous: SourceIndex())

        try sandbox.write("bbbb", to: "same.txt")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: sandbox.source.appendingPathComponent("same.txt").path
        )

        let rescanned = try Scanner.scan(source: sandbox.sourceRoot, excludes: ExcludeMatcher(patterns: []))
        let second = indexer.refresh(files: rescanned, previous: first.index)

        XCTAssertEqual(second.hashed, 1, "the rewritten file must be re-hashed")
        let key = "\(sandbox.sourceRoot.id.uuidString)/same.txt"
        XCTAssertEqual(second.index.entries[key]?.sha256, Hashing.sha256(of: "bbbb"))
    }

    func testNamespacingSeparatesIdenticalPathsFromDifferentSources() {
        let source = SourceRoot(name: "Work", path: "/tmp/work")
        XCTAssertEqual(Scanner.namespaced(relativePath: "notes.txt", source: source, sourceCount: 1), "notes.txt")
        XCTAssertEqual(Scanner.namespaced(relativePath: "notes.txt", source: source, sourceCount: 3), "Work/notes.txt")
    }
}
