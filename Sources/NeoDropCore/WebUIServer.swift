import Foundation
import Network

public enum WebUIError: Error, LocalizedError {
    case couldNotStart(String)

    public var errorDescription: String? {
        switch self {
        case .couldNotStart(let reason): return "The deleted-files view could not start: \(reason)"
        }
    }
}

/// The in-app web view's back end: a tiny HTTP server bound to loopback that serves the
/// deleted-files page and its two API routes.
///
/// It exists so the deleted-files UI can grow into a real UI without dragging AppKit into
/// `NeoDropCore`, and so the same page can be checked with `curl` when something looks wrong.
///
/// Security posture — this is deliberately small, not a general-purpose web server:
///
/// * bound to `127.0.0.1` only, so nothing on the LAN can reach it;
/// * every route sits behind a random per-launch URL token, so another local account or a
///   long-lived bookmark cannot guess it (and a stale URL cannot reach the next run);
/// * the `Host` header must be a loopback host, so a hostile page that rebinds DNS to us is
///   refused rather than served;
/// * a `POST` that carries an `Origin` must have come from this page;
/// * two routes, no directory serving, no keep-alive, no cookies.
public final class WebUIServer: @unchecked Sendable {
    public typealias ListHandler = @Sendable () async -> [DeletionEntry]
    public typealias RestoreHandler = @Sendable (_ relativePath: String) async throws -> URL
    /// Answers "what does NeoDrop know about this path?" — the Finder service's back end. Returns
    /// nil when the app cannot answer at all, which the page reports as a missing file rather than
    /// as an empty report.
    public typealias StatusHandler = @Sendable (_ path: String) async -> FileStatusReport?

    /// Longest request accepted, headers and body together. Bigger is a client with a problem.
    static let maximumRequestBytes = 64 * 1024

    private let queue = DispatchQueue(label: "ai.storyteller.neodrop.webui")
    private let listHandler: ListHandler
    private let restoreHandler: RestoreHandler
    private let statusHandler: StatusHandler?
    /// Random per launch and never persisted: the page URL is not a credential that outlives the
    /// run it was printed for.
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    private var listener: NWListener?
    private var liveConnections: [NWConnection] = []

    /// `status` is optional so the deleted-files half of the server can be constructed — and
    /// tested — on its own; the route answers 404 until a handler is supplied.
    public init(
        list: @escaping ListHandler,
        restore: @escaping RestoreHandler,
        status: StatusHandler? = nil
    ) {
        self.listHandler = list
        self.restoreHandler = restore
        self.statusHandler = status
    }

    // MARK: - Lifecycle

    /// Start listening on an ephemeral loopback port and return the page URL.
    ///
    /// The port is chosen by the OS so a second instance, or anything else already on a fixed
    /// port, can never collide with us.
    @discardableResult
    public func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        // Loopback only. The deleted-files view is for the person sitting at this Mac.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw WebUIError.couldNotStart(error.localizedDescription)
        }

        // State callbacks all arrive on `queue`, so a plain flag is enough to resume the
        // continuation exactly once (a listener can report ready and later fail).
        let resumed = Flag()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let raw = listener.port?.rawValue else {
                        resumed.once { continuation.resume(throwing: WebUIError.couldNotStart("no port was assigned")) }
                        return
                    }
                    resumed.once { continuation.resume(returning: raw) }
                case .failed(let error):
                    resumed.once { continuation.resume(throwing: WebUIError.couldNotStart(error.localizedDescription)) }
                case .cancelled:
                    resumed.once { continuation.resume(throwing: WebUIError.couldNotStart("the listener was cancelled")) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }

        self.listener = listener
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/") else {
            stop()
            throw WebUIError.couldNotStart("could not form the page URL")
        }
        return url
    }

    public func stop() {
        queue.async { [self] in
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            for connection in liveConnections { connection.cancel() }
            liveConnections.removeAll()
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        liveConnections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                guard let self, let connection else { return }
                self.liveConnections.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Read until one complete request has arrived, then answer it and close.
    ///
    /// There is no pipelining and no keep-alive: the page makes a handful of requests over its
    /// life, and a connection per request is the simplest thing that cannot get out of step.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest.parse(buffer) {
                guard let self else { connection.cancel(); return }
                self.dispatch(request, on: connection)
                return
            }
            if buffer.count > Self.maximumRequestBytes {
                guard let self else { connection.cancel(); return }
                self.send(.text(status: 413, "Request too large"), on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            guard let self else { connection.cancel(); return }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func dispatch(_ request: HTTPRequest, on connection: NWConnection) {
        Task { [weak self] in
            guard let self else { connection.cancel(); return }
            let response = await self.response(for: request)
            self.send(response, on: connection)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    private func response(for request: HTTPRequest) async -> HTTPResponse {
        let prefix = "/" + token
        let path = HTTPRequest.path(of: request.target)

        // Anything without the token does not get to learn that a server is here.
        guard path == prefix || path.hasPrefix(prefix + "/") else {
            return .text(status: 404, "Not found")
        }
        // A browser sending a foreign `Host` is a page on another site reaching for us (DNS
        // rebinding). The token already blocks that; this makes it explicit.
        guard HTTPRequest.isLoopbackHost(request.headers["host"]) else {
            return .text(status: 403, "Forbidden")
        }
        if request.method == "POST", let origin = request.headers["origin"] {
            let host = request.headers["host"] ?? ""
            guard origin.lowercased() == "http://" + host.lowercased() else {
                return .text(status: 403, "Forbidden")
            }
        }

        switch (request.method, String(path.dropFirst(prefix.count))) {
        case ("GET", ""), ("GET", "/"):
            return .html(WebUIPage.html(retentionDays: DeleteRecord.retentionDays))
        case ("GET", "/api/deletions"):
            return await deletionsResponse()
        case ("GET", "/status"):
            return await statusResponse(request)
        case ("POST", "/api/restore"):
            return await restoreResponse(for: request)
        case (_, "/"), (_, ""), (_, "/api/deletions"):
            return .text(status: 405, "Method not allowed")
        case (_, "/api/restore"):
            return .text(status: 405, "Method not allowed")
        default:
            return .text(status: 404, "Not found")
        }
    }

    private func deletionsResponse() async -> HTTPResponse {
        let entries = await listHandler()
        let payload = DeletionsPayload(
            retentionDays: DeleteRecord.retentionDays,
            generatedAt: Date(),
            files: entries
        )
        do {
            return try .json(status: 200, payload)
        } catch {
            return .text(status: 500, "Could not encode the deletion list")
        }
    }

    /// The status page is rendered here rather than fetched by script: the report is the whole
    /// page, and a document with no JavaScript in it has nothing to go wrong.
    private func statusResponse(_ request: HTTPRequest) async -> HTTPResponse {
        guard let statusHandler else {
            return .text(status: 404, "Not found")
        }
        guard let path = HTTPRequest.query(of: request.target)["path"], path.hasPrefix("/") else {
            return .text(status: 400, "Expected ?path=/absolute/path")
        }
        guard let report = await statusHandler(path) else {
            return .text(status: 404, "No status for that path")
        }
        return .html(WebUIPage.statusHTML(for: report))
    }

    private func restoreResponse(for request: HTTPRequest) async -> HTTPResponse {
        guard let body = RestoreRequest.decode(request.body), !body.relativePath.isEmpty else {
            return .jsonError(status: 400, message: "Expected {\"relativePath\": \"…\"}")
        }
        do {
            let restored = try await restoreHandler(body.relativePath)
            return try .json(status: 200, RestoreResponse(ok: true, restoredTo: restored.path, path: body.relativePath))
        } catch let error as NeoDropError {
            return .jsonError(status: Self.status(for: error), message: error.localizedDescription)
        } catch {
            return .jsonError(status: 500, message: error.localizedDescription)
        }
    }

    private static func status(for error: NeoDropError) -> Int {
        switch error {
        case .retainedCopyUnavailable: return 404
        case .restoreConflict, .restoreSourceUnavailable: return 409
        default: return 500
        }
    }
}

// MARK: - Wire types

struct DeletionsPayload: Encodable {
    var retentionDays: Int
    var generatedAt: Date
    var files: [DeletionEntry]
}

struct RestoreRequest: Decodable {
    var relativePath: String

    static func decode(_ body: Data) -> RestoreRequest? {
        guard !body.isEmpty else { return nil }
        return try? JSONDecoder().decode(RestoreRequest.self, from: body)
    }
}

struct RestoreResponse: Encodable {
    var ok: Bool
    var restoredTo: String
    var path: String
}

// MARK: - Minimal HTTP

struct HTTPRequest {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data

    /// Parse a complete request, or `nil` when more bytes are still needed.
    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }
        let head = String(decoding: data[data.startIndex..<headerRange.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= WebUIServer.maximumRequestBytes else { return nil }
        let body = Data(data[headerRange.upperBound...])
        guard body.count >= contentLength else { return nil }
        return HTTPRequest(method: method, target: target, headers: headers, body: body.prefix(contentLength))
    }

    /// The path part of the request target, without query or fragment.
    /// The query parameters, percent-decoded. A file path travels in the query string, so the
    /// decoding is not cosmetic: a folder called "Anna's Folder" arrives as `Anna%27s%20Folder`
    /// and must be turned back into the name the file system knows.
    static func query(of target: String) -> [String: String] {
        guard let mark = target.firstIndex(of: "?") else { return [:] }
        var query = String(target[target.index(after: mark)...])
        if let hash = query.firstIndex(of: "#") { query = String(query[query.startIndex..<hash]) }
        var result: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            // `+` is deliberately *not* decoded as a space, unlike a form submission: a file name
            // may contain a literal `+`, and treating it as a space would quietly answer about a
            // different file. Spaces arrive percent-encoded, which is what the app sends.
            result[name.removingPercentEncoding ?? name] = value.removingPercentEncoding ?? value
        }
        return result
    }

    static func path(of target: String) -> String {
        var path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        if let hash = path.firstIndex(of: "#") { path = String(path[path.startIndex..<hash]) }
        return path.isEmpty ? "/" : path
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard var host = host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") { // [::1]:port
            host = String(host.dropFirst().prefix(while: { $0 != "]" }))
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[host.startIndex..<colon])
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func text(status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }

    static func html(_ markup: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(markup.utf8))
    }

    static func json<T: Encodable>(status: Int, _ payload: T) throws -> HTTPResponse {
        let encoder = JSONEncoder()
        // File paths read as file paths, so the payload is legible to a person reading it.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: try encoder.encode(payload))
    }

    static func jsonError(status: Int, message: String) -> HTTPResponse {
        let payload = ErrorPayload(error: message)
        return (try? .json(status: status, payload)) ?? .text(status: status, message)
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        if contentType.hasPrefix("text/html") {
            // The page is one file with its own inline style and script and makes no external
            // requests, so nothing else needs to be allowed.
            head += "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        default: return "Internal Server Error"
        }
    }

    private struct ErrorPayload: Encodable { var error: String }
}

/// Single-use guard for a continuation that must be resumed exactly once. Only ever touched from
/// the listener's own serial queue, so a plain flag is enough.
private final class Flag: @unchecked Sendable {
    private var used = false
    func once(_ body: () -> Void) {
        guard !used else { return }
        used = true
        body()
    }
}
