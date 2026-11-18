import Testing
@testable import SkylightMenuCore

@Test func incompleteLaunchOpensWelcomeOnce() {
    var state = LaunchPresentationState()
    let first = state.shouldOpenWelcome(setupComplete: false)
    let second = state.shouldOpenWelcome(setupComplete: false)
    #expect(first)
    #expect(!second)
}

@Test func completedLaunchOpensNothing() {
    var state = LaunchPresentationState()
    let first = state.shouldOpenWelcome(setupComplete: true)
    let second = state.shouldOpenWelcome(setupComplete: false)
    #expect(!first)
    #expect(!second)
}
