import Foundation

/// A problem with the current configuration, phrased for a human.
public struct ConfigIssue: Identifiable, Sendable {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public let id: UUID
    public var severity: Severity
    public var message: String

    public init(id: UUID = UUID(), severity: Severity, message: String) {
        self.id = id
        self.severity = severity
        self.message = message
    }
}

/// Catches the mistakes that quietly turn "protected" into "not protected".
public enum ConfigValidator {
    public static func validate(_ config: AppConfig, fileManager: FileManager = .default) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []

        if config.sources.isEmpty {
            issues.append(ConfigIssue(severity: .error, message: "No source folder is selected, so there is nothing to protect."))
        }
        if config.replicas.isEmpty {
            issues.append(ConfigIssue(severity: .error, message: "No NAS destination is configured."))
        } else if config.enabledReplicas.isEmpty {
            issues.append(ConfigIssue(severity: .error, message: "Every NAS destination is disabled."))
        }

        for source in config.sources {
            let url = source.url
            guard fileManager.fileExists(atPath: url.path) else {
                issues.append(ConfigIssue(severity: .error, message: "Source “\(source.displayName)” is not available at \(url.path)."))
                continue
            }
            guard MirrorEngine.isUsableDirectory(url) else {
                issues.append(ConfigIssue(severity: .error, message: "Source “\(source.displayName)” is a file, not a folder."))
                continue
            }
            if VolumeIdentity.isOnBootVolume(url) == false {
                issues.append(ConfigIssue(severity: .warning, message: "Source “\(source.displayName)” lives on an external volume; unplugging it stops protection."))
            }
        }

        for replica in config.replicas {
            guard replica.enabled else { continue }
            let url = replica.url
            if !MirrorEngine.isUsableDirectory(url) {
                issues.append(ConfigIssue(severity: .error, message: "Replica “\(replica.displayName)” is not mounted at \(url.path)."))
            }
            if config.sources.contains(where: { contains($0.url, url) || contains(url, $0.url) }) {
                issues.append(ConfigIssue(severity: .error, message: "Replica “\(replica.displayName)” overlaps a source folder, which would copy files into themselves."))
            }
        }

        // Duplicate destinations write the same bytes twice and protect nothing extra.
        var seen: [String: String] = [:]
        for replica in config.enabledReplicas {
            let key = replica.url.standardizedFileURL.path
            if let first = seen[key] {
                issues.append(ConfigIssue(severity: .error, message: "Replicas “\(first)” and “\(replica.displayName)” point at the same folder."))
            } else {
                seen[key] = replica.displayName
            }
        }

        let groups = VolumeIdentity.sharedVolumeGroups(config.enabledReplicas.map { ($0.displayName, $0.url) })
        for group in groups {
            issues.append(ConfigIssue(
                severity: .warning,
                message: "\(group.joined(separator: " and ")) are on the same volume, so they fail together. Real resilience needs separate NAS boxes."
            ))
        }

        if config.enabledReplicas.count == 1 {
            issues.append(ConfigIssue(severity: .warning, message: "Only one replica is enabled: a single NAS failure loses the only copy."))
        }

        if config.replicas.allSatisfy({ VolumeIdentity.isOnBootVolume($0.url) }) && !config.replicas.isEmpty {
            issues.append(ConfigIssue(severity: .warning, message: "Every replica resolves to the boot disk — the shares are probably not mounted."))
        }

        if config.mirrorDeletions && config.sources.isEmpty {
            issues.append(ConfigIssue(severity: .warning, message: "Deletions are mirrored, but no source is configured."))
        }

        // Errors first, then warnings, each keeping the order it was discovered in.
        return issues.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.severity == rhs.element.severity { return lhs.offset < rhs.offset }
                return lhs.element.severity == .error
            }
            .map(\.element)
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = parent.standardizedFileURL.path
        let c = child.standardizedFileURL.path
        if p == c { return true }
        return c.hasPrefix(p + "/")
    }
}
