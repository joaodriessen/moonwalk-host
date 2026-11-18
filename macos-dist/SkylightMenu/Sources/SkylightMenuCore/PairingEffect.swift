import Foundation

/// Data describing a side effect `PairingReducer` wants run -- the reducer itself stays pure
/// (no SwiftUI/Timer/XPC imports); `PairingModel` (the `SkylightMenu` executable target) is the
/// sole interpreter (design-pairing-statemachine.md §1.3/§4.1).
///
/// `.runPairFlow` and `.startVerification` deliberately hide the EXISTING multi-XPC sequencing --
/// they are plumbing the reducer doesn't need to model, so the reducer tests the state MACHINE,
/// not the wiring:
/// - `.runPairFlow` does, in order (verbatim today's `submitIfComplete`): snapshot
///   `fetchPairedClientsList` -> if nil, `.snapshotUnavailable`; else drain a stale outcome via a
///   discarded `fetchPairOutcome` (preserves the `edf95ccf` retry fix) -> `host.pair(...)` -> on
///   `success == false`, `.phase1Rejected`; on `success == true`, `.enteredVerification` with the
///   pre-submit snapshot as `baseline`. A 15s internal watchdog dispatches `.phase1Rejected` if no
///   callback ever lands (closes dossier bug #9, "`.submitting` had no timeout of its own").
/// - `.startVerification` runs today's 1.5s poll: each tick consults `fetchPairOutcome` first
///   for the selected request; only its terminal decision dispatches `.outcomeResolved`.
///   After the 30s deadline, one final target-specific poll precedes `.verificationFailed`.
public enum PairingEffect: Equatable, Sendable {
    case focusFirstDigit
    case armPairingWindow
    case fetchPending
    /// 2s timer: re-arm the host's eligibility window + refresh the pending list (preserves the
    /// "F2" continuous re-arm fix, dossier §6 item 5).
    case startPendingPolling
    case cancelPendingPolling
    case runPairFlow(generation: Int, target: String, pin: String, name: String)
    case startVerification(generation: Int, target: String, baseline: Set<String>)
    case cancelVerification
    /// 1.2s -> `.autoDismissElapsed`.
    case scheduleAutoDismiss(generation: Int)
    /// Fired ONCE, alongside `.scheduleAutoDismiss`, the moment `.outcomeResolved(paired: true)`
    /// lands: refreshes `HostConnection.paired` (the list `SettingsView`'s Devices tab renders)
    /// so the just-paired device appears without the owner having to bounce to another tab first
    /// (dossier-devicelist-refresh.md §5). Carries `generation` to match the sibling effect's
    /// shape, even though the interpreter has no async gap of its own to guard here -- see
    /// `PairingModel.run(_:)`.
    case refreshPairedClients(generation: Int)
    case dismissWindow
}
