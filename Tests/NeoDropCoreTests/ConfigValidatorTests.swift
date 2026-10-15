import XCTest
@testable import NeoDropCore

final class ConfigValidatorTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox(name: "validator", replicaCount: 2)
    }

    override func tearDown() {
        sandbox = nil
    }

    private func messages(_ config: AppConfig) -> [String] {
        ConfigValidator.validate(config).map(\.message)
    }

    private func errors(_ config: AppConfig) -> [String] {
        ConfigValidator.validate(config).filter { $0.severity == .error }.map(\.message)
    }

    func testEmptyConfigReportsBothMissingPieces() {
        let found = errors(AppConfig())
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.contains { $0.contains("source folder") })
        XCTAssertTrue(found.contains { $0.contains("NAS destination") })
    }

    func testValidConfigHasNoErrors() {
        XCTAssertTrue(errors(sandbox.config()).isEmpty)
    }

    func testErrorsAreListedBeforeWarnings() {
        var config = AppConfig()
        config.sources = [SourceRoot(name: "Gone", path: "/tmp/neodrop-missing-\(UUID().uuidString)")]
        let issues = ConfigValidator.validate(config)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertTrue(issues.drop(while: { $0.severity == .error }).allSatisfy { $0.severity == .warning })
    }

    func testMissingSourceIsAnError() {
        var config = sandbox.config()
        config.sources = [SourceRoot(name: "Gone", path: "/tmp/neodrop-missing-\(UUID().uuidString)")]
        XCTAssertTrue(errors(config).contains { $0.contains("is not available") })
    }

    func testMissingReplicaIsAnError() {
        var config = sandbox.config()
        config.replicas[0].path = "/Volumes/neodrop-missing-\(UUID().uuidString)"
        XCTAssertTrue(errors(config).contains { $0.contains("is not mounted") })
    }

    func testSourceThatIsAFileIsAnError() throws {
        let file = sandbox.root.appendingPathComponent("a-file.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        var config = sandbox.config()
        config.sources = [SourceRoot(name: "File", path: file.path)]
        XCTAssertTrue(errors(config).contains { $0.contains("is a file, not a folder") })
    }

    func testReplicaInsideSourceIsRejected() {
        var config = sandbox.config()
        config.replicas = [Replica(name: "Recursive", path: sandbox.source.appendingPathComponent("inner").path)]
        XCTAssertTrue(errors(config).contains { $0.contains("overlaps a source folder") })
    }

    func testSourceInsideReplicaIsRejected() throws {
        let replica = sandbox.replicaURLs[0]
        let nested = replica.appendingPathComponent("Inside")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        var config = sandbox.config()
        config.sources = [SourceRoot(name: "Nested", path: nested.path)]
        XCTAssertTrue(errors(config).contains { $0.contains("overlaps a source folder") })
    }

    func testDuplicateReplicaPathsAreRejected() {
        var config = sandbox.config()
        config.replicas[1].path = config.replicas[0].path
        XCTAssertTrue(errors(config).contains { $0.contains("point at the same folder") })
    }

    func testAllReplicasDisabledIsAnError() {
        var config = sandbox.config()
        for index in config.replicas.indices { config.replicas[index].enabled = false }
        XCTAssertTrue(errors(config).contains { $0.contains("Every NAS destination is disabled") })
    }

    func testSingleReplicaWarnsAboutNoRedundancy() {
        var config = sandbox.config()
        config.replicas = [config.replicas[0]]
        XCTAssertTrue(messages(config).contains { $0.contains("Only one replica") })
    }

    /// Two replicas on the same volume is the classic false sense of safety.
    func testReplicasOnTheSameVolumeWarn() {
        var config = sandbox.config()
        // Both test replicas live in the same temp directory, i.e. the same volume.
        let warnings = messages(config)
        XCTAssertTrue(warnings.contains { $0.contains("same volume") }, "expected a shared-volume warning, got: \(warnings)")
    }

    func testDisabledReplicasAreNotChecked() {
        var config = sandbox.config()
        config.replicas[0].path = "/Volumes/neodrop-missing-\(UUID().uuidString)"
        config.replicas[0].enabled = false
        XCTAssertFalse(errors(config).contains { $0.contains("is not mounted") })
    }

    func testReplicaCountsTowardsBootVolumeWarning() {
        // Every replica in the sandbox is on the boot volume, which should be called out.
        XCTAssertTrue(messages(sandbox.config()).contains { $0.contains("boot disk") })
    }

    // MARK: - Two-way folders

    private func vaultSandbox() throws -> (local: URL, vault: URL) {
        let local = sandbox.root.appendingPathComponent("TwoWay/Folder")
        let vault = sandbox.root.appendingPathComponent("NAS/Vault")
        for url in [local, vault] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return (local, vault)
    }

    /// A vault-only configuration is complete. Telling someone with no mirror that they have no
    /// NAS destination would be wrong twice over: nothing is missing, and the sync would refuse to run.
    func testAVaultAloneHasNoErrors() throws {
        let (local, vault) = try vaultSandbox()
        let config = AppConfig(vaults: [VaultLink(vaultPath: vault.path, localPath: local.path)])

        XCTAssertEqual(errors(config), [])
        XCTAssertTrue(config.isConfigured)
    }

    func testVaultNestedInsideItsLocalFolderIsAnError() throws {
        let (local, _) = try vaultSandbox()
        let config = AppConfig(vaults: [VaultLink(vaultPath: local.appendingPathComponent("Vault").path, localPath: local.path)])

        XCTAssertTrue(errors(config).contains { $0.contains("nested inside one another") })
    }

    func testMissingVaultIsAnError() throws {
        let (local, _) = try vaultSandbox()
        let config = AppConfig(vaults: [VaultLink(vaultPath: "/Volumes/neodrop-missing-\(UUID().uuidString)", localPath: local.path)])

        XCTAssertTrue(errors(config).contains { $0.contains("vault") && $0.contains("is not mounted") })
    }

    func testMissingLocalFolderIsAnError() throws {
        let (_, vault) = try vaultSandbox()
        let config = AppConfig(vaults: [VaultLink(
            vaultPath: vault.path,
            localPath: sandbox.root.appendingPathComponent("gone-\(UUID().uuidString)").path
        )])

        XCTAssertTrue(errors(config).contains { $0.contains("is not available") })
    }

    func testTwoVaultsPointingAtOneVaultAreAnError() throws {
        let (local, vault) = try vaultSandbox()
        let second = sandbox.root.appendingPathComponent("TwoWay/Second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let config = AppConfig(vaults: [
            VaultLink(vaultPath: vault.path, localPath: local.path),
            VaultLink(vaultPath: vault.path, localPath: second.path),
        ])

        XCTAssertTrue(errors(config).contains { $0.contains("point at the same vault") })
    }

    func testTwoVaultsSyncingOneFolderAreAnError() throws {
        let (local, vault) = try vaultSandbox()
        let other = sandbox.root.appendingPathComponent("NAS/Vault2")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let config = AppConfig(vaults: [
            VaultLink(vaultPath: vault.path, localPath: local.path),
            VaultLink(vaultPath: other.path, localPath: local.path),
        ])

        XCTAssertTrue(errors(config).contains { $0.contains("both sync the folder") })
    }

    func testVaultInsideAReplicaIsAWarning() throws {
        let (local, _) = try vaultSandbox()
        let vault = sandbox.replicaURLs[0].appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        var config = sandbox.config()
        config.vaults = [VaultLink(vaultPath: vault.path, localPath: local.path)]

        XCTAssertTrue(messages(config).contains { $0.contains("inside replica") })
    }

    func testADisabledVaultIsNotChecked() throws {
        let (local, _) = try vaultSandbox()
        let config = AppConfig(vaults: [VaultLink(
            vaultPath: "/Volumes/neodrop-missing-\(UUID().uuidString)",
            localPath: local.path,
            enabled: false
        )])

        XCTAssertFalse(errors(config).contains { $0.contains("is not mounted") })
    }
}
