import Foundation

/// Comparing paths the way the filesystem means them, not the way they are spelled.
///
/// macOS reaches the same directory by more than one name. `/var` and `/private/var` are the same
/// place (as are `/tmp`, `/etc` and `/private/tmp`, `/private/etc`), and `FileManager`'s enumerator
/// hands back the `/private` spelling while a `config.json` — or anything a person types — usually
/// holds the other one. Comparing the raw strings therefore makes a folder *disagree with itself*,
/// which is not a theoretical problem: it is how restoring a file that another Mac deleted from a
/// two-way folder was refused with "the original folder is no longer configured", with the folder
/// configured on screen.
///
/// `resolvingSymlinksInPath` is the primitive that does the work, but it is only reliable for parts
/// of a path that **exist**: asked about `/private/var/…/file.txt` where `file.txt` is already gone
/// (exactly the case in play — the file is in the trash), Foundation cannot resolve it and hands the
/// `/private` spelling straight back. So the existing prefix is resolved component by component and
/// the rest is appended. That also covers a symlink of somebody's own: a configuration naming
/// `~/Archive` and a record naming the volume it points at are then the same folder.
public enum PathIdentity {
    /// The one spelling two paths must agree on before anything is compared.
    public static func canonical(_ url: URL) -> String {
        let fm = FileManager.default
        let parts = url.standardizedFileURL.pathComponents
        var resolved = URL(fileURLWithPath: "/")
        var index = 1
        // Walk as far as the path really goes, resolving as we go.
        while index < parts.count {
            let next = resolved.appendingPathComponent(parts[index])
            guard fm.fileExists(atPath: next.path) else { break }
            resolved = next.resolvingSymlinksInPath()
            index += 1
        }
        // The tail is appended unchanged — an unmounted share, or a file that has been deleted, must
        // still compare against the folder it belongs to.
        var result = resolved.path
        for tail in parts[index...] where tail != "/" {
            result = (result as NSString).appendingPathComponent(tail)
        }
        if result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Is `child` the same directory as `root`, or inside it?
    public static func contains(_ root: URL, _ child: URL) -> Bool {
        let parent = canonical(root)
        let candidate = canonical(child)
        if parent == candidate { return true }
        return candidate.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    /// Do two folders overlap, either containing the other or being the same folder?
    public static func overlaps(_ left: URL, _ right: URL) -> Bool {
        contains(left, right) || contains(right, left)
    }
}
