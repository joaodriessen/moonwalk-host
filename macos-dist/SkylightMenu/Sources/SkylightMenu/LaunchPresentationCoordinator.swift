import Observation
import SwiftUI
import SkylightMenuCore

@MainActor
@Observable
final class LaunchPresentationCoordinator {
    private var state = LaunchPresentationState()

    func presentIfNeeded(firstRun: FirstRunCoordinator, openWindow: OpenWindowAction) {
        guard state.shouldOpenWelcome(setupComplete: firstRun.isComplete) else { return }
        WindowActivator.open(id: SkylightMenuApp.firstRunWindowID, using: openWindow)
    }
}
