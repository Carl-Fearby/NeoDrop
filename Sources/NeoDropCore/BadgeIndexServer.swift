import Foundation
import Network
import NeoDropShared

/// Serves the encoded `FinderStatusIndex` to the Finder Sync extension over loopback.
///
/// It is a second, smaller server rather than a route on `WebUIServer` because the two have opposite
/// requirements: the deleted-files page gets a random port behind a per-launch token, while a
/// sandboxed extension has to *find* this one without being told anything. So this binds the first
/// free port of a small fixed range — see `FinderStatusService` for what that costs and why the
/// trade was taken. What it answers with is one path, one verb and one cached Data: the same bytes the
/// app writes to the container file, so the two channels cannot disagree.
public final class BadgeIndexServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.storyteller.neodrop.badges")
    private let portRange: ClosedRange<UInt16>
    private var listener: NWListener?
    private var liveConnections: [NWConnection] = []
    /// The port that was bound, or nil while nothing is listening.
    public private(set) var port: UInt16?
    /// Written by the app after a sync, read by whichever queue is answering a request.
    private let lock = NSLock()
    private var latest: Data?

    public init(portRange: ClosedRange<UInt16> = FinderStatusService.portRange) {
        self.portRange = portRange
    }

    // MARK: - What it serves

    public func publish(_ index: FinderStatusIndex) {
        publish(try? index.encoded())
    }

    public func publish(_ data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        latest = data
    }

    /// Forget what was published, so the extension stops showing the last thing a stopped sync knew
    /// rather than a stale green tick.
    public func withdraw() {
        publish(nil)
    }

    private var current: Data? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    // MARK: - Lifecycle

    /// Bind the first free port in the range and start answering.
    ///
    /// Blocking for at most a second per candidate: it is called once at launch and a failure has to
    /// be known now, because "no channel" is a fallback to the file rather than a retry later.
    @discardableResult
    public func start() -> UInt16? {
        guard listener == nil else { return port }
        for candidate in portRange {
            guard let candidatePort = NWEndpoint.Port(rawValue: candidate) else { continue }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            // Loopback only: the badge index is for the Finder on this Mac.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                                                  port: candidatePort)
            guard let candidateListener = try? NWListener(using: parameters) else { continue }

            let settled = Settled()
            candidateListener.stateUpdateHandler = { state in
                switch state {
                case .ready: settled.finish(ready: true)
                case .failed, .cancelled: settled.finish(ready: false)
                default: break
                }
            }
            candidateListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            candidateListener.start(queue: queue)
            guard settled.wait(timeout: 1), settled.ready else {
                candidateListener.stateUpdateHandler = nil
                candidateListener.newConnectionHandler = nil
                candidateListener.cancel()
                continue
            }
            listener = candidateListener
            port = candidate
            return candidate
        }
        return nil
    }

    public func stop() {
        queue.sync {
            publish(nil)
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            port = nil
            for connection in liveConnections { connection.cancel() }
            liveConnections.removeAll()
        }
    }

    // MARK: - Connections

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

    /// Read one complete request, answer, close. No keep-alive and no pipelining: the extension asks
    /// every couple of seconds and a connection per ask is the simplest thing that cannot get out of
    /// step with a client that may go away at any moment.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest.parse(buffer) {
                guard let self else { connection.cancel(); return }
                self.send(self.response(for: request), on: connection)
                return
            }
            if buffer.count > WebUIServer.maximumRequestBytes || isComplete || error != nil {
                connection.cancel()
                return
            }
            guard let self else { connection.cancel(); return }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    private func response(for request: HTTPRequest) -> HTTPResponse {
        // A page on another site reaching for us (DNS rebinding) is refused before anything else,
        // the same rule the web UI applies.
        guard HTTPRequest.isLoopbackHost(request.headers["host"]) else {
            return .text(status: 403, "Forbidden")
        }
        switch (request.method, HTTPRequest.path(of: request.target)) {
        case ("GET", FinderStatusService.path):
            guard let data = current else {
                // The app is up and has published nothing yet. A 404 is a real answer: the extension
                // shows no badge rather than claiming everything is in sync.
                return .text(status: 404, "No badge index yet")
            }
            return HTTPResponse(status: 200, contentType: "application/json; charset=utf-8", body: data)
        case (_, FinderStatusService.path):
            return .text(status: 405, "Method not allowed")
        default:
            return .text(status: 404, "Not found")
        }
    }
}

/// One-shot handshake between the listener's queue and the thread that started it: a state callback
/// can fire more than once (ready, then cancelled), and the waiter must be released exactly once.
private final class Settled: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var settled = false
    private var isReady = false

    var ready: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReady
    }

    func finish(ready: Bool) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        isReady = ready
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}
