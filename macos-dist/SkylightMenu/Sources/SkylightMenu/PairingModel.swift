import Foundation
import Observation
import SkylightMenuCore

@MainActor
protocol PairingHost: AnyObject {
    func beginPairingWindow()
    func fetchPendingPairings(completion: @escaping ([PendingPairing]?) -> Void)
    func fetchPairedClients()
    func fetchPairedClientsList(completion: @escaping ([PairedClient]?) -> Void)
    func fetchPairOutcome(forUniqueid: String, completion: @escaping (HostConnection.PairOutcomeReply) -> Void)
    func pair(pin: String, name: String, target: String, completion: @escaping (Bool, String) -> Void)
}

extension HostConnection: PairingHost {}

/// The sole effect-runner for `PairingReducer`'s pure state machine
/// (design-pairing-statemachine.md §4.1). Owns every timer + XPC call that used to be scattered
/// across `PairingSheet`'s 11 `@State` vars and their transition methods; `PairingSheet` itself is
/// now a thin renderer that only sends `PairingEvent`s into `send(_:)` and reads `state`.
///
/// Every effect captures the generation it was issued under and tags the event it later
/// dispatches with that same generation; `PairingReducer`'s gen guard drops anything stale. Timers
/// are cancel-then-start (idempotent); `.cancelPendingPolling`/`.cancelVerification` invalidate
/// them; `.sheetClosed` cancels both. This -- not any per-callback cleverness -- is what makes a
/// stale XPC/timer callback landing after a reset (window closed, reopened, or a new attempt
/// started) a structural no-op rather than corrupting the freshly-reset state.
@MainActor
@Observable
final class PairingModel {
    private(set) var state = PairingState.initial()
    /// Bridges the `.focusFirstDigit` effect into the view's own `@FocusState` -- the one piece of
    /// UI-only state the design keeps in the view rather than the reducer (design §4.2).
    var focusTarget: Int?
    /// Wired to the view's `@Environment(\.dismiss)` (pairing is a sheet on the Settings window,
    /// per docs/design/2026-07-18-pairing-attached-to-settings.md), so the reducer/model stay free
    /// of any `@Environment` dependency and the effect list can be asserted on directly in tests.
    var onDismiss: (() -> Void)?

    private let host: any PairingHost
    private var pendingTimer: Timer?
    private var verifyTimer: Timer?
    private var verificationRequest: UUID?
    private var submitWatchdog: Timer?
    private var autoDismissWork: DispatchWorkItem?

    init(host: any PairingHost) {
        self.host = host
    }

    func send(_ event: PairingEvent) {
        let (next, effects) = PairingReducer.reduce(state, event)
        state = next
        for effect in effects {
            run(effect)
        }
    }

    private func run(_ effect: PairingEffect) {
        switch effect {
        case .focusFirstDigit:
            focusTarget = 0

        case .armPairingWindow:
            host.beginPairingWindow()

        case .fetchPending:
            fetchPending()

        case .startPendingPolling:
            startPendingPolling()

        case .cancelPendingPolling:
            pendingTimer?.invalidate()
            pendingTimer = nil

        case .runPairFlow(let generation, let target, let pin, let name):
            runPairFlow(generation: generation, target: target, pin: pin, name: name)

        case .startVerification(let generation, let target, let baseline):
            startVerification(generation: generation, target: target, baseline: baseline)

        case .cancelVerification:
            verificationRequest = nil
            verifyTimer?.invalidate()
            verifyTimer = nil

        case .scheduleAutoDismiss(let generation):
            scheduleAutoDismiss(generation: generation)

        case .refreshPairedClients:
            // No generation guard needed here: `run(_:)` executes synchronously, in the same
            // call stack as the `reduce` that emitted this effect (see `send(_:)` above), so
            // `state.generation` cannot have moved between emission and this call -- same
            // reasoning as `.dismissWindow`/`.armPairingWindow` needing none. `fetchPairedClients()`
            // itself is the pre-existing, safe-to-call-repeatedly refresh
            // (`HostConnection.swift:772-777`) already used by Settings-open/status-change/unpair.
            host.fetchPairedClients()

        case .dismissWindow:
            autoDismissWork?.cancel()
            autoDismissWork = nil
            onDismiss?()
        }
    }

    // MARK: - Pending list (F2: continuous re-arm while the sheet is open)

    private func fetchPending() {
        let gen = state.generation
        host.fetchPendingPairings { [weak self] pairings in
            guard let self, gen == self.state.generation else { return }
            if let pairings { self.send(.pendingPairingsFetched(pairings)) }
            else { self.send(.pendingPairingsUnavailable) }
        }
    }

    private func startPendingPolling() {
        pendingTimer?.invalidate()
        let gen = state.generation
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.state.generation else { return }
                self.host.beginPairingWindow()
                self.fetchPending()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingTimer = timer
    }

    // MARK: - Submit (.runPairFlow -- verbatim today's submitIfComplete sequencing)

    private func runPairFlow(generation: Int, target: String, pin: String, name: String) {
        // Dossier bug #9 ("`.submitting` had no timeout of its own"): belt-and-suspenders over
        // HostConnection's already-guaranteed single-resume `withXPC` plumbing.
        submitWatchdog?.invalidate()
        let watchdog = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.state.generation else { return }
                self.send(.phase1Rejected(generation: generation, message: "Timed out reaching the host"))
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        submitWatchdog = watchdog

        // Snapshot BEFORE submitting -- the pre-existing getPairedClients call, no new XPC
        // surface. False-paired prevention: a failed snapshot fetch means no trustworthy
        // baseline, so nothing is submitted and everything is kept for a plain retry.
        host.fetchPairedClientsList { [weak self] snapshot in
            guard let self, generation == self.state.generation,
                  case .submitting = self.state.step else { return }
            guard let snapshot else {
                self.submitWatchdog?.invalidate()
                self.submitWatchdog = nil
                self.send(.snapshotUnavailable(generation: generation))
                return
            }
            let baseline = Set(snapshot.map(\.uuid))

            // Drain a stale outcome for this device before submitting (`edf95ccf`): Moonlight
            // reuses the same uniqueid across pairing retries, and the host keeps a failed
            // outcome for a short TTL after a timeout records it -- discard it here so this
            // attempt's FIRST outcome poll can't consume the PREVIOUS attempt's stale result.
            self.host.fetchPairOutcome(forUniqueid: target) { [weak self] _ in
                guard let self, generation == self.state.generation,
                  case .submitting = self.state.step else { return }
                self.host.pair(pin: pin, name: name, target: target) { [weak self] success, message in
                    guard let self else { return }
                    self.submitWatchdog?.invalidate()
                    self.submitWatchdog = nil
                    guard generation == self.state.generation else { return }
                    if success {
                        // Phase 1 accepted ONLY -- the real (phase 4) outcome is still unknown.
                        self.send(.enteredVerification(generation: generation, baseline: baseline))
                    } else {
                        // Honest phase-1 rejection -- nothing was consumed host-side.
                        self.send(.phase1Rejected(generation: generation, message: message))
                    }
                }
            }
        }
    }

    // MARK: - Verification (.startVerification -- verbatim today's checkForPairedGrowth polling)

    private func startVerification(generation: Int, target: String, baseline: Set<String>) {
        verifyTimer?.invalidate()
        let deadline = Date().addingTimeInterval(30)
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.state.generation else { return }
                self.checkOutcome(generation: generation, target: target, baseline: baseline, deadline: deadline)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        verifyTimer = timer
    }

    /// Only the selected request's terminal outcome can establish success. Paired UUIDs are
    /// unrelated to request uniqueids, so list growth is not evidence about this device.
    func checkOutcome(
        generation: Int,
        target: String,
        baseline: Set<String>,
        deadline: Date,
        isFinalReconcile: Bool = false
    ) {
        guard verificationRequest == nil else { return }
        let request = UUID()
        verificationRequest = request
        host.fetchPairOutcome(forUniqueid: target) { [weak self] outcome in
            guard let self, self.verificationRequest == request else { return }
            self.verificationRequest = nil
            guard generation == self.state.generation else { return }
            switch outcome {
            case .complete(let paired):
                self.send(.outcomeResolved(generation: generation, paired: paired))
                return
            case .unavailable:
                self.send(.verificationFailed(generation: generation, reason: .unavailable))
                return
            case .waiting:
                break
            }
            guard Date() >= deadline else { return }
            if isFinalReconcile {
                self.send(.verificationFailed(generation: generation, reason: .expired))
            } else {
                self.checkOutcome(generation: generation, target: target, baseline: baseline, deadline: deadline, isFinalReconcile: true)
            }
        }
    }

    // MARK: - Auto-dismiss

    private func scheduleAutoDismiss(generation: Int) {
        autoDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.send(.autoDismissElapsed(generation: generation))
        }
        autoDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
