import Foundation
import Testing
@testable import SkylightMenuCore

private func withDataHome(_ run: (URL, FileManager) throws -> Void) throws {
    let files = FileManager.default
    let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try files.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: home) }
    try run(home, files)
}

private func legacyConfiguration(_ home: URL, files: FileManager) throws -> URL {
    let legacy = home.appendingPathComponent(".config/sunshine")
    try files.createDirectory(at: legacy, withIntermediateDirectories: true)
    try "pkey = \(legacy.path)/credentials/key.pem\n".write(
        to: legacy.appendingPathComponent("sunshine.conf"), atomically: true, encoding: .utf8)
    try Data("paired device".utf8).write(to: legacy.appendingPathComponent("sunshine_state.json"))
    return legacy
}

@Test func freshSkylightDoesNotImportSunshine() throws {
    try withDataHome { home, files in
        _ = try legacyConfiguration(home, files: files)
        #expect(try !SkylightDataPaths.prepare(home: home, legacyInstallation: false))
        #expect(!files.fileExists(atPath: SkylightDataPaths.configuration(home: home)
            .appendingPathComponent("sunshine_state.json").path))
    }
}

@Test func knownLegacySkylightIsCopiedAndRebasedWithoutChangingSource() throws {
    try withDataHome { home, files in
        let legacy = try legacyConfiguration(home, files: files)
        let original = try Data(contentsOf: legacy.appendingPathComponent("sunshine.conf"))
        #expect(try SkylightDataPaths.prepare(home: home, legacyInstallation: true))
        let owned = SkylightDataPaths.configuration(home: home)
        #expect(try String(contentsOf: owned.appendingPathComponent("sunshine.conf"), encoding: .utf8)
            == "pkey = \(owned.path)/credentials/key.pem\n")
        #expect(try Data(contentsOf: owned.appendingPathComponent("sunshine_state.json")) == Data("paired device".utf8))
        #expect(try Data(contentsOf: legacy.appendingPathComponent("sunshine.conf")) == original)
        #expect(try !SkylightDataPaths.prepare(home: home, legacyInstallation: true))
        try SkylightDataPaths.removeOwnedData(home: home)
        #expect(try Data(contentsOf: legacy.appendingPathComponent("sunshine.conf")) == original)
        #expect(files.fileExists(atPath: legacy.appendingPathComponent("sunshine_state.json").path))
    }
}

@Test func existingOwnedConfigurationWinsAndDefaultsFillOnlyMissingFiles() throws {
    try withDataHome { home, files in
        _ = try legacyConfiguration(home, files: files)
        let owned = SkylightDataPaths.configuration(home: home)
        try files.createDirectory(at: owned, withIntermediateDirectories: true)
        try "chosen".write(to: owned.appendingPathComponent("sunshine.conf"), atomically: true, encoding: .utf8)
        let defaults = home.appendingPathComponent("Defaults")
        try files.createDirectory(at: defaults, withIntermediateDirectories: true)
        try "default".write(to: defaults.appendingPathComponent("sunshine.conf"), atomically: true, encoding: .utf8)
        try "apps".write(to: defaults.appendingPathComponent("apps.json"), atomically: true, encoding: .utf8)
        #expect(try !SkylightDataPaths.prepare(home: home, legacyInstallation: true, defaultsDirectory: defaults))
        #expect(try String(contentsOf: owned.appendingPathComponent("sunshine.conf"), encoding: .utf8) == "chosen")
        #expect(try String(contentsOf: owned.appendingPathComponent("apps.json"), encoding: .utf8) == "apps")
    }
}

@Test func migrationRejectsLinksInsteadOfRetainingLegacyWriteThrough() throws {
    try withDataHome { home, files in
        let legacy = try legacyConfiguration(home, files: files)
        try files.createSymbolicLink(at: legacy.appendingPathComponent("linked"),
                                    withDestinationURL: legacy.appendingPathComponent("sunshine.conf"))
        #expect(throws: (any Error).self) {
            try SkylightDataPaths.prepare(home: home, legacyInstallation: true)
        }
        #expect(!files.fileExists(atPath: SkylightDataPaths.configuration(home: home).path))
        #expect(files.fileExists(atPath: legacy.appendingPathComponent("sunshine.conf").path))
    }
}

@Test func upgradeImportsEvenWhenInstallScriptsAlreadyCreatedLogs() throws {
    try withDataHome { home, files in
        let legacy = try legacyConfiguration(home, files: files)
        let owned = SkylightDataPaths.configuration(home: home)
        try files.createDirectory(at: owned, withIntermediateDirectories: true)
        try Data("prior log".utf8).write(to: owned.appendingPathComponent("launchd.out.log.1"))
        #expect(try SkylightDataPaths.prepare(home: home, legacyInstallation: true))
        #expect(try Data(contentsOf: owned.appendingPathComponent("sunshine_state.json")) == Data("paired device".utf8))
        #expect(try Data(contentsOf: owned.appendingPathComponent("previous-logs/launchd.out.log.1")) == Data("prior log".utf8))
        #expect(files.fileExists(atPath: legacy.appendingPathComponent("sunshine.conf").path))
    }
}

@Test func incompleteOwnedDataIsNotOverwrittenByAnImport() throws {
    try withDataHome { home, files in
        _ = try legacyConfiguration(home, files: files)
        let owned = SkylightDataPaths.configuration(home: home)
        try files.createDirectory(at: owned, withIntermediateDirectories: true)
        try Data("owned identity".utf8).write(to: owned.appendingPathComponent("sunshine_state.json"))
        #expect(throws: (any Error).self) {
            try SkylightDataPaths.prepare(home: home, legacyInstallation: true)
        }
        #expect(try Data(contentsOf: owned.appendingPathComponent("sunshine_state.json")) == Data("owned identity".utf8))
    }
}

@Test func daemonCreatedEmptyConfigurationDoesNotSilentlySkipMigration() throws {
    try withDataHome { home, files in
        _ = try legacyConfiguration(home, files: files)
        let owned = SkylightDataPaths.configuration(home: home)
        try files.createDirectory(at: owned, withIntermediateDirectories: true)
        try Data().write(to: owned.appendingPathComponent("sunshine.conf"))
        #expect(throws: (any Error).self) {
            try SkylightDataPaths.prepare(home: home, legacyInstallation: true)
        }
        #expect(try Data(contentsOf: owned.appendingPathComponent("sunshine.conf")).isEmpty)
    }
}

@Test func firstRunDefaultsExistBeforeStartingHostAndLegacyDetectionUsesOwnDefaults() throws {
    try withDataHome { home, files in
        let defaults = home.appendingPathComponent("Defaults")
        try files.createDirectory(at: defaults, withIntermediateDirectories: true)
        for name in ["sunshine.conf", "apps.json"] {
            try Data(name.utf8).write(to: defaults.appendingPathComponent(name))
        }
        try SkylightDataPaths.prepare(home: home, legacyInstallation: false, defaultsDirectory: defaults)
        for name in ["sunshine.conf", "apps.json"] {
            #expect(try Data(contentsOf: SkylightDataPaths.configuration(home: home).appendingPathComponent(name)) == Data(name.utf8))
        }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        #expect(!SkylightDataPaths.isLegacyInstallation(defaults: preferences))
        preferences.set(true, forKey: "skylight.firstRunComplete")
        #expect(SkylightDataPaths.isLegacyInstallation(defaults: preferences))
        preferences.removeObject(forKey: "skylight.firstRunComplete")
        preferences.set("old-host", forKey: "skylight.registeredHostExecutablePath")
        #expect(SkylightDataPaths.isLegacyInstallation(defaults: preferences))
    }
}
