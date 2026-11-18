public enum SettingsLoadPhase: Equatable, Sendable {
    case idle
    case waitingForHost
    case loading
    case loaded
    case unavailable
}

public enum SettingsLoadEffect: Equatable, Sendable {
    case load(generation: Int)
}

public enum SettingsLoadEvent: Equatable, Sendable {
    case appeared(connected: Bool)
    case connectionChanged(connected: Bool)
    case connectionFailed
    case loadFinished(generation: Int, success: Bool)
}

public struct SettingsLoadState: Equatable, Sendable {
    public private(set) var phase: SettingsLoadPhase = .idle
    private var generation = 0

    public init() {}

    @discardableResult
    public mutating func reduce(event: SettingsLoadEvent) -> [SettingsLoadEffect] {
        switch event {
        case .appeared(let connected):
            guard connected else {
                phase = .waitingForHost
                return []
            }
            guard phase != .loading else { return [] }
            generation += 1
            phase = .loading
            return [.load(generation: generation)]
        case .connectionChanged(let connected):
            guard connected else {
                phase = .waitingForHost
                return []
            }
            guard phase == .idle || phase == .waitingForHost || phase == .unavailable else { return [] }
            generation += 1
            phase = .loading
            return [.load(generation: generation)]
        case .connectionFailed:
            generation += 1
            phase = .unavailable
            return []
        case .loadFinished(let completedGeneration, let success):
            guard accepts(generation: completedGeneration) else { return [] }
            phase = success ? .loaded : .unavailable
            return []
        }
    }

    public func accepts(generation candidate: Int) -> Bool {
        candidate == generation
    }
}
