import Testing
@testable import SkylightMenuCore

@Suite("RestartCoordinator")
@MainActor
struct RestartCoordinatorTests {
    @Test("starts clear")
    func startsClear() {
        let restart = RestartCoordinator()
        #expect(!restart.pendingRestart)
    }

    /// Every persist-only key (design §0.1's 24 raw keys) must arm the banner.
    @Test("every persist-only key arms")
    func everyPersistOnlyKeyArms() {
        for key in RestartCoordinator.persistOnlyKeys {
            let restart = RestartCoordinator()
            restart.markPersistedChange(key: key)
            #expect(restart.pendingRestart, "\(key) should arm the restart banner")
        }
    }

    /// None of the live-5 dedicated-setter keys may ever arm the banner, even if a caller
    /// mistakenly funnels one through `markPersistedChange`.
    @Test("no live-setter key arms")
    func noLiveSetterKeyArms() {
        for key in RestartCoordinator.liveSetterKeys {
            let restart = RestartCoordinator()
            restart.markPersistedChange(key: key)
            #expect(!restart.pendingRestart, "\(key) must never arm the restart banner")
        }
    }

    /// The live-5 and persist-only sets are disjoint -- a key can't be both live and
    /// restart-gated, or the classification below would be ambiguous.
    @Test("live and persist-only sets are disjoint")
    func liveAndPersistOnlySetsAreDisjoint() {
        #expect(RestartCoordinator.liveSetterKeys.isDisjoint(with: RestartCoordinator.persistOnlyKeys))
    }

    @Test("unknown key does not arm")
    func unknownKeyDoesNotArm() {
        let restart = RestartCoordinator()
        restart.markPersistedChange(key: "not_a_real_config_key")
        #expect(!restart.pendingRestart)
    }

    @Test("clear resets after arming")
    func clearResetsAfterArming() {
        let restart = RestartCoordinator()
        restart.markPersistedChange(key: "port")
        #expect(restart.pendingRestart)
        restart.clear()
        #expect(!restart.pendingRestart)
    }

    /// Flipping a persist-only setting and back still leaves it armed (design §3.1's documented,
    /// intentionally conservative behavior) -- only `clear()` (a real restart) resets it.
    @Test("re-flip to original value stays armed")
    func reflipToOriginalValueStaysArmed() {
        let restart = RestartCoordinator()
        restart.markPersistedChange(key: "keyboard")
        restart.markPersistedChange(key: "keyboard")
        #expect(restart.pendingRestart)
    }

    @Test("persistOnlyKeys has expected count")
    func persistOnlyKeysHasExpectedCount() {
        // 24 raw keys collapse to 21 human-facing controls (video codec spans 2 keys, each
        // manual res/refresh field rides its own option key) -- see design §0.1. Plus
        // web_ui_enabled (restart-required: main.cpp reads it once at startup) = 25. Plus
        // `clipboard_sync` and `output_name` (menu-polish batch, 2026-07-18,
        // design-skylight-menu-polish.md §3.2/§3.3 -- both already in config_schema.json, zero
        // host change, round-tripping through the same generic setConfigValue path) = 27.
        // Cached Video engine selection requires restart even with its dedicated setter = 28.
        #expect(RestartCoordinator.persistOnlyKeys.count == 28)
    }
}

@Test @MainActor func everyRestartEntryUsesTheSameActiveSessionWarningPolicy() {
    #expect(RestartCoordinator.requiresConfirmation(streaming: true))
    #expect(!RestartCoordinator.requiresConfirmation(streaming: false))
}
