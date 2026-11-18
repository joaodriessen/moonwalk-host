import Foundation

/// Skylight owns this directory. The legacy Sunshine directory is only a copy source.
public enum SkylightDataPaths {
    public static func configuration(home: URL) -> URL {
        home.appendingPathComponent(".config/skylight", isDirectory: true)
    }

    public static func applicationSupport(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Skylight", isDirectory: true)
    }

    public static func isLegacyInstallation(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: "skylight.firstRunComplete") ||
            defaults.string(forKey: "skylight.registeredHostExecutablePath") != nil
    }

    /// Copy a known previous Skylight installation atomically, without modifying Sunshine.
    /// Fresh installs do not infer ownership merely from finding a Sunshine configuration.
    @discardableResult
    public static func prepare(
        home: URL,
        legacyInstallation: Bool,
        defaultsDirectory: URL? = nil,
        files: FileManager = .default
    ) throws -> Bool {
        let owned = configuration(home: home)
        let legacy = home.appendingPathComponent(".config/sunshine", isDirectory: true)
        var imported = false
        let ownedConfig = owned.appendingPathComponent("sunshine.conf")
        if legacyInstallation, files.fileExists(atPath: legacy.appendingPathComponent("sunshine.conf").path),
           let size = (try? files.attributesOfItem(atPath: ownedConfig.path)[.size]) as? NSNumber,
           size.intValue == 0 {
            throw NSError(domain: "SkylightSetup", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "An empty Moonwalk Host configuration conflicts with previous settings. No settings were replaced. Restore the intended configuration before starting Moonwalk Host."])
        }
        if !files.fileExists(atPath: owned.appendingPathComponent("sunshine.conf").path), legacyInstallation,
           files.fileExists(atPath: legacy.appendingPathComponent("sunshine.conf").path) {
            // A linked directory/file would retain write-through references to the old data.
            try rejectSymbolicLinks(in: legacy, files: files)
            let staging = owned.deletingLastPathComponent()
                .appendingPathComponent(".skylight-import-\(UUID().uuidString)")
            let priorLogs = owned.deletingLastPathComponent()
                .appendingPathComponent(".skylight-logs-\(UUID().uuidString)")
            defer { try? files.removeItem(at: staging) }
            if files.fileExists(atPath: owned.path) {
                try rejectSymbolicLinks(in: owned, files: files)
                let entries = try files.contentsOfDirectory(atPath: owned.path)
                let logNames = ["sunshine.log", "launchd.out.log", "launchd.err.log"]
                guard entries.allSatisfy({ name in
                    name == ".skylight-logrotate.lock" || logNames.contains(where: { base in
                        name == base || ["1", "2", "3"].contains(where: { suffix in name == base + "." + suffix })
                    })
                }) else { throw CocoaError(.fileWriteFileExists) }
            }
            try files.copyItem(at: legacy, to: staging)
            let config = staging.appendingPathComponent("sunshine.conf")
            let text = try String(contentsOf: config, encoding: .utf8)
            // Legacy absolute paths to copied credentials/logs must follow the copy too.
            let rebased = text.replacingOccurrences(of: legacy.path + "/", with: owned.path + "/")
            try rebased.write(to: config, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            let hadLogs = files.fileExists(atPath: owned.path)
            if hadLogs { try files.moveItem(at: owned, to: priorLogs) }
            do {
                try files.moveItem(at: staging, to: owned)
            } catch {
                if hadLogs { try? files.moveItem(at: priorLogs, to: owned) }
                throw error
            }
            if hadLogs {
                // Keep any log-only directory created by older install/rotation scripts.
                try files.moveItem(at: priorLogs, to: owned.appendingPathComponent("previous-logs"))
            }
            imported = true
        }
        try files.createDirectory(at: owned, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        if let defaultsDirectory {
            for name in ["sunshine.conf", "apps.json"] {
                let destination = owned.appendingPathComponent(name)
                guard !files.fileExists(atPath: destination.path) else { continue }
                // Write defaults atomically before the host is allowed to create an empty file.
                let data = try Data(contentsOf: defaultsDirectory.appendingPathComponent(name))
                try data.write(to: destination, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        }
        return imported
    }

    public static func removeOwnedData(home: URL, files: FileManager = .default) throws {
        for path in [configuration(home: home), applicationSupport(home: home)] {
            if files.fileExists(atPath: path.path) { try files.removeItem(at: path) }
        }
    }

    private static func rejectSymbolicLinks(in directory: URL, files: FileManager) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
        if try directory.resourceValues(forKeys: keys).isSymbolicLink == true {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard let enumerator = files.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let item as URL in enumerator {
            if try item.resourceValues(forKeys: keys).isSymbolicLink == true {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
    }
}
