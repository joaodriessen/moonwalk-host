public struct FirstRunEnvironment: Equatable, Sendable {
    public enum HostAvailability: Equatable, Sendable {
        case connecting
        case connected
        case offline
    }
    public enum Service: Equatable, Sendable {
        case notRegistered
        case registered
        case requiresApproval
    }

    public let installedInApplications: Bool
    public let configExists: Bool
    public let service: Service
    public let hostAvailability: HostAvailability
    public let screenRecording: PermissionGrantState
    public let accessibility: PermissionGrantState

    public init(
        installedInApplications: Bool,
        configExists: Bool,
        service: Service,
        hostAvailability: HostAvailability,
        screenRecording: PermissionGrantState,
        accessibility: PermissionGrantState
    ) {
        self.installedInApplications = installedInApplications
        self.configExists = configExists
        self.service = service
        self.hostAvailability = hostAvailability
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }
}

public struct FirstRunState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case evaluating
        case moveToApplications
        case creatingConfiguration
        case registerService
        case approveService
        case waitingForHost
        case permissions
        case readyToPair
        case failed(String)
        case complete
    }

    public enum Event: Equatable, Sendable {
        case observed(FirstRunEnvironment)
        case operationFailed(String)
        case retry
        case finish
    }

    public enum Effect: Equatable, Sendable {
        case offerMoveToApplications
        case createDefaultConfiguration
        case registerService
        case persistCompletion
    }

    public private(set) var phase: Phase = .evaluating
    private var retryEffects: [Effect] = []

    public init() {}

    @discardableResult
    public mutating func reduce(event: Event) -> [Effect] {
        switch event {
        case .observed(let environment):
            let result = evaluate(environment)
            phase = result.phase
            retryEffects = result.effects
            return result.effects
        case .operationFailed(let message):
            phase = .failed(message)
            return []
        case .retry:
            guard case .failed = phase else { return [] }
            guard !retryEffects.isEmpty else {
                phase = .evaluating
                return []
            }
            if retryEffects.contains(.registerService) {
                phase = .registerService
            } else if retryEffects.contains(.createDefaultConfiguration) {
                phase = .creatingConfiguration
            } else if retryEffects.contains(.offerMoveToApplications) {
                phase = .moveToApplications
            }
            return retryEffects
        case .finish:
            guard phase == .readyToPair else { return [] }
            phase = .complete
            retryEffects = []
            return [.persistCompletion]
        }
    }

    private func evaluate(_ environment: FirstRunEnvironment) -> (phase: Phase, effects: [Effect]) {
        if !environment.installedInApplications {
            return (.moveToApplications, [.offerMoveToApplications])
        }
        if !environment.configExists {
            return (.creatingConfiguration, [.createDefaultConfiguration])
        }
        switch environment.service {
        case .notRegistered:
            return (.registerService, [.registerService])
        case .requiresApproval:
            return (.approveService, [])
        case .registered:
            break
        }
        if environment.hostAvailability == .offline {
            return (.failed("Moonwalk Host’s streaming service did not start. Try again."), [])
        }
        if environment.hostAvailability != .connected {
            return (.waitingForHost, [])
        }
        if environment.screenRecording != .granted || environment.accessibility != .granted {
            return (.permissions, [])
        }
        return (.readyToPair, [])
    }
}
