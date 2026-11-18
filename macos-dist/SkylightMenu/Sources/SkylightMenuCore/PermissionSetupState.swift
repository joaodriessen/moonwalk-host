public enum PermissionGrantState: Equatable, Sendable {
    case checking
    case required
    case granted
}

public enum PermissionSetupEffect: Equatable, Sendable {
    case requestScreenRecording
    case requestAccessibility
    case restartHost
}

public enum PermissionSetupEvent: Equatable, Sendable {
    case observed(screen: PermissionGrantState, accessibility: PermissionGrantState)
    case requestScreenRecording
    case requestAccessibility
    case hostRestarted
}

public struct PermissionSetupState: Equatable, Sendable {
    public private(set) var screen: PermissionGrantState = .checking
    public private(set) var accessibility: PermissionGrantState = .checking
    public private(set) var verifyingRestart = false
    private var hasObservedScreen = false

    public init() {}

    public var completionScreen: PermissionGrantState {
        verifyingRestart ? .checking : screen
    }

    public var completionAccessibility: PermissionGrantState {
        verifyingRestart ? .checking : accessibility
    }

    @discardableResult
    public mutating func reduce(event: PermissionSetupEvent) -> [PermissionSetupEffect] {
        switch event {
        case .requestScreenRecording:
            return [.requestScreenRecording]
        case .requestAccessibility:
            return [.requestAccessibility]
        case .observed(let newScreen, let newAccessibility):
            let shouldRestart = hasObservedScreen && screen == .required && newScreen == .granted
            screen = newScreen
            accessibility = newAccessibility
            hasObservedScreen = true
            if shouldRestart, !verifyingRestart {
                verifyingRestart = true
                return [.restartHost]
            }
            return []
        case .hostRestarted:
            verifyingRestart = false
            return []
        }
    }
}
