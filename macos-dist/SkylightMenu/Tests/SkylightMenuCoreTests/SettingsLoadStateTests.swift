import Testing
@testable import SkylightMenuCore

@Test func lateSettingsConnectionLoadsOnce() {
    var state = SettingsLoadState()
    #expect(state.reduce(event: .appeared(connected: false)) == [])
    #expect(state.phase == .waitingForHost)
    #expect(state.reduce(event: .connectionChanged(connected: true)) == [.load(generation: 1)])
    #expect(state.phase == .loading)
    #expect(state.reduce(event: .connectionChanged(connected: true)) == [])
}

@Test func failedSettingsLoadBecomesUnavailable() {
    var state = SettingsLoadState()
    _ = state.reduce(event: .appeared(connected: true))
    #expect(state.reduce(event: .loadFinished(generation: 1, success: false)) == [])
    #expect(state.phase == .unavailable)
}

@Test func completedSettingsLoadCanRefreshOnReappearance() {
    var state = SettingsLoadState()
    #expect(state.reduce(event: .appeared(connected: true)) == [.load(generation: 1)])
    _ = state.reduce(event: .loadFinished(generation: 1, success: true))
    #expect(state.phase == .loaded)
    #expect(state.reduce(event: .appeared(connected: true)) == [.load(generation: 2)])
}

@Test func reconnectStartsOneNewConnectionGenerationLoad() {
    var state = SettingsLoadState()
    #expect(state.reduce(event: .appeared(connected: true)) == [.load(generation: 1)])
    _ = state.reduce(event: .loadFinished(generation: 1, success: true))
    #expect(state.reduce(event: .connectionChanged(connected: false)) == [])
    #expect(state.phase == .waitingForHost)
    #expect(state.reduce(event: .connectionChanged(connected: true)) == [.load(generation: 2)])
    #expect(state.reduce(event: .connectionChanged(connected: true)) == [])
}

@Test func staleSettingsCompletionCannotBecomeCurrent() {
    var state = SettingsLoadState()
    #expect(state.reduce(event: .appeared(connected: true)) == [.load(generation: 1)])
    _ = state.reduce(event: .connectionChanged(connected: false))
    #expect(state.reduce(event: .connectionChanged(connected: true)) == [.load(generation: 2)])
    #expect(!state.accepts(generation: 1))
    _ = state.reduce(event: .loadFinished(generation: 1, success: true))
    #expect(state.phase == .loading)
    #expect(state.accepts(generation: 2))
}

@Test func offlineSettingsStopsSpinning() {
    var state = SettingsLoadState()
    _ = state.reduce(event: .appeared(connected: false))
    _ = state.reduce(event: .connectionFailed)
    #expect(state.phase == .unavailable)
}
