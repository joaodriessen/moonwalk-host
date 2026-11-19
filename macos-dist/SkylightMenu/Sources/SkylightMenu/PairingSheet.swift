import SwiftUI
import SkylightMenuCore

/// S3 native pairing view (docs/design/menubar-app.md "S3", docs/design/menubar-mockup.html
/// "A four-digit handshake, beautifully small"). Presented as a `.sheet` on the Settings window
/// (docs/design/2026-07-18-pairing-attached-to-settings.md), arrived at via `PairingPresentation`
/// -- either directly (`SettingsView`'s in-Devices-pane button, Settings already frontmost) or
/// through `WindowActivator` fronting Settings first, for the menu's "Pair New Device…" row (a
/// `.menu`-style `MenuBarExtra` has no popover of its own to host a sheet, but the Settings window
/// does). A standalone `Window` scene was tried in between and rejected by the owner (modeless,
/// competed for window management) -- see `MenuContent.swift`'s doc comment for that history.
/// TRUST ESTABLISHMENT -- this is the native front end
/// for the same `POST /api/pin` flow the web UI's `pin.html` already exposes; see
/// `HostConnection.pair(pin:name:target:completion:)` ->
/// `SkylightControl.pair(_:name:targetUniqueid:reply:)` -> `src/platform/macos/xpc_control.mm`'s
/// `pair:name:targetUniqueid:reply:`, which reuses `nvhttp::pin` -- the SAME function `savePin`
/// calls -- rather than reimplementing any pairing crypto.
///
/// HONESTY NOTE (device name): the daemon has no way to know a pending client's real name ahead
/// of confirmation -- neither does the existing web flow (`pin.html` also asks the human to
/// type both the PIN and a name). This sheet asks for both too, rather than fabricating a
/// "detected device name" the host cannot actually supply.
///
/// HONESTY NOTE (pairing outcome): `nvhttp::pin()`'s `true` return means ONLY that the PIN was
/// accepted into phase 1 (`getservercert`'s key derivation, which cannot fail on a wrong PIN);
/// the REAL correctness check happens 3 client-driven round-trips later in
/// `clientpairingsecret()`. This sheet enters a "Verifying the PIN…" state after a successful
/// phase-1 submit and checks the host's existing target-specific outcome registry to detect the
/// real, phase-4-verified result. A different device joining the paired list is never proof -- see
/// `PairingReducer`/`PairingModel` (SkylightMenuCore/PairingReducer.swift,
/// SkylightMenu/PairingModel.swift) for the state machine this drives.
///
/// SECURITY (S3 pairing-DoS/hijack fix, HARDENED -- see `src/nvhttp.h`/`.cpp`'s
/// `arm_pairing_window()`/`pin()` doc comments for the full design): opening this sheet ARMS the
/// host's owner-eligibility window (`.onAppear` below), which excludes any background attacker
/// session outside that window. That alone is NOT sufficient to trust "the one eligible session
/// must be the owner's" -- if the owner's genuine client fired `getservercert` more than the
/// eligibility lookback before this sheet is opened, the genuine session falls OUT of the window
/// while an in-window LAN attacker could be the SOLE eligible session. So this sheet NEVER submits
/// without the owner explicitly tapping to confirm a specific pending session, identified ONLY by
/// its attacker-unspoofable source IP (`PendingPairing.sourceIp`) -- required even when there is
/// exactly one candidate to confirm. There is no "0/1 eligible -> submit blind" path anywhere in
/// this view; `nvhttp::pin()` itself refuses an empty target unconditionally as the backstop, and
/// `PairingState.canSubmit` mirrors that gate at the type level (SkylightMenuCore/PairingState.swift).
///
/// REBUILD (design-pairing-statemachine.md, dossier-pairing-statemachine.md): this view used to
/// hold 11 independent `@State` vars with no "we just opened, start clean" contract -- bound to a
/// singleton `Window` scene whose state survives every open/close, that gap let a stale terminal
/// screen (e.g. "Paired") survive a reopen. All session-scoped state now lives in ONE
/// `PairingState` value inside `PairingModel`, reset totally by a `.sheetOpened` event on every
/// `.onAppear` -- see `PairingReducer`'s `PairingStateMachineTests` for the unit coverage. This
/// view is now a thin renderer: state -> section, user action -> event. Every section body below
/// is REUSED VERBATIM from the pre-rebuild view; only the bindings were repointed.
struct PairingSheet: View {
    var host: HostConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    /// Design tokens (design-pairing-panel.md §3) resolved for the current appearance --
    /// styling-only, no behavior. See `SkylightTheme.swift`.
    private var theme: SkylightTheme.Colors { SkylightTheme.Colors(colorScheme) }

    /// The effect-runner. Whether this exact object instance persists across dismiss/re-present
    /// (2026-07-18: now a `.sheet` rather than a singleton `Window` scene) is immaterial either way
    /// (design §7): `.sheetOpened` totally resets `model.state` on every `onAppear`, so nothing
    /// about correctness depends on the object's own lifetime, only its (idempotent,
    /// cancel-then-start) timers matter if it does happen to survive.
    @State private var model: PairingModel
    /// The one piece of UI-only state kept in the view rather than the reducer (design §4.1/§4.2):
    /// `.focusFirstDigit` bridges into this via `model.focusTarget`.
    @FocusState private var focusedDigit: Int?
    @State private var pinEntry = PINEntry()

    init(host: HostConnection) {
        self.host = host
        _model = State(initialValue: PairingModel(host: host))
    }

    var body: some View {
        // §2.1: a centered vertical hero, not the old leading-aligned form stack. `minHeight: 300`
        // stabilizes the layout across the picking→verifying→paired swap -- a `.sheet` DOES resize
        // to fit its content and can animate that swap (unlike the old `Window` scene, which
        // couldn't animate its outer size), but the stabilizer still helps avoid a jarring resize
        // and needs no change (design §3.7); the state-swap `.animation` lives on this outer
        // VStack, while each case below carries its own `.transition` — styling/motion only, no
        // state, event, or binding logic changed anywhere in this file.
        VStack(alignment: .center, spacing: SkylightTheme.Spacing.l) {
            header

            switch model.state.step {
            case .picking, .submitting:
                VStack(alignment: .leading, spacing: SkylightTheme.Spacing.l) {
                    digitEntry
                    deviceConfirmationSection
                    deviceNameField
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            case .verifying:
                waitingForDeviceSection
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            case .paired:
                pairedSection
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let inlineErrorText {
                noticeCapsule(inlineErrorText)
            }

            footer
        }
        .padding(SkylightTheme.Spacing.l)
        .frame(width: 340)
        .frame(minHeight: 300)
        .animation(.snappy(duration: 0.28), value: model.state.step)
        .onAppear {
            // SECURITY (S3 pairing-DoS/hijack fix, Layer A): opening this sheet IS the owner's
            // explicit "I'm about to pair a device" signal -- `.sheetOpened`'s `.armPairingWindow`
            // effect arms the host's eligibility window so the genuine client's pending session
            // becomes eligible for pin() to target. This narrows WHO can be eligible; it does not
            // by itself make a lone eligible session trustworthy -- see this struct's doc comment
            // for why an explicit tap is still required below.
            //
            // This is ALSO the reset-on-open transition (design §3): `.sheetOpened` replaces
            // `model.state` wholesale via `PairingReducer`, so a stale terminal step from a prior
            // session (the reopen-after-paired bug this rebuild exists to close) can never survive
            // to this render.
            model.onDismiss = { dismiss() }
            pinEntry = PINEntry()
            model.send(.sheetOpened)
        }
        .onDisappear {
            model.send(.sheetClosed)
        }
        .onChange(of: model.focusTarget) { _, newValue in
            focusedDigit = newValue
        }
        .onChange(of: model.state.generation) { _, _ in
            if model.state.pin.isEmpty { pinEntry = PINEntry() }
        }
        .onChange(of: model.state.step) { _, _ in
            if model.state.pin.isEmpty { pinEntry = PINEntry() }
        }
    }

    // MARK: - Sections (unchanged bodies -- bindings repointed to `model` only)

    private var header: some View {
        // §2.2 hero: mirrors the host-card hero's restraint (design-host-card-hero.md) — centered
        // glyph + gradient + title, generous whitespace, no drop shadow ever.
        VStack(spacing: SkylightTheme.Spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [theme.accent, theme.accentPress], startPoint: .top, endPoint: .bottom))
                LucideIcon(.link, size: 28)
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)

            Text("Pair a device")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.label)

            Text("When your device shows a 4-digit PIN, enter it here to confirm on this Mac.")
                .font(.system(size: SkylightTheme.TypeSize.caption))
                .foregroundStyle(theme.label2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var digitEntry: some View {
        HStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { index in
                digitBox(index)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PIN, 4 digits")
    }

    private var deviceNameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Device name")
                .font(.caption)
                .foregroundStyle(theme.label2)
            TextField("e.g. Living Room PC", text: Binding(
                get: { model.state.deviceName },
                set: { model.send(.deviceNameChanged($0)) }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.send(.submitRequested) }
            .accessibilityLabel("Device name")
            .accessibilityHint("A name for your reference — the host can’t detect the client’s real name automatically.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The honest "we submitted phase 1, phase 4's real result is still unknown" state. §2.6:
    /// a serene centered wait, a calm large spinner rather than a small inline one.
    private var waitingForDeviceSection: some View {
        // `deviceLabel` is "friendly-name · IP" when the host had a hostname hint at submit time,
        // else the IP alone (`PendingPairing.displayLabel`, computed once in
        // `PairingReducer.reducePicking`'s `.submitRequested`) -- display only, never re-derives
        // trust; the attempt was already keyed on `uniqueid` before this label was built.
        let label = currentAttempt?.deviceLabel ?? "your device"
        return VStack(spacing: SkylightTheme.Spacing.s) {
            ProgressView().controlSize(.large)
            Text("Verifying the PIN…")
                .font(.system(size: SkylightTheme.TypeSize.body, weight: .medium))
                .foregroundStyle(theme.label)
            Text("Waiting for \(label) to confirm.")
                .font(.system(size: SkylightTheme.TypeSize.caption))
                .foregroundStyle(theme.label2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SkylightTheme.Spacing.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verifying the PIN, confirming with \(label)")
    }

    /// Shown once the host confirms that this device was added to the paired list.
    private var pairedSection: some View {
        VStack(spacing: SkylightTheme.Spacing.s) {
            LucideIcon(.circleCheck, size: 44)
                .foregroundStyle(theme.ok)
                // One gentle bounce on the state transition into `.paired`. The glyph is a
                // Lucide image, not an SF Symbol, so `.symbolEffect(.bounce)` would do nothing;
                // `model.state.step` only becomes `.paired` once per pairing, so this fires once.
                .phaseAnimator([1.0, 1.12, 1.0], trigger: model.state.step) { glyph, scale in
                    glyph.scaleEffect(scale)
                } animation: { _ in .spring(duration: 0.25) }
            Text("Paired")
                .font(.system(size: SkylightTheme.TypeSize.headline, weight: .semibold))
                .foregroundStyle(theme.label)
            Text("You can now connect from your other device.")
                .font(.system(size: SkylightTheme.TypeSize.caption))
                .foregroundStyle(theme.label2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SkylightTheme.Spacing.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Paired successfully")
    }

    /// §2.8: a danger-tinted capsule instead of bare red text — prominent without alarm. The
    /// trailing `Spacer` is a deliberate slot: an inline "Try again" button can drop in here
    /// without any layout change, but none exists in this file today (styling only, no retry
    /// logic added).
    @ViewBuilder
    private func noticeCapsule(_ message: String) -> some View {
        HStack(spacing: 8) {
            LucideIcon(.triangleAlert, size: 14)
                .foregroundStyle(theme.danger)
            Text(message)
                .font(.system(size: SkylightTheme.TypeSize.caption))
                .foregroundStyle(theme.label)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: SkylightTheme.Radius.control, style: .continuous))
        .accessibilityLabel(message)
    }

    /// §2.9: keep native buttons + all existing logic (`model.send`, `canSubmit`, keyboard
    /// shortcuts) untouched. Only the `.paired` step's layout changes — Cancel/Pair Device are
    /// meaningless once paired, so that step renders a single centered prominent "Done" instead
    /// of the left/right pair; the button already switched its title on `.paired` before this
    /// pass, this only changes which buttons render and how they're arranged.
    @ViewBuilder
    private var footer: some View {
        if model.state.step == .paired {
            HStack {
                Spacer()
                Button("Done", role: .cancel) {
                    model.send(.denyRequested)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                Spacer()
            }
        } else {
            HStack {
                Button("Cancel", role: .cancel) {
                    model.send(.denyRequested)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(theme.danger)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel pairing")

                Spacer()

                if isPickingOrSubmitting {
                    Button {
                        model.send(.submitRequested)
                    } label: {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Pair Device")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.state.canSubmit || isSubmitting)
                    .accessibilityLabel("Pair device")
                }
            }
        }
    }

    // MARK: - Owner confirmation (mandatory -- see struct doc comment for why, even at count 1)

    /// ALWAYS rendered while any pairing session is eligible or pending confirmation -- there is
    /// no "skip this because there's only one" branch. `nvhttp::pin()` refuses to apply a PIN
    /// without a caller-supplied target no matter the eligible-set size, so the UI must never
    /// offer a way to submit without the owner tapping a specific row first.
    private var deviceConfirmationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.state.pending.isEmpty ? "Waiting for a device" : "Confirm your device")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.label)
            Text(
                model.state.pending.isEmpty
                    ? "1. On the client, open Moonwalk (or Moonlight) and click Pair on this host.\n2. Its network address appears below.\n3. Tap it and enter the PIN it shows."
                    : "Tap the row for your device, identified by its network address. This confirmation is required even if only one device is shown."
            )
            .font(.caption2)
            .foregroundStyle(theme.label2)

            if model.state.pendingPhase == .unavailable {
                Label("Couldn’t reach the streaming host. Wait for it to reconnect, then retry.", lucide: .triangleAlert, size: 12)
                    .font(.caption)
                Button("Retry") { model.send(.retryPending) }
            } else if model.state.pending.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.state.pendingPhase == .loading ? "Checking for devices…" : "No device is asking to pair yet")
                        .font(.caption)
                        .foregroundStyle(theme.label2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.state.pending) { pairing in
                        pairingRow(pairing)
                            .transition(.opacity)
                    }
                }
                .padding(SkylightTheme.Spacing.s)
                .background(RoundedRectangle(cornerRadius: SkylightTheme.Radius.group, style: .continuous).fill(theme.segBg))
                .animation(.easeOut(duration: 0.25), value: model.state.pending.count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pairingRow(_ pairing: PendingPairing) -> some View {
        let isSelected = model.state.selected == pairing.uniqueid
        Button {
            model.send(.deviceSelected(pairing.uniqueid))
        } label: {
            HStack(spacing: 10) {
                LucideIcon(isSelected ? .circleCheck : .circle, size: 16)
                    .foregroundStyle(isSelected ? theme.accent : theme.label2)

                // §2.4: container restyle only -- this inner VStack's content/colors are
                // UNCHANGED (kept EXACTLY as-is per the design), so the concurrent friendly-name
                // worker's extra line slots in here without any collision with this pass.
                VStack(alignment: .leading, spacing: 1) {
                    // Source IP remains the SELECTION KEY and the only TRUSTED identifier -- an
                    // unspoofable identifier for a completed TCP getservercert (see
                    // pair_session_t::source_ip's doc comment, nvhttp.h). Selection above keys on
                    // `pairing.uniqueid`, never on anything rendered here.
                    //
                    // `hostnameHint` (device.displayHostname, ".local" stripped) is a best-effort,
                    // UNTRUSTED reverse-DNS label -- spoofable by anything with a PTR record for
                    // the address. When present it leads the line (friendlier than a bare IP); the
                    // IP always stays visible right after it, de-emphasized, so the trust anchor is
                    // never hidden -- just no longer the first thing the owner reads. The
                    // client-claimed pairing NAME is still deliberately never shown here (an
                    // attacker could pick something reassuring like "Living Room PC"); this hint
                    // comes from the HOST's own reverse lookup, not the client's claim.
                    if !pairing.displayHostname.isEmpty {
                        (Text(pairing.displayHostname)
                            .font(.body.weight(.medium))
                            .foregroundStyle(theme.label)
                         + Text(" · ")
                            .font(.caption2)
                            .foregroundStyle(theme.label2)
                         + Text(pairing.sourceIp)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(theme.label2))
                    } else {
                        Text(pairing.sourceIp)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .foregroundStyle(theme.label)
                    }
                    Text(ageLabel(pairing.ageSec))
                        .font(.caption2)
                        .foregroundStyle(theme.label2)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected ? theme.rowSelectedBg : Color.clear,
                in: RoundedRectangle(cornerRadius: SkylightTheme.Radius.control, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: SkylightTheme.Radius.control, style: .continuous)
                        .stroke(theme.accent, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            pairing.displayHostname.isEmpty
                ? "Device at \(pairing.sourceIp), \(ageLabel(pairing.ageSec))"
                : "\(pairing.displayHostname), at \(pairing.sourceIp), \(ageLabel(pairing.ageSec))"
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func ageLabel(_ ageSec: Int) -> String {
        ageSec < 60 ? "\(ageSec)s ago" : "\(ageSec / 60)m ago"
    }

    // MARK: - Derived render state

    private var isSubmitting: Bool {
        if case .submitting = model.state.step { return true }
        return false
    }

    /// The in-flight `Attempt` payload, whichever of `.submitting`/`.verifying` currently holds
    /// it -- used to surface `deviceLabel` in the verifying/waiting section without duplicating
    /// the step-matching switch already used for `isSubmitting`/`isPickingOrSubmitting`.
    private var currentAttempt: PairingState.Attempt? {
        switch model.state.step {
        case .submitting(let attempt): return attempt
        case .verifying(let attempt, _): return attempt
        default: return nil
        }
    }

    private var isPickingOrSubmitting: Bool {
        switch model.state.step {
        case .picking, .submitting: return true
        default: return false
        }
    }

    /// Surfaces the current `.picking` step's `Notice`, if any -- folds the old standalone
    /// `inlineError` `@State` var into a pure read of `model.state`.
    private var inlineErrorText: String? {
        guard case .picking(let notice) = model.state.step, let notice else { return nil }
        switch notice {
        case .phase1Rejected(let message):
            return message
        case .serviceUnreachable:
            return "Couldn’t reach the Moonwalk Host service — try again."
        case .didntPair:
            return "The device rejected pairing or the handshake expired. Start Pair again on the client and check its new PIN."
        case .verificationExpired:
            return "Pairing verification timed out. Check the client is still connected, then start Pair again."
        }
    }

    // MARK: - PIN entry (OTP idiom -- backspace, paste, larger boxes -- REUSED, repointed to
    // read/write `model.state.pin` instead of a local `[String]` array)

    private func pinChar(_ index: Int) -> String { pinEntry.slots[index] }

    @ViewBuilder
    private func digitBox(_ index: Int) -> some View {
        TextField("", text: Binding(
            get: { pinChar(index) },
            set: { newValue in handleDigitEntry(index: index, newValue: newValue) }
        ))
        .multilineTextAlignment(.center)
        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
        // §2.3: filled-but-unfocused digits read crisp (`theme.label`); empty boxes keep the
        // dimmer placeholder-empty look (`theme.label3`) -- no structural change, the text is
        // still exactly `pinChar(index)`.
        .foregroundStyle(pinChar(index).isEmpty ? theme.label3 : theme.label)
        .frame(width: 48, height: 58)
        .background(RoundedRectangle(cornerRadius: SkylightTheme.Radius.group, style: .continuous).fill(theme.segBg))
        .overlay {
            // Idle state shows a real 1px hairline border so empty/unfocused boxes still read as
            // visible fields. The focused box used to ALSO draw a hand-drawn 2px accent ring here
            // -- redundant with the native system focus ring macOS already draws around the
            // focused control, giving two rings at once. Dropped: the focused box now renders no
            // ring of its own at all, so only the system's ring shows.
            if focusedDigit != index {
                RoundedRectangle(cornerRadius: SkylightTheme.Radius.group, style: .continuous)
                    .stroke(theme.hairline, lineWidth: 1)
            }
        }
        // §2.3: the focused box gently lifts (1.04x, calm spring) -- subtle motion, not a
        // structural change; every handler below (`onKeyPress`, paste, auto-advance, `onSubmit`)
        // is untouched.
        .scaleEffect(focusedDigit == index ? 1.04 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: focusedDigit)
        .focused($focusedDigit, equals: index)
        // The standard OTP idiom this UI was always imitating. `.delete` is AppKit's ordinary
        // Backspace/Delete key. Only handle it ourselves when THIS box is already empty -- when
        // it holds a digit, returning `.ignored` lets the TextField's own editing clear that
        // digit in place first, and our handler only fires on the SECOND backspace, once there's
        // nothing left to delete here, moving focus back and clearing the previous box.
        .onKeyPress(.delete) {
            guard pinChar(index).isEmpty, index > 0 else { return .ignored }
            pinEntry.replace(at: index - 1, with: "")
            model.send(.pinChanged(pinEntry.pin))
            focusedDigit = index - 1
            return .handled
        }
        // Replace a slot directly on digit keys, before AppKit can append to its existing
        // field buffer. Modified paste retains the whole-PIN distribution path below.
        .onKeyPress(phases: .down) { keyPress in
            guard keyPress.modifiers.isEmpty, let character = keyPress.characters.first else { return .ignored }
            let isControl = character.unicodeScalars.allSatisfy { $0.value < 0x20 || $0.value == 0x7F }
            let isFunctionKey = character.unicodeScalars.allSatisfy { (0xF700...0xF8FF).contains($0.value) }
            if isControl || isFunctionKey { return .ignored }
            if character.isASCII && character.isNumber {
                handleDigitEntry(index: index, newValue: String(character))
            }
            return .handled
        }
        .onPasteCommand(of: [.plainText]) { _ in
            if let text = NSPasteboard.general.string(forType: .string) {
                handleDigitEntry(index: index, newValue: text)
            }
        }
        .onSubmit { model.send(.submitRequested) }
        .accessibilityLabel("PIN digit \(index + 1) of 4")
        .accessibilityValue(pinChar(index).isEmpty ? "empty" : pinChar(index))
    }

    private func handleDigitEntry(index: Int, newValue: String) {
        let numeric = newValue.filter { $0.isASCII && $0.isNumber }
        pinEntry.replace(at: index, with: numeric)
        model.send(.pinChanged(pinEntry.pin))
        if numeric.count > 1 {
            let count = min(numeric.count, 4)
            focusedDigit = count < 4 ? count : nil
            if !pinEntry.pin.isEmpty { model.send(.submitRequested) }
        } else if !numeric.isEmpty {
            focusedDigit = index < 3 ? index + 1 : nil
        }
    }
}
