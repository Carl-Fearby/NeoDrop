import Foundation

/// The channel the Finder extension uses when the container file is closed to it.
///
/// A sandboxed extension can read exactly one place: its own container. The app publishes the badge
/// index there, and macOS 14+ only allows that from a process carrying the *same team identity* — so
/// an ad-hoc build, which has no team at all, publishes nothing and shows no badges.
///
/// The second channel is loopback HTTP:
///
/// * the app listens on `127.0.0.1`, on the first free port of a **fixed small range**, and serves the
///   index at `/badges.json`;
/// * the extension — which may open an outgoing connection with its own entitlement — probes the
///   ports in that range and takes the first answer that decodes as an index.
///
/// A fixed range is what makes the two sides find each other without a shared secret. That is a real
/// trade-off and it is deliberate: any local process that probes the same ten ports can read the
/// index. What it contains is paths and badge names for folders NeoDrop already watches, never file
/// contents, and the alternative — a token — would have to travel over the same channel that cannot
/// carry it. The server answers loopback `Host` headers only and serves one path, one verb.
///
/// A Mach service was tried first and does not work here: `NSXPCListener(machServiceName:)` needs the
/// name to be owned by launchd (a launchd plist or an app service), and a name registered by an
/// ordinary app is not visible to a lookup — measured as `Connection init failed at lookup with
/// error 3 - No such process` from both a test process and a real app launched by LaunchServices.
public enum FinderStatusService {
    /// Ten ports, so a second NeoDrop (or something else) on the first few is not fatal. Both sides
    /// read this list; scripts/verify.sh checks the extension can reach loopback at all.
    public static let portRange: ClosedRange<UInt16> = 47_623...47_632
    public static let path = "/badges.json"

    public static func url(port: UInt16) -> URL? {
        URL(string: "http://127.0.0.1:\(port)\(path)")
    }
}

/// The extension's end of the channel: one short request per port, first answer wins.
///
/// Synchronous on purpose. It runs on the poll queue, never in Finder's badge path, and a reply that
/// arrives after the caller has moved on is not useful — so a missing app, a port with nothing on it
/// and a server that accepts and stays silent all end in `nil` rather than in a waiting Finder.
public final class FinderStatusClient {
    private let portRange: ClosedRange<UInt16>
    private let perPortTimeout: TimeInterval

    public init(portRange: ClosedRange<UInt16> = FinderStatusService.portRange,
                perPortTimeout: TimeInterval = 0.2) {
        self.portRange = portRange
        self.perPortTimeout = perPortTimeout
    }

    /// Nil when nothing is listening, when the app has published nothing, when the reply takes longer
    /// than the timeout, and when the bytes are not an index this build understands.
    public func fetchIndex() -> FinderStatusIndex? {
        for port in portRange {
            if let index = fetchIndex(port: port) { return index }
        }
        return nil
    }

    private func fetchIndex(port: UInt16) -> FinderStatusIndex? {
        guard let url = FinderStatusService.url(port: port) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = perPortTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let answer = Answer()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            // A 200 from something that is not NeoDrop is caught by the decode below; a non-200 is
            // NeoDrop saying "no index yet", which is not worth decoding.
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                answer.data = data
            }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + perPortTimeout + 0.1) == .success else {
            task.cancel()
            return nil
        }
        return answer.data.flatMap(FinderStatusIndex.decode)
    }

    /// Written on URLSession's own queue, read after the semaphore: the pair is the handover.
    private final class Answer: @unchecked Sendable {
        var data: Data?
    }
}
