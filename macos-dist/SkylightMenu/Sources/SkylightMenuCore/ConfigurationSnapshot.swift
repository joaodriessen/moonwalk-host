import Foundation

/// A settings profile contains only host-approved scalar configuration, never pairing data.
public struct ConfigurationSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: TimeInterval
    public let values: [String: String]

    public init(name: String, values: [String: String], id: String = UUID().uuidString,
                createdAt: TimeInterval = Date().timeIntervalSince1970) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.values = values
    }

    public struct Change: Identifiable, Equatable, Sendable {
        public var id: String { key }
        public let key: String
        public let before: String?
        public let after: String?
    }

    public func changes(from current: [String: String], keys: Set<String>) -> [Change] {
        keys.sorted().compactMap { key in
            current[key] == values[key] ? nil : Change(key: key, before: current[key], after: values[key])
        }
    }
}

public struct ConfigurationSnapshots: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func save(_ snapshot: ConfigurationSnapshot) throws {
        guard UUID(uuidString: snapshot.id) != nil, snapshot.name.count <= 120 else { throw CocoaError(.fileWriteInvalidFileName) }
        let files = FileManager.default
        if files.fileExists(atPath: directory.path),
           try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw CocoaError(.fileWriteNoPermission)
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
        let destination = directory.appendingPathComponent(snapshot.id + ".json")
        try data.write(to: destination, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public func load() throws -> [ConfigurationSnapshot] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 1_048_576,
                      let data = try? Data(contentsOf: url), let item = try? JSONDecoder().decode(ConfigurationSnapshot.self, from: data),
                      UUID(uuidString: item.id) != nil else { return nil }
                return item
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
