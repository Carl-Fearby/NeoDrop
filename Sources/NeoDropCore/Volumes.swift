import Foundation

/// Volume-level facts NeoDrop uses to warn about false resilience: two replicas that happen to
/// live on the same physical device are one failure away from being zero replicas.
public enum VolumeIdentity {
    public static func identifier(for url: URL) -> String? {
        var target = url
        if !FileManager.default.fileExists(atPath: url.path) {
            // Fall back to the nearest existing ancestor so an unmounted `/Volumes/NAS2/NeoDrop`
            // still resolves to whatever volume holds that path.
            var candidate = url.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
                candidate = candidate.deletingLastPathComponent()
            }
            target = candidate
        }
        let values = try? target.resourceValues(forKeys: [.volumeIdentifierKey, .volumeNameKey])
        guard let identifier = values?.volumeIdentifier else { return nil }
        return String(describing: identifier)
    }

    public static func name(for url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName)
    }

    /// True when the path resolves to the same volume as the boot disk, which for a replica
    /// path usually means "the share is not mounted".
    public static func isOnBootVolume(_ url: URL) -> Bool {
        guard let volume = identifier(for: url),
              let boot = identifier(for: URL(fileURLWithPath: "/")) else { return false }
        return volume == boot
    }

    /// Replicas sharing a volume. Returns groups of replica names that are not independent.
    public static func sharedVolumeGroups(_ paths: [(name: String, url: URL)]) -> [[String]] {
        var groups: [String: [String]] = [:]
        for entry in paths {
            guard let identifier = identifier(for: entry.url) else { continue }
            groups[identifier, default: []].append(entry.name)
        }
        return groups.values.filter { $0.count > 1 }
    }
}

/// Asking Finder to mount an SMB/AFP share, and telling whether it arrived.
///
/// Deliberately does *not* handle passwords: `open smb://…` lets macOS use the Keychain entry
/// the user already has, and nothing sensitive ever passes through NeoDrop.
public struct MountManager: Sendable {
    public init() {}

    public static func isMounted(volumePath: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: volumePath, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// True when a share is reachable *and* is not silently the boot volume.
    public static func isAvailable(replicaPath: String) -> Bool {
        let url = URL(fileURLWithPath: (replicaPath as NSString).expandingTildeInPath)
        guard MirrorEngine.isUsableDirectory(url) else { return false }
        return !VolumeIdentity.isOnBootVolume(url)
    }

    /// Ask Finder (and therefore the user's Keychain) to mount the share.
    @discardableResult
    public static func requestMount(smbURL: String) -> Bool {
        guard let url = URL(string: smbURL), url.scheme != nil else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Poll for a replica path to appear, so a sync that follows a mount request still works.
    public static func waitForAvailability(replicaPath: String, timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isAvailable(replicaPath: replicaPath) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return isAvailable(replicaPath: replicaPath)
    }

    /// Currently mounted network volumes, used to suggest replicas in the UI.
    public static func mountedVolumes() -> [String] {
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return volumes
            .filter { $0 != "Macintosh HD" && !$0.hasPrefix(".") }
            .map { "/Volumes/\($0)" }
            .sorted()
    }
}
