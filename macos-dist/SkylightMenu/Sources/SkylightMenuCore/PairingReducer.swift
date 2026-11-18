import Foundation

/// The pure pairing state machine (design-pairing-statemachine.md §2). `reduce(state, event)` has
/// no SwiftUI / Timer / XPC import and is TOTAL: every (step x event) pair returns without
/// trapping. Events not listed for the current step are no-ops (state unchanged, no effects) --
/// see `PairingStateMachineTests` for the exhaustive coverage this enables headlessly (dossier
/// bug #12: zero test coverage existed for any of this before the rebuild).
public enum PairingReducer {
    public static func reduce(_ state: PairingState, _ event: PairingEvent) -> (PairingState, [PairingEffect]) {
        // Lifecycle events apply in ALL steps (design §2.1) -- checked before the per-step
        // switch below, since these are the inputs the OLD machine never modeled as
        // state-machine input at all (dossier §1.3).
        switch event {
        case .sheetOpened:
            // THE fix for dossier bug #7 (reopen-after-paired/verifying/submitting): total
            // replacement, not a patch -- there is no field left over to forget resetting.
            return (
                .initial(generation: state.generation + 1),
                [.focusFirstDigit, .armPairingWindow, .fetchPending, .startPendingPolling]
            )

        case .sheetClosed:
            var next = state
            next.generation += 1 // invalidates any in-flight callback/timer tick
            return (next, [.cancelPendingPolling, .cancelVerification])

        case .denyRequested:
            // Valid from ANY step (dossier bug #8, deny-mid-flight): every terminal/mid-flight
            // state gets a manual exit. Only `step` moves to `.picking(nil)` here -- the full
            // scrub of pin/name/selection happens on the NEXT `.sheetOpened`, not here, since
            // this attempt is being abandoned (window closing), not resumed.
            var next = state
            next.generation += 1
            next.step = .picking(nil)
            return (next, [.cancelVerification, .cancelPendingPolling, .dismissWindow])

        default:
            break
        }

        switch state.step {
        case .picking(let notice):
            return reducePicking(state, notice: notice, event: event)
        case .submitting(let attempt):
            return reduceSubmitting(state, attempt: attempt, event: event)
        case .verifying(let attempt, let baseline):
            return reduceVerifying(state, attempt: attempt, baseline: baseline, event: event)
        case .paired:
            return reducePaired(state, event: event)
        }
    }

    // MARK: - .picking(notice)

    private static func reducePicking(
        _ state: PairingState,
        notice: PairingState.Notice?,
        event: PairingEvent
    ) -> (PairingState, [PairingEffect]) {
        switch event {
        case .pinChanged(let s):
            var next = state
            next.pin = s
            return (next, [])

        case .deviceNameChanged(let s):
            var next = state
            next.deviceName = s
            return (next, [])

        case .deviceSelected(let uniqueid):
            guard let match = state.pending.first(where: { $0.uniqueid == uniqueid }) else { return (state, []) }
            var next = state
            next.selected = uniqueid
            // Auto-populate the name field -- owner friction fix: only when the field is still
            // empty, so this never clobbers something already typed, and it's a plain default the
            // owner can freely edit. Never gates `canSubmit`/`isComplete` on its own; the existing
            // empty-name-blocks-submit behavior is untouched.
            //
            // Source preference: the connecting CLIENT'S own self-reported name
            // (`match.displayClientName`, from the pairing request's `devicename` param) when
            // non-empty, else fall back to the host-side reverse-DNS hint
            // (`match.displayHostname`), else leave empty. Both are display-only, UNTRUSTED
            // strings feeding only this editable default -- neither is ever a trust signal or
            // part of the picker's identity labeling (`PairingSheet.swift` is unchanged).
            if next.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let clientName = match.displayClientName
                next.deviceName = clientName.isEmpty ? match.displayHostname : clientName
            }
            return (next, [])

        case .pendingPairingsFetched(let list):
            var next = state
            next.pendingPhase = .available
            next.pending = list
            if let selected = next.selected, !list.contains(where: { $0.uniqueid == selected }) {
                next.selected = nil
            }
            return (next, [])

        case .pendingPairingsUnavailable:
            var next = state
            next.pendingPhase = .unavailable
            return (next, [])

        case .retryPending:
            return (state, [.armPairingWindow, .fetchPending])

        case .submitRequested:
            // The `canSubmit` + `step == .picking` guard REPLACES the old `phase == .idle`
            // re-entrancy guard (dossier §2: "fires on the wrong state"). A second
            // `.submitRequested` while already `.submitting` falls through to
            // `reduceSubmitting`, which has no case for it -- a structural no-op, not a
            // special-cased guard (T11, double-submit re-entrancy).
            guard state.canSubmit, let target = state.selected else { return (state, []) }
            // "friendly-name · IP" when the host supplied a hostname hint, else the IP alone --
            // matches the pending-list row's formatting rule (`PendingPairing.displayLabel`); the
            // IP remains present either way as the trust anchor, just de-emphasized in the view.
            let label = state.pending.first(where: { $0.uniqueid == target })?.displayLabel ?? "your device"
            let trimmedName = state.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            var next = state
            next.generation += 1
            next.step = .submitting(PairingState.Attempt(target: target, deviceLabel: label))
            return (next, [.runPairFlow(generation: next.generation, target: target, pin: state.pin, name: trimmedName)])

        default:
            return (state, [])
        }
    }

    // MARK: - .submitting(attempt)

    private static func reduceSubmitting(
        _ state: PairingState,
        attempt: PairingState.Attempt,
        event: PairingEvent
    ) -> (PairingState, [PairingEffect]) {
        switch event {
        case .snapshotUnavailable(let generation):
            guard generation == state.generation else { return (state, []) } // drop: stale gen
            var next = state
            next.step = .picking(.serviceUnreachable)
            // FIX (inline-retry-after-failure bug): every transition back to `.picking` following
            // a submit -- i.e. after `.submitRequested` already bumped `state.generation` -- must
            // re-arm the RECURRING pending-list poll, not a one-shot `.fetchPending`. The poll
            // timer `PairingModel.startPendingPolling` started under `.sheetOpened` captured the
            // OLD (pre-submit) generation; its per-tick `gen == state.generation` guard now fails
            // forever, so without this the sheet silently stops polling/re-arming the host's
            // eligibility window after ANY failure, and a re-initiated pairing from the client
            // never appears without a full window close+reopen. `.startPendingPolling` cancels the
            // stale timer and restarts it capturing the CURRENT (already-bumped) generation.
            return (next, [.startPendingPolling])

        case .phase1Rejected(let generation, let message):
            guard generation == state.generation else { return (state, []) }
            var next = state
            next.pin = ""
            next.step = .picking(.phase1Rejected(message))
            // Same fix as `.snapshotUnavailable` above -- resume the recurring poll under the
            // current generation, not a single one-shot fetch.
            return (next, [.focusFirstDigit, .startPendingPolling])

        case .enteredVerification(let generation, let baseline):
            guard generation == state.generation else { return (state, []) }
            var next = state
            next.step = .verifying(attempt, baseline: baseline)
            return (next, [.startVerification(generation: generation, target: attempt.target, baseline: baseline)])

        default:
            return (state, [])
        }
    }

    // MARK: - .verifying(attempt, baseline)

    private static func reduceVerifying(
        _ state: PairingState,
        attempt: PairingState.Attempt,
        baseline: Set<String>,
        event: PairingEvent
    ) -> (PairingState, [PairingEffect]) {
        switch event {
        case .outcomeResolved(let generation, let paired):
            guard generation == state.generation else { return (state, []) } // drop: stale gen
            var next = state
            if paired {
                next.step = .paired
                // Device-list-refresh fix (dossier-devicelist-refresh.md): this is the ONE place
                // the state machine knows "pairing just succeeded" -- pair it with a refresh of
                // `host.paired` so the Devices tab shows the new device without a tab-bounce.
                // Additive only: `.scheduleAutoDismiss` and everything else here is unchanged.
                return (next, [.cancelVerification, .scheduleAutoDismiss(generation: generation), .refreshPairedClients(generation: generation)])
            } else {
                // Reproduces the old `handleDidntPair()` exactly: digits + target cleared, back
                // to the picker, refresh the pending list.
                next.pin = ""
                next.selected = nil
                next.step = .picking(.didntPair)
                // FIX (the reported bug): was a one-shot `.fetchPending`, which left the recurring
                // poll dead (see `.snapshotUnavailable`'s comment above for the full mechanism).
                // `.startPendingPolling` resumes the 2s re-arm + pending-fetch loop under the
                // current generation, so a re-initiated pairing from the client surfaces on the
                // next tick (~2s) with no window close/reopen required.
                return (next, [.cancelVerification, .focusFirstDigit, .startPendingPolling])
            }

        case .verificationFailed(let generation, let reason):
            guard generation == state.generation else { return (state, []) }
            var next = state
            next.pin = ""
            next.selected = nil
            next.step = .picking(reason == .expired ? .verificationExpired : .serviceUnreachable)
            return (next, [.cancelVerification, .focusFirstDigit, .startPendingPolling])

        case .pendingPairingsFetched(let list):
            var next = state
            next.pendingPhase = .available
            next.pending = list
            return (next, [])

        default:
            return (state, [])
        }
    }

    // MARK: - .paired

    private static func reducePaired(
        _ state: PairingState,
        event: PairingEvent
    ) -> (PairingState, [PairingEffect]) {
        switch event {
        case .autoDismissElapsed(let generation):
            guard generation == state.generation else { return (state, []) }
            // The gen guard here fixes a real edge: paired -> auto-close scheduled -> owner
            // reopens within 1.2s -> `.sheetOpened` bumps generation -> this stale
            // `.autoDismissElapsed` is DROPPED, so it can't close the freshly-reopened session.
            return (state, [.dismissWindow])

        default:
            return (state, [])
        }
    }
}
