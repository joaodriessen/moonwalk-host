import Foundation

/// Pure pairing state-machine value (design-pairing-statemachine.md §1.1). Rebuild motivation:
/// the OLD `PairingSheet` held 11 independent `@State` vars bound to a singleton `Window` scene
/// whose state survives every open/close, with no "we just opened, start clean" contract -- 7
/// historical bugs (dossier-pairing-statemachine.md §6) all trace to that shape. Collapsing every
/// piece of session-scoped state into ONE value whose `step` is an enum carrying its own payload
/// makes "a stale field survived a reset" unrepresentable: you cannot be `.verifying` without a
/// `target` (it lives in `Attempt`, inside the step), and `.picking`'s payload has no such field
/// to leak into. See `PairingEvent`/`PairingEffect`/`PairingReducer` for the rest of the machine.
public struct PairingState: Equatable, Sendable {
    /// Monotone attempt/session token. Bumped on `.sheetOpened`, `.sheetClosed`,
    /// `.submitRequested` (successful transition to `.submitting`), and `.denyRequested`. Every
    /// effect-callback event carries the generation it was issued under; `PairingReducer` DROPS
    /// any such event whose generation != `state.generation`. This is the structural cancellation
    /// that makes a stale XPC/timer callback landing after a reset a no-op (closes dossier bugs
    /// #7 reopen-after-paired, #8 deny-mid-flight, and the auto-dismiss-after-reopen race).
    public var generation: Int

    /// Always-present form buffer + host-sourced list. Meaningful only while `.picking`/
    /// `.submitting`; rendering ignores them in `.verifying`/`.paired`, and `.sheetOpened` clears
    /// them regardless of when it fires.
    public var pending: [PendingPairing]
    public var pendingPhase: RemoteListPhase = .available
    /// uniqueid the owner tapped; nil = nothing selected. SECURITY (mandatory-target gate, mirrors
    /// `nvhttp::pin()`'s own unconditional refusal of an empty target): `canSubmit` below requires
    /// this to be non-nil even when `pending.count == 1` -- there is no "sole eligible session
    /// auto-apply" path anywhere in this machine.
    public var selected: String?
    /// Normalized 0-4 digit string (the view keeps the OTP-box editing ergonomics; this is what it
    /// reports on every edit).
    public var pin: String
    public var deviceName: String

    public var step: Step

    public enum Step: Equatable, Sendable {
        /// Fresh entry OR post-failure -- folds the old `.idle` state plus every inline-error
        /// variant into one case with a payload, so "is there a notice to show" and "are we in the
        /// picking UI" can never disagree.
        case picking(Notice?)
        /// `pair()` XPC (phase 1 only) is in flight for `Attempt`.
        case submitting(Attempt)
        /// Phase-1 accepted; polling the REAL (phase-4) outcome for `Attempt`, using `baseline` as
        /// the pre-submit paired-uuid snapshot retained for availability checks, never success.
        case verifying(Attempt, baseline: Set<String>)
        /// Terminal success; auto-dismiss is scheduled, and (per `.denyRequested`, valid from ANY
        /// step) there is also always a manual exit -- `.paired` is never a dead end.
        case paired
    }

    /// Everything an in-flight attempt needs, CARRIED IN THE STEP so it cannot leak into
    /// `.picking` the way `submittedTargetUniqueid` used to survive independently of `phase` in
    /// the old 11-`@State`-var machine. Kills the "target points at nothing / a stale target"
    /// class at the type level: you cannot construct a `.verifying`/`.submitting` step without one.
    public struct Attempt: Equatable, Sendable {
        /// Was `submittedTargetUniqueid` / `selectedTarget` at submit time.
        public var target: String
        /// Was `waitingDeviceLabel` (the source IP), shown in the verifying UI.
        public var deviceLabel: String

        public init(target: String, deviceLabel: String) {
            self.target = target
            self.deviceLabel = deviceLabel
        }
    }

    public enum Notice: Equatable, Sendable {
        /// Host refused phase 1 (no armed window / no target / caps). Non-destructive: target and
        /// device name stay put, only the PIN is cleared -- the owner just re-enters the code.
        case phase1Rejected(String)
        /// Pre-submit paired-list snapshot fetch failed. Nothing was submitted host-side, so
        /// EVERYTHING is kept (pin, name, selection) and no verification starts -- this is the
        /// host-availability guard. Only a target-specific terminal outcome can establish success.
        case serviceUnreachable
        /// The host reports an unsuccessful handshake; its current Boolean API also covers
        /// expiry, so this must not be described as proof that the PIN was wrong.
        case didntPair
        case verificationExpired
    }

    public init(
        generation: Int,
        pending: [PendingPairing],
        selected: String?,
        pin: String,
        deviceName: String,
        step: Step
    ) {
        self.generation = generation
        self.pending = pending
        self.selected = selected
        self.pin = pin
        self.deviceName = deviceName
        self.step = step
    }

    /// The reset-on-open transition target (design §3): `PairingReducer.reduce(anyState,
    /// .sheetOpened)` is DEFINED to return exactly this, with `generation` bumped -- reset can't
    /// "forget a field" because the whole value is replaced, not patched.
    public static func initial(generation: Int = 0) -> PairingState {
        var state = PairingState(generation: generation, pending: [], selected: nil, pin: "", deviceName: "", step: .picking(nil))
        state.pendingPhase = .loading
        return state
    }

    // MARK: - Pure derived predicates

    public var isComplete: Bool {
        pin.count == 4 && !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// SECURITY: gates on `selected != nil` UNCONDITIONALLY (mirrors `nvhttp::pin()`'s mandatory-
    /// target backstop) AND on `step == .picking` (replaces the old, misfiring `phase == .idle`
    /// re-entrancy guard -- dossier §2 noted it "fires on the wrong state"). No "0/1 eligible ->
    /// submit blind" path exists, and a second submit while already `.submitting` is structurally
    /// a no-op (this returns `false`, so `PairingReducer` treats `.submitRequested` as a no-op).
    public var canSubmit: Bool {
        if case .picking = step { return isComplete && selected != nil && pendingPhase == .available }
        return false
    }
}
