/// Preserve the last valid list when a refresh fails; failure is never a genuine empty result.
public enum RemoteListPhase: Equatable, Sendable {
    case loading, available, unavailable
}

public struct RemoteList<Element: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var values: [Element] = []
    public private(set) var phase: RemoteListPhase = .loading
    public private(set) var hasValue = false
    public init() {}
    public mutating func receive(_ result: [Element]?) {
        if let result {
            values = result
            hasValue = true
            phase = .available
        } else {
            phase = .unavailable
        }
    }
}
