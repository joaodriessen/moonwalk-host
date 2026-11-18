import Foundation

/// The total input alphabet for `PairingReducer` (design-pairing-statemachine.md §1.2). Includes
/// the window-lifecycle events (`sheetOpened`/`sheetClosed`) the OLD machine never modeled as
/// state-machine input at all (dossier §1.3) -- that omission, not any single missing reset line,
/// is why a stale `.paired`/`.waitingForDevice` screen could survive a window reopen.
public enum PairingEvent: Equatable, Sendable {
    // Window lifecycle.
    case sheetOpened
    case sheetClosed

    // User / host-list inputs (meaningful only while `.picking`; no-ops otherwise -- the reducer
    // is total by construction, see `PairingReducer`).
    case pendingPairingsFetched([PendingPairing])
    case pendingPairingsUnavailable
    case retryPending
    case verificationFailed(generation: Int, reason: PairingVerificationFailure)
    case pinChanged(String)
    case deviceNameChanged(String)
    case deviceSelected(String)
    /// "Pair Device" tapped OR a 4th-digit paste auto-completed the PIN.
    case submitRequested
    /// "Deny"/"Done" -- valid from ANY step, the manual exit for every terminal/mid-flight state.
    case denyRequested

    // Effect callbacks. Each carries the generation it was issued under; `PairingReducer` drops
    // any whose generation != the current state's -- the structural cancellation for a stale
    // XPC/timer callback landing after a reset (dossier bugs #7, #8, and the auto-dismiss race).
    case snapshotUnavailable(generation: Int)
    case phase1Rejected(generation: Int, message: String)
    case enteredVerification(generation: Int, baseline: Set<String>)
    /// A terminal host decision for the selected request. Local expiry and unavailable
    /// service/data use verificationFailed, so they cannot be misreported as a rejected PIN.
    case outcomeResolved(generation: Int, paired: Bool)
    /// The 1.2s paired auto-close fired.
    case autoDismissElapsed(generation: Int)
}

public enum PairingVerificationFailure: Equatable, Sendable {
    case unavailable, expired
}
