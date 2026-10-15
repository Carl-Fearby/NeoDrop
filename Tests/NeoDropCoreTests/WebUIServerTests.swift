import Foundation
import XCTest
@testable import NeoDropCore

/// The deleted-files page is served by a real HTTP server, so it is tested the way it is used:
/// over HTTP, on loopback, through the routes the page itself calls.
final class WebUIServerTests: XCTestCase {
    /// Stand-in for the app: records what the page asked for and answers from a fixed list.
    final class Stub: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [DeletionEntry] = []
        private var restoredPaths: [String] = []
        private var failure: Error?
        private var restoredTo = "/tmp/Source/alpha.txt"

        init(entries: [DeletionEntry] = []) { list = entries }

        func setFailure(_ error: Error?) { lock.lock(); failure = error; lock.unlock() }
        func setRestoredTo(_ path: String) { lock.lock(); restoredTo = path; lock.unlock() }
        func restored() -> [String] { lock.lock(); defer { lock.unlock() }; return restoredPaths }

        func listEntries() -> [DeletionEntry] { lock.lock(); defer { lock.unlock() }; return list }

        func restore(_ relativePath: String) throws -> URL {
            lock.lock()
            let failure = self.failure
            let destination = restoredTo
            if failure == nil { restoredPaths.append(relativePath) }
            lock.unlock()
            if let failure { throw failure }
            return URL(fileURLWithPath: destination)
        }
    }

    /// Records what the app was asked about, from the server's own queue.
    final class AskedPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func append(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    private func start(stub: Stub, status: WebUIServer.StatusHandler? = nil) async throws -> (WebUIServer, URL) {
        let server = WebUIServer(
            list: { stub.listEntries() },
            restore: { path in try stub.restore(path) },
            status: status
        )
        let url = try await server.start()
        return (server, url)
    }

    /// A report with no disk behind it: enough to prove the route is wired and the page is escaped.
    private func report(path: String, name: String = "NAS1") -> FileStatusReport {
        FileStatusReport(
            path: path,
            relativePath: (path as NSString).lastPathComponent,
            kind: "file",
            summary: "It is on this Mac and copied to \(name).",
            locations: [
                FileLocation(role: .replica, name: name, rootPath: "/Volumes/NAS1", absolutePath: path,
                             present: true, size: 1234, modified: Date(),
                             recorded: RecordedCopy(kind: "manifest", sha256: String(repeating: "b", count: 64),
                                                    size: 1234, at: Date(), verifiedAt: Date(), matches: true),
                             note: "A complete copy of what NeoDrop wrote."),
            ],
            history: [
                FileHistoryEntry(at: Date(), kind: "update", machineName: "Anna's MacBook", size: 1234,
                                 sha256: String(repeating: "c", count: 64)),
            ],
            generatedAt: Date(),
            covered: true
        )
    }

    /// The wire shape of the two responses, decoded here rather than through the server's own
    /// encode-only types: this way the test fails if a field is renamed on one side only.
    private struct DeletionsJSON: Decodable {
        var retentionDays: Int
        var files: [DeletionEntry]
    }

    private struct RestoreJSON: Decodable {
        var ok: Bool
        var restoredTo: String
        var path: String
    }

    private static func entry(_ relativePath: String, available: Bool = true) -> DeletionEntry {
        DeletionEntry(
            relativePath: relativePath,
            sourcePath: "/tmp/Source/" + relativePath,
            size: 1234,
            sha256: String(repeating: "a", count: 64),
            deletedAt: Date().addingTimeInterval(-3600),
            expiresAt: Date().addingTimeInterval(DeleteRecord.retention - 3600),
            copies: [
                DeletionCopy(replicaID: UUID(), replicaName: "NAS1", available: available),
                DeletionCopy(replicaID: UUID(), replicaName: "NAS2", available: available),
            ]
        )
    }

    // MARK: - The page

    func testPageIsServedOnLoopbackBehindTheToken() async throws {
        let (server, url) = try await start(stub: Stub())
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        XCTAssertEqual(url.host, "127.0.0.1", "the server must only be reachable from this Mac")
        XCTAssertNotEqual(url.port, 80)
        XCTAssertNotEqual(url.port, 8080, "the port is assigned by the OS, not guessed")

        let html = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(html.contains("Deleted Files"))
        XCTAssertTrue(html.contains("\(DeleteRecord.retentionDays) days"), "the page states the retention window")
        XCTAssertTrue(html.contains("api/restore"), "the page talks to the API relatively, without the token in markup")
        XCTAssertFalse(html.contains(url.lastPathComponent), "the token is not written into the page")
    }

    /// The page is one self-contained document; nothing it renders may reach the network.
    func testPageLoadsNothingFromOutside() async throws {
        let (server, url) = try await start(stub: Stub())
        defer { server.stop() }
        let (data, _) = try await URLSession.shared.data(from: url)
        let html = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(html.contains("http://") && html.components(separatedBy: "http://").count > 1,
                       "no absolute external URL is referenced")
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("<link "))
        XCTAssertTrue(html.contains("Content-Security-Policy") == false, "the CSP is a header, not markup")
    }

    // MARK: - Routes

    func testDeletionsRouteReturnsTheList() async throws {
        let stub = Stub(entries: [Self.entry("Documents/report.txt"), Self.entry("Photos/a.jpg", available: false)])
        let (server, url) = try await start(stub: stub)
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: url.appendingPathComponent("api/deletions"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(DeletionsJSON.self, from: data)

        XCTAssertEqual(payload.retentionDays, DeleteRecord.retentionDays)
        XCTAssertEqual(payload.files.map(\.relativePath), ["Documents/report.txt", "Photos/a.jpg"])
        XCTAssertTrue(payload.files[0].restorable)
        XCTAssertFalse(payload.files[1].restorable, "one offline destination is still restorable, both are not")
    }

    func testRestoreRouteCallsThroughToTheEngine() async throws {
        let stub = Stub()
        stub.setRestoredTo("/tmp/Source/alpha.txt")
        let (server, url) = try await start(stub: stub)
        defer { server.stop() }

        var request = URLRequest(url: url.appendingPathComponent("api/restore"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"relativePath":"alpha.txt"}"#.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(stub.restored(), ["alpha.txt"])
        let payload = try JSONDecoder().decode(RestoreJSON.self, from: data)
        XCTAssertTrue(payload.ok)
        XCTAssertEqual(payload.path, "alpha.txt")
        XCTAssertEqual(payload.restoredTo, "/tmp/Source/alpha.txt")
    }

    func testRestoreConflictIsReportedAsAConflict() async throws {
        let stub = Stub()
        stub.setFailure(NeoDropError.restoreConflict("/tmp/Source/alpha.txt"))
        let (server, url) = try await start(stub: stub)
        defer { server.stop() }

        var request = URLRequest(url: url.appendingPathComponent("api/restore"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"relativePath":"alpha.txt"}"#.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 409)
        let message = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(message.contains("already exists"), "the page shows the user why: \(message)")
    }

    func testRestoreWithoutAPathIsRejected() async throws {
        let stub = Stub()
        let (server, url) = try await start(stub: stub)
        defer { server.stop() }

        var request = URLRequest(url: url.appendingPathComponent("api/restore"))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(stub.restored().isEmpty, "nothing is restored without a path")
    }

    // MARK: - File status

    func testStatusRouteRendersTheReportForTheDecodedPath() async throws {
        let asked = "file:///tmp/Anna's Folder/alpha.txt"
        let path = "/tmp/Anna's Folder/alpha.txt"
        let stub = Stub()
        let askedPaths = AskedPaths()
        let expected = report(path: path)
        let (server, url) = try await start(stub: stub, status: { requested in
            askedPaths.append(requested)
            return requested == path ? expected : nil
        })
        defer { server.stop() }

        var components = URLComponents(url: url.appendingPathComponent("status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        let request = try XCTUnwrap(components?.url)

        let (data, response) = try await URLSession.shared.data(from: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        XCTAssertEqual(askedPaths.all, [path], "the query arrives percent-decoded as a real path: \(askedPaths.all)")

        let html = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(html.contains("File Status"))
        XCTAssertTrue(html.contains("A complete copy of what NeoDrop wrote."))
        XCTAssertTrue(html.contains("Anna&#39;s MacBook") || html.contains("Anna's MacBook"),
                      "the publishing machine is named")
        XCTAssertNotEqual(asked, path)
    }

    /// The page is a document built from user data — a file name, a path, a machine name — so it is
    /// the one place in the app where a hostile file name could become markup.
    func testStatusPageEscapesEverythingItPrints() async throws {
        let path = "/tmp/<img src=x onerror=alert(1)>.txt"
        let stub = Stub()
        let expected = report(path: path)
        let (server, url) = try await start(stub: stub, status: { _ in expected })
        defer { server.stop() }

        var components = URLComponents(url: url.appendingPathComponent("status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        let (data, response) = try await URLSession.shared.data(from: try XCTUnwrap(components?.url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let html = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(html.contains("<img src=x"), "markup in a path must not reach the document")
        XCTAssertTrue(html.contains("&lt;img src=x"), html)
    }

    func testStatusRouteRefusesARelativePath() async throws {
        let stub = Stub()
        let askedPaths = AskedPaths()
        let (server, url) = try await start(stub: stub, status: { path in
            askedPaths.append(path)
            return FileStatusReport(path: path, relativePath: path, kind: "file", summary: "asked",
                                    locations: [], history: [], generatedAt: Date(), covered: false)
        })
        defer { server.stop() }

        var components = URLComponents(url: url.appendingPathComponent("status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "path", value: "relative/alpha.txt")]
        let (_, response) = try await URLSession.shared.data(from: try XCTUnwrap(components?.url))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(askedPaths.all.isEmpty, "a path that is not absolute never reaches the app")
    }

    func testStatusRouteIsAbsentWhenTheAppCannotAnswer() async throws {
        let (server, url) = try await start(stub: Stub())
        defer { server.stop() }

        let (_, response) = try await URLSession.shared.data(from: url.appendingPathComponent("status"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    func testStatusQueryParsing() {
        XCTAssertEqual(HTTPRequest.query(of: "/t/status?path=%2Ftmp%2Fa%20b.txt"), ["path": "/tmp/a b.txt"])
        XCTAssertEqual(HTTPRequest.query(of: "/t/status?path=/tmp/a+b.txt"), ["path": "/tmp/a+b.txt"],
                       "a literal + is part of a file name, not a space")
        XCTAssertEqual(HTTPRequest.query(of: "/t/status"), [:])
        XCTAssertEqual(HTTPRequest.query(of: "/t/status?path=/tmp/a.txt#anchor"), ["path": "/tmp/a.txt"])
    }

    func testWrongMethodOnAKnownRouteIsRejected() async throws {
        let (server, url) = try await start(stub: Stub())
        defer { server.stop() }

        var request = URLRequest(url: url.appendingPathComponent("api/deletions"))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 405)
    }

    // MARK: - Who may talk to it

    func testRequestsWithoutTheTokenLearnNothing() async throws {
        let (server, url) = try await start(stub: Stub(entries: [Self.entry("secret.txt")]))
        defer { server.stop() }

        let bare = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(url.port))/"))
        let (data, response) = try await URLSession.shared.data(from: bare)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(body.contains("Deleted Files"), "without the token the server is indistinguishable from nothing")

        let guessed = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(url.port))/deadbeef/api/deletions"))
        let (guessedData, guessedResponse) = try await URLSession.shared.data(from: guessed)
        XCTAssertEqual((guessedResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertFalse(String(decoding: guessedData, as: UTF8.self).contains("secret.txt"))
    }

    /// A page on another site must not be able to drive a restore (CSRF).
    func testPostFromAnotherOriginIsRefused() async throws {
        let stub = Stub()
        let (server, url) = try await start(stub: stub)
        defer { server.stop() }

        var request = URLRequest(url: url.appendingPathComponent("api/restore"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("http://evil.example", forHTTPHeaderField: "Origin")
        request.httpBody = Data(#"{"relativePath":"alpha.txt"}"#.utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertTrue(stub.restored().isEmpty, "the engine was never asked to restore anything")
    }

    func testForeignHostHeaderIsRefused() async throws {
        let stub = Stub()
        let (server, url) = try await start(stub: stub)
        defer { server.stop() }

        var request = URLRequest(url: url.appendingPathComponent("api/deletions"))
        request.setValue("evil.example", forHTTPHeaderField: "Host")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403,
                       "a rebinding page that reaches the port still has to name a loopback host")
    }

    func testStopReleasesThePort() async throws {
        let (server, url) = try await start(stub: Stub())
        let port = try XCTUnwrap(url.port)
        server.stop()

        // Give the cancellation a moment to reach the socket.
        var reachable = true
        for _ in 0..<20 {
            var probe = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(url.lastPathComponent)")))
            probe.timeoutInterval = 0.5
            if (try? await URLSession.shared.data(for: probe)) == nil { reachable = false; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(reachable, "a stopped server stops answering")
    }

    // MARK: - Request parsing

    func testLoopbackHostRecognition() {
        XCTAssertTrue(HTTPRequest.isLoopbackHost("127.0.0.1:51234"))
        XCTAssertTrue(HTTPRequest.isLoopbackHost("localhost"))
        XCTAssertTrue(HTTPRequest.isLoopbackHost("LocalHost:80"))
        XCTAssertTrue(HTTPRequest.isLoopbackHost("[::1]:8080"))
        XCTAssertFalse(HTTPRequest.isLoopbackHost("127.0.0.1.evil.example"))
        XCTAssertFalse(HTTPRequest.isLoopbackHost("evil.example:51234"))
        XCTAssertFalse(HTTPRequest.isLoopbackHost(nil))
        XCTAssertFalse(HTTPRequest.isLoopbackHost(""))
    }

    func testRequestParsingWaitsForTheWholeBody() throws {
        let head = "POST /t/api/restore HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 10\r\n\r\n"
        XCTAssertNil(HTTPRequest.parse(Data((head + "12345").utf8)), "an incomplete body is not a request")

        let request = try XCTUnwrap(HTTPRequest.parse(Data((head + "1234567890").utf8)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/t/api/restore")
        XCTAssertEqual(request.headers["host"], "127.0.0.1")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "1234567890")
    }

    func testTargetParsingDropsQueryAndFragment() {
        XCTAssertEqual(HTTPRequest.path(of: "/abc/api/deletions?x=1"), "/abc/api/deletions")
        XCTAssertEqual(HTTPRequest.path(of: "/abc/"), "/abc/")
        XCTAssertEqual(HTTPRequest.path(of: "/"), "/")
    }
}
