import Testing
@testable import SkylightMenuCore

@Test func permissionsStartChecking() {
    let state = PermissionSetupState()
    #expect(state.screen == .checking)
    #expect(state.accessibility == .checking)
    #expect(!state.verifyingRestart)
}

@Test func observationNeverRequestsPermission() {
    var state = PermissionSetupState()
    #expect(state.reduce(event: .observed(screen: .required, accessibility: .required)) == [])
}

@Test func permissionRequestsOnlyComeFromExplicitActions() {
    var state = PermissionSetupState()
    #expect(state.reduce(event: .observed(screen: .required, accessibility: .required)) == [])
    #expect(state.reduce(event: .requestScreenRecording) == [.requestScreenRecording])
    #expect(state.reduce(event: .requestAccessibility) == [.requestAccessibility])
}

@Test func screenGrantRestartsExactlyOnce() {
    var state = PermissionSetupState()
    _ = state.reduce(event: .observed(screen: .required, accessibility: .required))
    #expect(state.reduce(event: .observed(screen: .granted, accessibility: .required)) == [.restartHost])
    #expect(state.verifyingRestart)
    #expect(state.reduce(event: .observed(screen: .granted, accessibility: .required)) == [])
    #expect(state.completionScreen == .checking)
    #expect(state.completionAccessibility == .checking)
    _ = state.reduce(event: .hostRestarted)
    #expect(!state.verifyingRestart)
    #expect(state.completionScreen == .granted)
}

@Test func preGrantedScreenDoesNotRestartOnFirstObservation() {
    var state = PermissionSetupState()
    #expect(state.reduce(event: .observed(screen: .granted, accessibility: .granted)) == [])
}
