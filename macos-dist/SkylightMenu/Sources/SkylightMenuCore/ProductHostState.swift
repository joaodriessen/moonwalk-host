import Foundation

public struct ConfigurationState: Decodable, Sendable {
    public let revision: String
    public let values: [String: String]
    public let runningValues: [String: String]
    public let snapshotKeys: Set<String>
}

public struct HostConnectionInfo: Decodable, Sendable {
    public let basePort: Int
    public let httpReady: Bool
    public let httpsReady: Bool
    public let rtspReady: Bool
    public var ready: Bool { httpReady && httpsReady && rtspReady }
    public var unavailableListeners: [String] {
        [("Discovery/control", httpReady), ("Paired control", httpsReady), ("Stream setup", rtspReady)]
            .filter { !$0.1 }.map(\.0)
    }
}

public struct SoundTestResult: Decodable, Sendable {
    public let source: String
    public let message: String
    public let peak: Float?
    public let samples: Int?
    public let cancelled: Bool?
}
