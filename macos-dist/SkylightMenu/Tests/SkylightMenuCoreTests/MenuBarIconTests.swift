import Testing
@testable import SkylightMenuCore

@Suite("MenuBarIcon")
struct MenuBarIconTests {
    @Test("not connected always reads idle regardless of other flags")
    func notConnectedAlwaysReadsIdleRegardlessOfOtherFlags() {
        #expect(MenuBarIcon.glyph(connected: false, streaming: false, pendingPairing: false) == .monitor)
        #expect(MenuBarIcon.glyph(connected: false, streaming: true, pendingPairing: true) == .monitor)
    }

    @Test("connected idle shows bare glyph")
    func connectedIdleShowsBareGlyph() {
        #expect(MenuBarIcon.glyph(connected: true, streaming: false, pendingPairing: false) == .monitor)
    }

    @Test("connected streaming shows filled glyph")
    func connectedStreamingShowsFilledGlyph() {
        #expect(MenuBarIcon.glyph(connected: true, streaming: true, pendingPairing: false) == .monitorPlay)
    }

    @Test("connected pending-pairing shows badged glyph")
    func connectedPendingPairingShowsBadgedGlyph() {
        #expect(
            MenuBarIcon.glyph(connected: true, streaming: false, pendingPairing: true)
                == .userRoundPlus
        )
    }

    /// A pending pairing request must stay visible even mid-stream -- it is the more actionable
    /// state and must not be silently masked by the streaming badge.
    @Test("pending pairing takes precedence over streaming")
    func pendingPairingTakesPrecedenceOverStreaming() {
        #expect(
            MenuBarIcon.glyph(connected: true, streaming: true, pendingPairing: true)
                == .userRoundPlus
        )
    }
}
