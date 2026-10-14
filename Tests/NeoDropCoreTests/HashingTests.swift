import XCTest
import CryptoKit
@testable import NeoDropCore

final class HashingTests: XCTestCase {

    func testHexStringIsLowercaseAndPadded() {
        XCTAssertEqual(hexString([0x00, 0x0f, 0xa0, 0xff]), "000fa0ff")
        XCTAssertEqual(hexString([]), "")
    }

    /// Published NIST vectors, so the digest itself is pinned independently of CryptoKit.
    func testKnownDigests() {
        XCTAssertEqual(Hashing.sha256(of: ""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Hashing.sha256(of: "abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            Hashing.sha256(of: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testFileDigestMatchesStringDigest() throws {
        let url = try temporaryFile(contents: Data("abc".utf8))
        XCTAssertEqual(try Hashing.sha256(ofFileAt: url), Hashing.sha256(of: "abc"))
    }

    /// The chunked reader must agree with a one-shot hash across chunk boundaries, which is the
    /// usual place a streaming implementation drops or double-counts bytes.
    func testLargeFileDigestIsChunkBoundarySafe() throws {
        // 2 chunks plus a partial chunk, so both boundaries are exercised.
        let bytes = Data((0..<(Hashing.chunkSize * 2 + 12_345)).map { UInt8($0 % 251) })
        let url = try temporaryFile(contents: bytes)
        let expected = hexString(SHA256.hash(data: bytes))
        XCTAssertEqual(try Hashing.sha256(ofFileAt: url), expected)
    }

    func testExactChunkMultipleIsChunkBoundarySafe() throws {
        let bytes = Data(repeating: 0x5a, count: Hashing.chunkSize * 3)
        let url = try temporaryFile(contents: bytes)
        XCTAssertEqual(try Hashing.sha256(ofFileAt: url), hexString(SHA256.hash(data: bytes)))
    }

    func testEmptyFileHasEmptyDigest() throws {
        let url = try temporaryFile(contents: Data())
        XCTAssertEqual(try Hashing.sha256(ofFileAt: url), Hashing.sha256(of: ""))
    }

    func testAtomicCopyLeavesNoTempFilesBehind() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.txt")
        try Data("payload".utf8).write(to: source)
        let destination = directory.appendingPathComponent("nested/deep/copy.txt")

        try AtomicFile.copy(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("payload".utf8))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(siblings.filter { $0.contains(".part") }.count, 0, "temp files must be cleaned up")
    }

    func testAtomicCopyReplacesExistingFile() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.txt")
        let destination = directory.appendingPathComponent("destination.txt")
        try Data("old".utf8).write(to: destination)
        try Data("new-and-longer".utf8).write(to: source)

        try AtomicFile.copy(from: source, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new-and-longer")
    }

    func testAtomicCopyPreservesModificationDate() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.txt")
        try Data("payload".utf8).write(to: source)
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: source.path)

        let destination = directory.appendingPathComponent("copy.txt")
        try AtomicFile.copy(from: source, to: destination)

        let copied = try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date
        XCTAssertEqual(copied?.timeIntervalSince1970 ?? 0, stamp.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Helpers

    private func temporaryFile(contents: Data, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("neodrop-hash-\(UUID().uuidString)")
        try contents.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func temporaryDirectory(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("neodrop-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
