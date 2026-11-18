import Testing
@testable import SkylightMenuCore

@Test func incompleteSetupOffersRecovery() {
    #expect(SetupMenuAction.title(setupComplete: false, pendingPairing: false) == "Finish Setup…")
}

@Test func completedSetupOffersPairing() {
    #expect(SetupMenuAction.title(setupComplete: true, pendingPairing: false) == "Pair New Device…")
    #expect(SetupMenuAction.title(setupComplete: true, pendingPairing: true) == "Pair New Device… •")
}
