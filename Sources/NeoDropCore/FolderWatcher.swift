import Foundation
import CoreServices

/// Watches source folders with FSEvents and reports coalesced change batches.
///
/// Two levels of coalescing: FSEvents' own `latency`, then a quiet-period debounce so that
/// dragging 5,000 files onto the source triggers one sync rather than five thousand.
public final class FolderWatcher {
    public typealias Handler = @Sendable ([String]) -> Void

    private let paths: [String]
    private let latency: CFTimeInterval
    private let quietPeriod: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "ai.storyteller.neodrop.fsevents")

    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []
    private var debounceWork: DispatchWorkItem?

    public init(paths: [String], latency: CFTimeInterval = 1.0, quietPeriod: TimeInterval = 3.0, handler: @escaping Handler) {
        self.paths = paths.map { ($0 as NSString).expandingTildeInPath }
        self.latency = latency
        self.quietPeriod = quietPeriod
        self.handler = handler
    }

    @discardableResult
    public func start() -> Bool {
        stop()
        guard !paths.isEmpty else { return false }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            FolderWatcher.callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return false
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.async { [weak self] in
            self?.debounceWork?.cancel()
            self?.debounceWork = nil
            self?.pending.removeAll()
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        watcher.receive(paths: paths, limit: Int(count))
    }

    private func receive(paths: [String], limit: Int) {
        // Already on `queue` (FSEventStreamSetDispatchQueue).
        for path in paths.prefix(max(limit, paths.count)) {
            pending.insert(path)
        }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = Array(self.pending)
            self.pending.removeAll()
            self.debounceWork = nil
            if !batch.isEmpty { self.handler(batch) }
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }
}
