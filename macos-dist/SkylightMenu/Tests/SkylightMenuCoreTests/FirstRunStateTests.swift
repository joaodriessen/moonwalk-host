import Testing
@testable import SkylightMenuCore

private func environment(
    installed: Bool = true,
    config: Bool = true,
    service: FirstRunEnvironment.Service = .registered,
    availability: FirstRunEnvironment.HostAvailability = .connected,
    screen: PermissionGrantState = .granted,
    accessibility: PermissionGrantState = .granted
) -> FirstRunEnvironment {
    .init(
        installedInApplications: installed,
        configExists: config,
        service: service,
        hostAvailability: availability,
        screenRecording: screen,
        accessibility: accessibility
    )
}

@Test func appOutsideApplicationsStopsBeforeSetup() {
    var state = FirstRunState()
    #expect(state.reduce(event: .observed(environment(installed: false))) == [.offerMoveToApplications])
    #expect(state.phase == .moveToApplications)
}

@Test func missingConfigCreatesDefaultsButExistingConfigIsPreserved() {
    var missing = FirstRunState()
    #expect(missing.reduce(event: .observed(environment(config: false))) == [.createDefaultConfiguration])
    #expect(missing.phase == .creatingConfiguration)

    var existing = FirstRunState()
    #expect(existing.reduce(event: .observed(environment())) == [])
    #expect(existing.phase == .readyToPair)
}

@Test func serviceRegistrationAndApprovalAreSeparateSteps() {
    var unregistered = FirstRunState()
    #expect(unregistered.reduce(event: .observed(environment(service: .notRegistered))) == [.registerService])
    #expect(unregistered.phase == .registerService)

    var approval = FirstRunState()
    #expect(approval.reduce(event: .observed(environment(service: .requiresApproval))) == [])
    #expect(approval.phase == .approveService)
}

@Test func permissionsAdvanceOneHonestStepAtATime() {
    var screen = FirstRunState()
    _ = screen.reduce(event: .observed(environment(screen: .required, accessibility: .required)))
    #expect(screen.phase == .permissions)

    var checking = FirstRunState()
    _ = checking.reduce(event: .observed(environment(screen: .checking, accessibility: .checking)))
    #expect(checking.phase == .permissions)
}

@Test func registeredServiceWaitsForValidatedHost() {
    var state = FirstRunState()
    _ = state.reduce(event: .observed(environment(availability: .connecting)))
    #expect(state.phase == .waitingForHost)
}

@Test func offlineHostBecomesRetryableFailure() {
    var state = FirstRunState()
    _ = state.reduce(event: .observed(environment(availability: .offline)))
    #expect(state.phase == .failed("Moonwalk Host’s streaming service did not start. Try again."))
    _ = state.reduce(event: .retry)
    #expect(state.phase == .evaluating)
}

@Test func failureCanRetryWithoutDiscardingObservedProgress() {
    var state = FirstRunState()
    _ = state.reduce(event: .observed(environment(service: .notRegistered)))
    _ = state.reduce(event: .operationFailed("Registration failed"))
    #expect(state.phase == .failed("Registration failed"))
    #expect(state.reduce(event: .retry) == [.registerService])
    #expect(state.phase == .registerService)
}

@Test func finishingPersistsOnlyAfterReadyToPair() {
    var state = FirstRunState()
    _ = state.reduce(event: .observed(environment()))
    #expect(state.reduce(event: .finish) == [.persistCompletion])
    #expect(state.phase == .complete)
}
