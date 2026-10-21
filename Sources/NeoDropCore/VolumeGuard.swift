import Foundation

/// Whether the folder a replica points at is really the share it is supposed to be.
///
/// "The replica root must already exist" is not enough on its own. When a network share unmounts,
/// macOS can leave the mount point behind as an ordinary empty directory on the boot disk — and a
/// directory is all `isUsableDirectory` asks for. Measured, with an image mounted at a scratch mount
/// point and then ejected: the next sync happily mirrored the whole source into
/// `/tmp/…/mnt`, which on a real machine is the internal SSD. This is the check that stops it.
///
/// Two independent signals, because either one alone has a hole:
///
/// * **Where the folder is now.** A path under a mount root that resolves to the boot volume is a
///   mount point that is not mounted. This catches a share that has never been synced — the first
///   run after setup, with the NAS already unplugged.
/// * **Where it was last time.** A replica records the volume it last synced to. If that volume is
///   not the boot disk and the path now is, the share went away and a folder was left in its place.
///   This catches a mount point anywhere — a disk image at a custom path, an NFS mount the app
///   never chose — and it cannot be fooled by a same-named folder on the boot disk.
///
/// A replica that genuinely lives on the boot disk (a plain local folder) is never refused: it was
/// recorded as boot-volume, so the second signal says nothing, and it is not under a mount root, so
/// the first says nothing either.
public struct VolumeGuard: Sendable {
    /// The volume a path is on, as the filesystem identifies it — not its name, which two mounts
    /// can share.
    public typealias Identifier = @Sendable (URL) -> String?

    public var identifier: Identifier
    public var bootIdentifier: Identifier
    /// Directories the system mounts shares under. Paths inside them that resolve to the boot
    /// volume are mount points with nothing mounted.
    public var mountRoots: [String]

    public enum Verdict: Equatable, Sendable {
        /// The folder is there and is where it claims to be.
        case available
        /// Nothing is at the path.
        case missing
        /// A directory on this Mac's boot disk is sitting where a mounted share belongs.
        case folderOnBootDisk
    }

    public init(identifier: @escaping Identifier, bootIdentifier: @escaping Identifier,
                mountRoots: [String] = VolumeGuard.defaultMountRoots) {
        self.identifier = identifier
        self.bootIdentifier = bootIdentifier
        self.mountRoots = mountRoots
    }

    /// `/Volumes` is where the Finder and the app's own mount requests put shares. The other two are
    /// where macOS automounts network filesystems; they are spelled unresolved here and compared
    /// through `PathIdentity`, so `/var/automount` and `/private/var/automount` agree.
    public static let defaultMountRoots = ["/Volumes", "/Network", "/private/var/automount"]

    public static let live = VolumeGuard(
        identifier: { VolumeIdentity.identifier(for: $0) },
        bootIdentifier: { _ in VolumeIdentity.identifier(for: URL(fileURLWithPath: "/")) }
    )

    public func verdict(for root: URL, lastVolumeIdentifier: String? = nil) -> Verdict {
        guard MirrorEngine.isUsableDirectory(root) else { return .missing }
        // A machine that cannot answer is not evidence of a problem: refuse only when the answer is
        // known to be the boot disk.
        guard let boot = bootIdentifier(URL(fileURLWithPath: "/")),
              identifier(root) == boot else { return .available }

        if let lastVolumeIdentifier, lastVolumeIdentifier != boot { return .folderOnBootDisk }

        let path = PathIdentity.canonical(root)
        for root in mountRoots {
            let mount = PathIdentity.canonical(URL(fileURLWithPath: root))
            if path == mount || path.hasPrefix(mount.hasSuffix("/") ? mount : mount + "/") {
                return .folderOnBootDisk
            }
        }
        return .available
    }
}
