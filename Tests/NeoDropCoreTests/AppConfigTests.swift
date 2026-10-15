import XCTest
@testable import NeoDropCore

/// Configuration files outlive the build that wrote them. A key this build does not know about, or
/// one it has added since, must never turn the whole file into "no configuration" — `ConfigStore`
/// treats a failed decode as an empty config, which would silently forget every source and every
/// NAS destination the user set up.
final class AppConfigTests: XCTestCase {
    func testDecodesAConfigWrittenBeforeVaultsExisted() throws {
        let json = """
        {
          "version": 1,
          "sources": [ { "id": "11111111-1111-1111-1111-111111111111", "name": "Docs", "path": "/tmp/docs" } ],
          "replicas": [ { "id": "22222222-2222-2222-2222-222222222222", "name": "NAS1", "path": "/Volumes/NAS1/NeoDrop", "enabled": true, "priority": 0 } ],
          "watchForChanges": false,
          "mirrorDeletions": false,
          "excludes": ["*.tmp"]
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config.sources.map(\.name), ["Docs"])
        XCTAssertEqual(config.replicas.map(\.name), ["NAS1"])
        XCTAssertTrue(config.vaults.isEmpty)
        XCTAssertFalse(config.watchForChanges)
        XCTAssertFalse(config.mirrorDeletions)
        XCTAssertEqual(config.excludes, ["*.tmp"])
        // The fields the file did not mention keep the defaults they were built with.
        XCTAssertEqual(config.syncIntervalMinutes, 15)
        XCTAssertTrue(config.scheduledSync)
        XCTAssertTrue(config.hasMirrors)
        XCTAssertFalse(config.hasVaults)
    }

    func testIgnoresAKeyThisBuildDoesNotKnow() throws {
        let json = """
        {
          "version": 3,
          "sources": [],
          "replicas": [],
          "vaults": [],
          "somethingAddedLater": { "deeply": [1, 2, 3] }
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        XCTAssertFalse(config.isConfigured)
        XCTAssertTrue(config.sources.isEmpty)
    }

    func testVaultsRoundTrip() throws {
        let config = AppConfig(
            vaults: [VaultLink(name: "Shared", vaultPath: "/Volumes/NAS/Shared", localPath: "/Users/me/Shared", smbURL: "smb://nas/share")]
        )

        let data = try JSONFile.encoder().encode(config)
        let decoded = try JSONFile.decoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(decoded.vaults.count, 1)
        XCTAssertEqual(decoded.vaults[0].name, "Shared")
        XCTAssertEqual(decoded.vaults[0].vaultPath, "/Volumes/NAS/Shared")
        XCTAssertEqual(decoded.vaults[0].localPath, "/Users/me/Shared")
        XCTAssertEqual(decoded.vaults[0].smbURL, "smb://nas/share")
        XCTAssertTrue(decoded.vaults[0].enabled)
        XCTAssertEqual(decoded.vaults[0].id, config.vaults[0].id)
    }

    /// A vault alone is a complete configuration: it is the mode where nothing is mirrored and
    /// everything is still protected.
    func testAVaultAloneCountsAsConfigured() {
        var config = AppConfig()
        XCTAssertFalse(config.isConfigured)
        config.vaults = [VaultLink(vaultPath: "/tmp/vault", localPath: "/tmp/local")]
        XCTAssertTrue(config.isConfigured)
        XCTAssertFalse(config.hasMirrors)
        XCTAssertTrue(config.hasVaults)
    }

    func testADisabledVaultDoesNotCountAsConfigured() {
        var config = AppConfig()
        config.vaults = [VaultLink(vaultPath: "/tmp/vault", localPath: "/tmp/local", enabled: false)]
        XCTAssertFalse(config.isConfigured)
        XCTAssertTrue(config.enabledVaults.isEmpty)
    }
}
