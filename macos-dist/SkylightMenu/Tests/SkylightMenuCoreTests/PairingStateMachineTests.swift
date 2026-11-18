import Foundation
import Testing
@testable import SkylightMenuCore

/// Headless coverage for `PairingReducer` (design-pairing-statemachine.md §5). Each historical bug
/// (dossier-pairing-statemachine.md §6) maps to an assertion over the PURE reducer -- no XPC, no
/// window, no live pairing required. This suite is the antidote to "6 fixes, 6 new live-found
/// bugs, zero automated coverage" (dossier bug #12).
@Suite("PairingReducer")
struct PairingStateMachineTests {
    private func pairing(_ uniqueid: String, ip: String = "10.0.0.5", age: Int = 5, hostnameHint: String = "", clientName: String = "") -> PendingPairing {
        PendingPairing(uniqueid: uniqueid, sourceIp: ip, ageSec: age, hostnameHint: hostnameHint, clientName: clientName)
    }

    // MARK: - T1/T2 -- #7 reopen-after-any-terminal-or-mid-flight-step

    @Test("sheetOpened from .paired totally resets to .initial with bumped generation")
    func sheetOpenedFromPairedResetsTotally() {
        let stale = PairingState(
            generation: 3,
            pending: [pairing("a")],
            selected: "a",
            pin: "1234",
            deviceName: "Living Room PC",
            step: .paired
        )
        let (next, effects) = PairingReducer.reduce(stale, .sheetOpened)
        #expect(next == .initial(generation: 4))
        #expect(next.step == .picking(nil))
        #expect(next.selected == nil)
        #expect(next.pin == "")
        #expect(effects == [.focusFirstDigit, .armPairingWindow, .fetchPending, .startPendingPolling])
    }

    @Test("sheetOpened from .verifying and .submitting also totally resets (not just .paired)")
    func sheetOpenedFromVerifyingAndSubmittingResetsTotally() {
        let attempt = PairingState.Attempt(target: "a", deviceLabel: "10.0.0.5")
        let verifying = PairingState(
            generation: 1, pending: [pairing("a")], selected: "a", pin: "1234", deviceName: "PC",
            step: .verifying(attempt, baseline: [])
        )
        let (nextV, _) = PairingReducer.reduce(verifying, .sheetOpened)
        #expect(nextV == .initial(generation: 2))

        let submitting = PairingState(
            generation: 5, pending: [pairing("a")], selected: "a", pin: "9999", deviceName: "PC",
            step: .submitting(attempt)
        )
        let (nextS, _) = PairingReducer.reduce(submitting, .sheetOpened)
        #expect(nextS == .initial(generation: 6))
        #expect(nextS.selected == nil)
        #expect(nextS.pin == "")
    }

    // MARK: - T3 -- #8 deny-mid-verify

    @Test("denyRequested from .verifying dismisses and bumps generation; a stale outcome after is dropped")
    func denyMidVerifyDismissesAndDropsStaleOutcome() {
        let attempt = PairingState.Attempt(target: "a", deviceLabel: "10.0.0.5")
        let verifying = PairingState(
            generation: 2, pending: [], selected: nil, pin: "", deviceName: "PC",
            step: .verifying(attempt, baseline: [])
        )
        let (denied, effects) = PairingReducer.reduce(verifying, .denyRequested)
        #expect(denied.generation == 3)
        #expect(denied.step == .picking(nil))
        #expect(effects.contains(.dismissWindow))
        #expect(effects.contains(.cancelVerification))

        // The verification poll's late callback (issued under the OLD generation 2) lands after
        // the deny -- must be a structural no-op, not a false "Paired".
        let (afterStale, staleEffects) = PairingReducer.reduce(denied, .outcomeResolved(generation: 2, paired: true))
        #expect(afterStale == denied)
        #expect(staleEffects.isEmpty)
    }

    // MARK: - T4 -- #9 submitting-never-returns / watchdog path

    @Test("submitRequested emits runPairFlow; a phase1Rejected under a stale generation after reset is dropped")
    func submitEmitsRunPairFlowAndStaleRejectionIsDropped() {
        let picking = PairingState(
            generation: 0, pending: [pairing("a")], selected: "a", pin: "1234", deviceName: "PC",
            step: .picking(nil)
        )
        let (submitting, effects) = PairingReducer.reduce(picking, .submitRequested)
        guard case .submitting(let attempt) = submitting.step else {
            Issue.record("expected .submitting")
            return
        }
        #expect(attempt.target == "a")
        #expect(submitting.generation == 1)
        #expect(effects == [.runPairFlow(generation: 1, target: "a", pin: "1234", name: "PC")])

        // A reset happens (owner closed and reopened) before the watchdog's phase1Rejected(gen:1)
        // lands -- must be dropped against the NEW generation.
        let (reopened, _) = PairingReducer.reduce(submitting, .sheetOpened)
        let (afterStale, staleEffects) = PairingReducer.reduce(reopened, .phase1Rejected(generation: 1, message: "Timed out reaching the host"))
        #expect(afterStale == reopened)
        #expect(staleEffects.isEmpty)
    }

    // MARK: - T5 -- #1 wrong-PIN then retry

    @Test("outcomeResolved(false) from .verifying returns to .picking(.didntPair), clears pin+target, refetches pending, then a fresh attempt can submit")
    func wrongPinThenRetrySucceeds() {
        let attempt = PairingState.Attempt(target: "a", deviceLabel: "10.0.0.5")
        let verifying = PairingState(
            generation: 1, pending: [pairing("a")], selected: "a", pin: "1234", deviceName: "PC",
            step: .verifying(attempt, baseline: [])
        )
        let (failed, effects) = PairingReducer.reduce(verifying, .outcomeResolved(generation: 1, paired: false))
        #expect(failed.step == .picking(.didntPair))
        #expect(failed.pin == "")
        #expect(failed.selected == nil)
        // THE fix under test: must resume the RECURRING poll (which re-arms the host's
        // eligibility window every 2s), not a one-shot `.fetchPending` -- a bare fetch left the
        // poll timer dead forever afterward (it was started under a now-stale generation), so a
        // client-initiated retry never surfaced without closing and reopening the window.
        #expect(effects.contains(.startPendingPolling))
        #expect(!effects.contains(.fetchPending))
        #expect(effects.contains(.cancelVerification))
        #expect(effects.contains(.focusFirstDigit))
        // Device-list-refresh fix must NOT fire on the failure branch -- only a genuine pairing
        // success should ever trigger a `host.paired` refresh.
        #expect(!effects.contains(.refreshPairedClients(generation: 1)))

        // Retry: select again, re-enter the PIN, submit -- must succeed cleanly.
        let (reselected, _) = PairingReducer.reduce(failed, .deviceSelected("a"))
        let (rekeyed, _) = PairingReducer.reduce(reselected, .pinChanged("5678"))
        #expect(rekeyed.canSubmit)
        let (resubmitted, resubmitEffects) = PairingReducer.reduce(rekeyed, .submitRequested)
        guard case .submitting(let retryAttempt) = resubmitted.step else {
            Issue.record("expected .submitting on retry")
            return
        }
        #expect(retryAttempt.target == "a")
        #expect(resubmitted.generation == 2)
        #expect(resubmitEffects == [.runPairFlow(generation: 2, target: "a", pin: "5678", name: "PC")])
    }

    // MARK: - T6 -- honest phase-1 rejection (non-destructive)

    @Test("phase1Rejected keeps selected target and device name, clears only the pin, and resumes pending polling")
    func phase1RejectedIsNonDestructive() {
        let attempt = PairingState.Attempt(target: "a", deviceLabel: "10.0.0.5")
        let submitting = PairingState(
            generation: 0, pending: [pairing("a")], selected: "a", pin: "1234", deviceName: "PC",
            step: .submitting(attempt)
        )
        let (next, effects) = PairingReducer.reduce(submitting, .phase1Rejected(generation: 0, message: "no armed window"))
        #expect(next.step == .picking(.phase1Rejected("no armed window")))
        #expect(next.selected == "a")
        #expect(next.deviceName == "PC")
        #expect(next.pin == "")
        #expect(effects.contains(.focusFirstDigit))
        // Same recovering-.picking defect as the wrong-PIN path: a phase-1 rejection also lands
        // after `.submitRequested` already bumped the generation, so this must resume the
        // recurring poll too, not leave it dead.
        #expect(effects.contains(.startPendingPolling))
    }

    // MARK: - T7 -- false-paired prevention (snapshot fetch failure)

    @Test("snapshotUnavailable keeps pin, name, and selection, starts NO verification, and resumes pending polling")
    func snapshotUnavailableKeepsEverythingAndStartsNoVerification() {
        let attempt = PairingState.Attempt(target: "a", deviceLabel: "10.0.0.5")
        let submitting = PairingState(
            generation: 0, pending: [pairing("a")], selected: "a", pin: "1234", deviceName: "PC",
            step: .submitting(attempt)
        )
        let (next, effects) = PairingReducer.reduce(submitting, .snapshotUnavailable(generation: 0))
        #expect(next.step == .picking(.serviceUnreachable))
        #expect(next.pin == "1234")
        #expect(next.selected == "a")
        #expect(next.deviceName == "PC")
        #expect(!effects.contains { if case .startVerification = $0 { return true }; return false })
        // Recovering-.picking fix applies here too: a snapshot-fetch failure lands after
        // `.submitRequested` already bumped the generation, so the recurring poll needs restarting
        // under it, exactly like `.phase1Rejected`/`.didntPair`.
        #expect(effects == [.startPendingPolling])
    }

    // MARK: - Inline-retry-after-failure fix -- recovering .picking can fully resubmit

    @Test("recovering .picking after phase1Rejected can select, re-key the PIN, and resubmit cleanly")
    func recoveryFromPhase1RejectedCanResubmit() {
        let attempt = PairingState.Attempt(target: "a", deviceLabel: "10.0.0.5")
        let submitting = PairingState(
            generation: 1, pending: [pairing("a")], selected: "a", pin: "1234", deviceName: "PC",
            step: .submitting(attempt)
        )
        let (recovered, recoveryEffects) = PairingReducer.reduce(submitting, .phase1Rejected(generation: 1, message: "rejected"))
        #expect(recoveryEffects.contains(.startPendingPolling))
        // Selection and name survived (phase1Rejected is non-destructive); canSubmit is false only
        // because the pin was cleared -- re-keying it must restore a submittable state.
        #expect(recovered.selected == "a")
        let (rekeyed, _) = PairingReducer.reduce(recovered, .pinChanged("4321"))
        #expect(rekeyed.canSubmit)
        let (resubmitted, submitEffects) = PairingReducer.reduce(rekeyed, .submitRequested)
        guard case .submitting(let retryAttempt) = resubmitted.step else {
            Issue.record("expected .submitting on retry")
            return
        }
        #expect(retryAttempt.target == "a")
        #expect(submitEffects == [.runPairFlow(generation: resubmitted.generation, target: "a", pin: "4321", name: "PC")])
    }

    @Test("recovering .picking after snapshotUnavailable (serviceUnreachable) can resubmit without re-entering anything")
    func recoveryFromServiceUnreachableCanResubmit() {
        let attempt = PairingState.Attempt(target: "a", deviceLabel: "10.0.0.5")
        let submitting = PairingState(
            generation: 2, pending: [pairing("a")], selected: "a", pin: "1234", deviceName: "PC",
            step: .submitting(attempt)
        )
        let (recovered, recoveryEffects) = PairingReducer.reduce(submitting, .snapshotUnavailable(generation: 2))
        #expect(recoveryEffects == [.startPendingPolling])
        // Everything was kept (false-paired-prevention guard) -- canSubmit should already be true.
        #expect(recovered.canSubmit)
        let (resubmitted, submitEffects) = PairingReducer.reduce(recovered, .submitRequested)
        guard case .submitting = resubmitted.step else {
            Issue.record("expected .submitting on resubmit")
            return
        }
        #expect(submitEffects == [.runPairFlow(generation: resubmitted.generation, target: "a", pin: "1234", name: "PC")])
    }

    // MARK: - Friendly device names (owner: "without the .local after it")

    @Test("PendingPairing.displayHostname strips a trailing .local suffix, and passes through an empty or bare hint")
    func displayHostnameStripsTrailingLocalSuffix() {
        #expect(pairing("a", hostnameHint: "MacBook-Pro.local").displayHostname == "MacBook-Pro")
        #expect(pairing("a", hostnameHint: "MacBook-Pro").displayHostname == "MacBook-Pro")
        #expect(pairing("a", hostnameHint: "").displayHostname == "")
    }

    @Test("PendingPairing.displayClientName strips a trailing .local suffix and trims whitespace, and passes through empty")
    func displayClientNameStripsTrailingLocalSuffix() {
        #expect(pairing("a", clientName: "Joaos-MacBook-Pro.local").displayClientName == "Joaos-MacBook-Pro")
        #expect(pairing("a", clientName: "some-linux-box").displayClientName == "some-linux-box")
        #expect(pairing("a", clientName: "  padded  ").displayClientName == "padded")
        #expect(pairing("a", clientName: "").displayClientName == "")
    }

    @Test("PendingPairing decodes the client_name key, defaulting to empty when a host build predates it")
    func pendingPairingDecodesClientName() {
        let withClientName = """
        {"uniqueid": "a", "source_ip": "10.0.0.5", "age_sec": 3, "hostname_hint": "host.local", "client_name": "some-client"}
        """.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(PendingPairing.self, from: withClientName)
        #expect(decoded.clientName == "some-client")

        // Older host build's JSON omits the key entirely -- must not fail the whole decode.
        let withoutClientName = """
        {"uniqueid": "a", "source_ip": "10.0.0.5", "age_sec": 3, "hostname_hint": "host.local"}
        """.data(using: .utf8)!
        let decodedLegacy = try! JSONDecoder().decode(PendingPairing.self, from: withoutClientName)
        #expect(decodedLegacy.clientName == "")
    }

    @Test("PendingPairing.displayLabel combines friendly name and IP, or falls back to the IP alone")
    func displayLabelCombinesHostnameAndIp() {
        #expect(pairing("a", ip: "192.168.0.214", hostnameHint: "MacBook-Pro.local").displayLabel == "MacBook-Pro · 192.168.0.214")
        #expect(pairing("a", ip: "192.168.0.214", hostnameHint: "").displayLabel == "192.168.0.214")
    }

    @Test("deviceSelected auto-populates an empty device name from the friendly hostname (minus .local)")
    func deviceSelectedAutoPopulatesEmptyName() {
        let picking = PairingState(
            generation: 0, pending: [pairing("a", hostnameHint: "Living-Room-PC.local")], selected: nil, pin: "", deviceName: "", step: .picking(nil)
        )
        let (next, _) = PairingReducer.reduce(picking, .deviceSelected("a"))
        #expect(next.selected == "a")
        #expect(next.deviceName == "Living-Room-PC")
    }

    @Test("deviceSelected never clobbers an already-typed device name")
    func deviceSelectedDoesNotClobberExistingName() {
        let picking = PairingState(
            generation: 0, pending: [pairing("a", hostnameHint: "Living-Room-PC.local")], selected: nil, pin: "", deviceName: "My Custom Name", step: .picking(nil)
        )
        let (next, _) = PairingReducer.reduce(picking, .deviceSelected("a"))
        #expect(next.deviceName == "My Custom Name")
    }

    @Test("deviceSelected leaves an empty device name empty when there is no hostname hint")
    func deviceSelectedLeavesNameEmptyWithoutHint() {
        let picking = PairingState(
            generation: 0, pending: [pairing("a", hostnameHint: "")], selected: nil, pin: "", deviceName: "", step: .picking(nil)
        )
        let (next, _) = PairingReducer.reduce(picking, .deviceSelected("a"))
        #expect(next.deviceName == "")
    }

    @Test("deviceSelected prefers the client's own self-reported name over the host's reverse-DNS hint")
    func deviceSelectedPrefersClientNameOverHostnameHint() {
        let picking = PairingState(
            generation: 0,
            pending: [pairing("a", hostnameHint: "some-reverse-dns-guess.local", clientName: "Joaos-Laptop")],
            selected: nil, pin: "", deviceName: "", step: .picking(nil)
        )
        let (next, _) = PairingReducer.reduce(picking, .deviceSelected("a"))
        #expect(next.deviceName == "Joaos-Laptop")
    }

    @Test("deviceSelected falls back to the hostname hint when the client sent no devicename")
    func deviceSelectedFallsBackToHostnameHintWhenClientNameEmpty() {
        let picking = PairingState(
            generation: 0,
            pending: [pairing("a", hostnameHint: "Living-Room-PC.local", clientName: "")],
            selected: nil, pin: "", deviceName: "", step: .picking(nil)
        )
        let (next, _) = PairingReducer.reduce(picking, .deviceSelected("a"))
        #expect(next.deviceName == "Living-Room-PC")
    }

    @Test("deviceSelected strips a trailing .local suffix from the client-sent name too")
    func deviceSelectedStripsLocalSuffixFromClientName() {
        let picking = PairingState(
            generation: 0,
            pending: [pairing("a", hostnameHint: "", clientName: "Joaos-MacBook-Pro.local")],
            selected: nil, pin: "", deviceName: "", step: .picking(nil)
        )
        let (next, _) = PairingReducer.reduce(picking, .deviceSelected("a"))
        #expect(next.deviceName == "Joaos-MacBook-Pro")
    }

    @Test("deviceSelected with a client-sent name still never clobbers an already-typed device name")
    func deviceSelectedWithClientNameDoesNotClobberExistingName() {
        let picking = PairingState(
            generation: 0,
            pending: [pairing("a", hostnameHint: "", clientName: "Attacker-Controlled-Name")],
            selected: nil, pin: "", deviceName: "My Custom Name", step: .picking(nil)
        )
        let (next, _) = PairingReducer.reduce(picking, .deviceSelected("a"))
        #expect(next.deviceName == "My Custom Name")
    }

    @Test("submitRequested's Attempt.deviceLabel uses the friendly 'name · IP' form when a hostname hint is present")
    func submitAttemptLabelUsesFriendlyForm() {
        let picking = PairingState(
            generation: 0, pending: [pairing("a", ip: "192.168.0.214", hostnameHint: "MacBook-Pro.local")],
            selected: "a", pin: "1234", deviceName: "PC", step: .picking(nil)
        )
        let (submitting, _) = PairingReducer.reduce(picking, .submitRequested)
        guard case .submitting(let attempt) = submitting.step else {
            Issue.record("expected .submitting")
            return
        }
        #expect(attempt.deviceLabel == "MacBook-Pro · 192.168.0.214")
    }

    // MARK: - T8 -- edf95ccf stale-outcome-drain / generation cancel

    @Test("a prior attempt's outcome under the old generation is dropped once a new attempt has bumped it; runPairFlow is emitted for the new attempt (the drain itself lives inside that effect)")
    func priorAttemptOutcomeDroppedAfterNewSubmit() {
        let picking = PairingState(
            generation: 0, pending: [pairing("a")], selected: "a", pin: "1234", deviceName: "PC",
            step: .picking(nil)
        )
        let (submitting1, effects1) = PairingReducer.reduce(picking, .submitRequested)
        #expect(effects1 == [.runPairFlow(generation: 1, target: "a", pin: "1234", name: "PC")])

        // First attempt's phase-1 got rejected (generation 1), owner retries with new digits.
        let (backToPicking, _) = PairingReducer.reduce(submitting1, .phase1Rejected(generation: 1, message: "rejected"))
        let (rekeyed, _) = PairingReducer.reduce(backToPicking, .pinChanged("4321"))
        let (submitting2, effects2) = PairingReducer.reduce(rekeyed, .submitRequested)
        #expect(submitting2.generation == 2)
        #expect(effects2 == [.runPairFlow(generation: 2, target: "a", pin: "4321", name: "PC")])

        // A stale outcome for the FIRST attempt (generation 1) must not affect attempt 2's state.
        let (afterStaleOutcome, staleEffects) = PairingReducer.reduce(submitting2, .outcomeResolved(generation: 1, paired: false))
        #expect(afterStaleOutcome == submitting2)
        #expect(staleEffects.isEmpty)
    }

    // MARK: - T9 -- mandatory-target security (no 0/1-eligible auto-apply)

    @Test("canSubmit is false with a complete PIN+name but no selected target, and submitRequested is a no-op")
    func mandatoryTargetGateBlocksBlindSubmit() {
        let picking = PairingState(
            generation: 0, pending: [pairing("a")], selected: nil, pin: "1234", deviceName: "PC",
            step: .picking(nil)
        )
        #expect(picking.isComplete)
        #expect(!picking.canSubmit)
        let (next, effects) = PairingReducer.reduce(picking, .submitRequested)
        #expect(next == picking)
        #expect(next.step == .picking(nil))
        #expect(effects.isEmpty)
    }

    // MARK: - T10 -- #4 fast-outcome success

    @Test("outcomeResolved(true) from .verifying transitions to .paired and schedules auto-dismiss")
    func fastOutcomeSuccessReachesPaired() {
        let attempt = PairingState.Attempt(target: "a", deviceLabel: "10.0.0.5")
        let verifying = PairingState(
            generation: 4, pending: [], selected: nil, pin: "", deviceName: "PC",
            step: .verifying(attempt, baseline: [])
        )
        let (next, effects) = PairingReducer.reduce(verifying, .outcomeResolved(generation: 4, paired: true))
        #expect(next.step == .paired)
        #expect(effects.contains(.cancelVerification))
        #expect(effects.contains(.scheduleAutoDismiss(generation: 4)))
        // Device-list-refresh fix (dossier-devicelist-refresh.md): the Devices tab reads
        // `host.paired`, which nothing else refreshes on a successful pairing -- the reducer must
        // emit a refresh effect alongside the auto-dismiss the moment it declares `.paired`.
        #expect(effects.contains(.refreshPairedClients(generation: 4)))
    }

    // MARK: - T11 -- double-submit re-entrancy

    @Test("a second submitRequested while already .submitting is a no-op (no double-submit)")
    func doubleSubmitIsANoOp() {
        let picking = PairingState(
            generation: 0, pending: [pairing("a")], selected: "a", pin: "1234", deviceName: "PC",
            step: .picking(nil)
        )
        let (submitting, _) = PairingReducer.reduce(picking, .submitRequested)
        let (afterSecond, effects) = PairingReducer.reduce(submitting, .submitRequested)
        #expect(afterSecond == submitting)
        #expect(effects.isEmpty)
    }

    // MARK: - T12 -- auto-dismiss stale-generation guard

    @Test("autoDismissElapsed under a stale generation (owner reopened within the 1.2s window) is dropped")
    func staleAutoDismissAfterReopenIsDropped() {
        let paired = PairingState(generation: 4, pending: [], selected: nil, pin: "", deviceName: "", step: .paired)
        let (reopened, _) = PairingReducer.reduce(paired, .sheetOpened) // generation now 5
        #expect(reopened.generation == 5)

        let (afterStaleDismiss, effects) = PairingReducer.reduce(reopened, .autoDismissElapsed(generation: 4))
        #expect(afterStaleDismiss == reopened) // freshly-reopened session untouched
        #expect(effects.isEmpty) // NOT dismissed by the stale timer
    }

    @Test("autoDismissElapsed under the current generation dismisses the window")
    func liveAutoDismissDismissesWindow() {
        let paired = PairingState(generation: 4, pending: [], selected: nil, pin: "", deviceName: "", step: .paired)
        let (next, effects) = PairingReducer.reduce(paired, .autoDismissElapsed(generation: 4))
        #expect(next == paired)
        #expect(effects == [.dismissWindow])
    }

    // MARK: - T13 -- manual exit from every terminal state

    @Test("denyRequested from .paired dismisses the window (paired is never a dead end)")
    func denyFromPairedDismisses() {
        let paired = PairingState(generation: 2, pending: [], selected: nil, pin: "", deviceName: "", step: .paired)
        let (next, effects) = PairingReducer.reduce(paired, .denyRequested)
        #expect(next.step == .picking(nil))
        #expect(next.generation == 3)
        #expect(effects.contains(.dismissWindow))
    }

    @Test("denyRequested from .submitting also dismisses (every mid-flight step has a manual exit)")
    func denyFromSubmittingDismisses() {
        let attempt = PairingState.Attempt(target: "a", deviceLabel: "10.0.0.5")
        let submitting = PairingState(generation: 1, pending: [], selected: "a", pin: "1234", deviceName: "PC", step: .submitting(attempt))
        let (next, effects) = PairingReducer.reduce(submitting, .denyRequested)
        #expect(next.step == .picking(nil))
        #expect(effects.contains(.dismissWindow))
        #expect(effects.contains(.cancelVerification))
        #expect(effects.contains(.cancelPendingPolling))
    }

    // MARK: - T14 -- selection follows host truth

    @Test("pendingPairingsFetched clears a selection that vanished from the eligible list")
    func vanishedSelectionIsCleared() {
        let picking = PairingState(
            generation: 0, pending: [pairing("a")], selected: "a", pin: "", deviceName: "", step: .picking(nil)
        )
        let (next, _) = PairingReducer.reduce(picking, .pendingPairingsFetched([]))
        #expect(next.selected == nil)
        #expect(next.pending.isEmpty)
    }

    @Test("pendingPairingsFetched while .verifying only updates the list, step unchanged")
    func pendingListRefreshDuringVerifyLeavesStepUnchanged() {
        let attempt = PairingState.Attempt(target: "a", deviceLabel: "10.0.0.5")
        let verifying = PairingState(
            generation: 1, pending: [], selected: nil, pin: "", deviceName: "",
            step: .verifying(attempt, baseline: [])
        )
        let (next, effects) = PairingReducer.reduce(verifying, .pendingPairingsFetched([pairing("b")]))
        #expect(next.step == verifying.step)
        #expect(next.pending == [pairing("b")])
        #expect(effects.isEmpty)
    }

    // MARK: - T15 -- totality

    @Test("every (step x event) combination returns without trapping, and no event leaves a live-generation .verifying/.submitting stuck without a matching drop/advance path")
    func reducerIsTotal() {
        let attempt = PairingState.Attempt(target: "x", deviceLabel: "1.2.3.4")
        let steps: [PairingState.Step] = [
            .picking(nil),
            .picking(.phase1Rejected("m")),
            .picking(.serviceUnreachable),
            .picking(.didntPair),
            .submitting(attempt),
            .verifying(attempt, baseline: ["u1"]),
            .paired
        ]
        let events: [PairingEvent] = [
            .sheetOpened,
            .sheetClosed,
            .pendingPairingsFetched([PendingPairing(uniqueid: "x", sourceIp: "1.2.3.4", ageSec: 1)]),
            .pinChanged("12"),
            .deviceNameChanged("n"),
            .deviceSelected("x"),
            .submitRequested,
            .denyRequested,
            .snapshotUnavailable(generation: 0),
            .phase1Rejected(generation: 0, message: "m"),
            .enteredVerification(generation: 0, baseline: []),
            .outcomeResolved(generation: 0, paired: true),
            .outcomeResolved(generation: 0, paired: false),
            .autoDismissElapsed(generation: 0)
        ]
        for step in steps {
            for event in events {
                let state = PairingState(generation: 0, pending: [PendingPairing(uniqueid: "x", sourceIp: "1.2.3.4", ageSec: 1)], selected: "x", pin: "12", deviceName: "n", step: step)
                // Must not trap; result is always a well-formed value.
                let (next, _) = PairingReducer.reduce(state, event)
                _ = next.canSubmit
                _ = next.isComplete
            }
        }
    }

    // MARK: - Extra edge: field-level guards on the picking step

    @Test("deviceSelected ignores a uniqueid not present in the pending list")
    func deviceSelectedIgnoresUnknownUniqueid() {
        let picking = PairingState(generation: 0, pending: [pairing("a")], selected: nil, pin: "", deviceName: "", step: .picking(nil))
        let (next, _) = PairingReducer.reduce(picking, .deviceSelected("ghost"))
        #expect(next.selected == nil)
    }

    @Test("sheetClosed bumps generation and cancels timers but leaves the step untouched (the next open resets it)")
    func sheetClosedOnlyBumpsGeneration() {
        let attempt = PairingState.Attempt(target: "a", deviceLabel: "10.0.0.5")
        let verifying = PairingState(generation: 1, pending: [], selected: nil, pin: "", deviceName: "", step: .verifying(attempt, baseline: []))
        let (next, effects) = PairingReducer.reduce(verifying, .sheetClosed)
        #expect(next.generation == 2)
        #expect(next.step == verifying.step)
        #expect(effects == [.cancelPendingPolling, .cancelVerification])
    }
}

@Test func pendingServiceFailureDisablesSubmissionWithoutDiscardingTrustedSelection() {
    let pending = PendingPairing(uniqueid: "device", sourceIp: "10.0.0.5", ageSec: 1)
    var state = PairingState(generation: 4, pending: [pending], selected: "device", pin: "1234", deviceName: "PC", step: .picking(nil))
    (state, _) = PairingReducer.reduce(state, .pendingPairingsUnavailable)
    #expect(state.pending == [pending])
    #expect(state.pendingPhase == .unavailable)
    #expect(!state.canSubmit)
    #expect(PairingReducer.reduce(state, .retryPending).1 == [.armPairingWindow, .fetchPending])
    (state, _) = PairingReducer.reduce(state, .pendingPairingsFetched([pending]))
    #expect(state.canSubmit)
}

@Test func verificationOutageAndExpiryHaveDistinctNoticesAndCanRetry() {
    let attempt = PairingState.Attempt(target: "device", deviceLabel: "10.0.0.5")
    let original = PairingState(generation: 4, pending: [], selected: "device", pin: "1234", deviceName: "PC", step: .verifying(attempt, baseline: []))
    for reason in [PairingVerificationFailure.unavailable, .expired] {
        let (failed, effects) = PairingReducer.reduce(original, .verificationFailed(generation: 4, reason: reason))
        #expect(failed.step == .picking(reason == .expired ? .verificationExpired : .serviceUnreachable))
        #expect(failed.pin.isEmpty)
        #expect(failed.selected == nil)
        #expect(effects.contains(.cancelVerification))
        #expect(effects.contains(.startPendingPolling))
        #expect(PairingReducer.reduce(original, .verificationFailed(generation: 3, reason: reason)).0 == original)
    }
}
