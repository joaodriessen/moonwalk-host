import SwiftUI
import AppKit
import Foundation
import AVFoundation
import SkylightMenuCore

/// Native settings with acknowledged writes and independent Status/Support recovery actions.
/// Generic configuration changes are persisted for restart; dedicated setters apply live.
struct SettingsView: View {
    var host: HostConnection
    var loginItem: LoginItemManager
    var restart: RestartCoordinator
    /// The menu and Settings share the same pairing sheet state.
    var pairing: PairingPresentation
    var permissionSetup: PermissionSetupCoordinator
    var quitConfirmation: QuitConfirmation
    @State private var selectedSection: SettingsSection? = .status
    @State private var showPermissions = false
    @State private var loadState = SettingsLoadState()

    @State private var actionResultTitle = ""
    @State private var actionResultMessage: String?
    @State private var isRestartingViaBanner = false
    @State private var confirmBannerRestart = false

    /// The device offered in the per-row Unpair confirm alert, or `nil` when none is pending. A
    /// single optional (not a bool) so the alert's title/message can name the device without a
    /// second piece of state to keep in sync.
    @State private var unpairTarget: PairedClient?
    @State private var unpairSessionId: Int?
    @State private var showUnpairAllConfirm = false

    /// Apply a new base port only after confirmation, since it changes how
    /// paired clients reach this host.
    @State private var pendingPort: Int?

    /// Preserve text typed while a configuration read or earlier save is in flight.
    private var drafts: [String: String] {
        get { host.settings.drafts }
        nonmutating set { host.settings.drafts = newValue }
    }
    @State private var fieldErrors: [String: String] = [:]

    @State private var audioDevices: [AudioDeviceLister.Device] = []

    private enum DraftField: Hashable {
        case externalIP, port
    }
    @FocusState private var focusedDraftField: DraftField?

    var body: some View {
        permissionSheets
            // Land on Devices behind the sheet whenever pairing is presented.
            .onChange(of: pairing.isPresented) { _, newValue in
                if newValue {
                    selectedSection = .devices
                }
            }
    }

    // Keep each modifier group independently type-checked on supported Swift compilers.
    // These opaque view boundaries retain the original modifier order and state owners.
    private var navigationContent: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if restart.pendingRestart {
                    RestartBanner(isBusy: isRestartingViaBanner) { requestBannerRestart() }
                }
                saveErrors
                externalChanges
                detail
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 560)
        .background(WindowRestorationDisabler())
        .toolbar {
            Button("Refresh Settings") { Task { await host.refreshExternalConfiguration(force: true) } }
                .disabled(host.status != .connected)
        }
    }

    private var lifecycleContent: some View {
        navigationContent
        // Audit papercut 5(c): commit whichever draft field just lost focus (click-away, Tab,
        // window resign) — the same funnel `.onSubmit` already uses, just triggered by focus
        // loss instead of Return, so a typed edit is never silently dropped.
        .onChange(of: focusedDraftField) { oldValue, _ in
            commitDraftOnBlur(from: oldValue)
        }
        .onAppear {
            restart.synchronize(pendingKeys: host.settings.restartKeys)
            switch host.status {
            case .connected: handleLoad(.appeared(connected: true))
            case .connecting: handleLoad(.appeared(connected: false))
            case .offline, .untrusted:
                handleLoad(.appeared(connected: false))
                handleLoad(.connectionFailed)
            }
            refreshAudioDevices()
            Task { await host.refreshCaptureDisplays() }
        }
        .onChange(of: selectedSection) { _, section in
            if section == .devices { host.fetchPairedClients() }
            if section == .streaming { refreshAudioDevices() }
            if section == .display { Task { await host.refreshCaptureDisplays() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            Task { await host.refreshCaptureDisplays() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await host.refreshCaptureDisplays() }
            Task { await host.refreshExternalConfiguration() }
        }
        .onChange(of: host.settings.restartKeys) { _, keys in restart.synchronize(pendingKeys: keys) }
    }

    private var deviceLifecycleContent: some View {
        lifecycleContent
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshAudioDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshAudioDevices() }
        .onChange(of: host.status) { _, status in
            switch status {
            case .connected:
                handleLoad(.connectionChanged(connected: true))
                Task { await host.refreshCaptureDisplays() }
            case .connecting: handleLoad(.connectionChanged(connected: false))
            case .offline, .untrusted: handleLoad(.connectionFailed)
            }
        }
    }

    private var sessionConfirmations: some View {
        deviceLifecycleContent
        .alert("Restart Moonwalk Host?", isPresented: $confirmBannerRestart) {
            Button("Cancel", role: .cancel) {}
            Button("Restart", role: .destructive) { performBannerRestart() }
        } message: {
            Text("This stops the current streaming session. Moonwalk Host comes back on its own within a few seconds.")
        }
        .alert("Quit Moonwalk Host?", isPresented: Binding(
            get: { quitConfirmation.isPresented },
            set: { quitConfirmation.isPresented = $0 }
        )) {
            Button("Cancel", role: .cancel) { quitConfirmation.cancel() }
                .keyboardShortcut(.defaultAction)
            Button("Quit", role: .destructive) { quitConfirmation.confirm() }
        } message: {
            Text("Quitting ends any current streaming session and stops Moonwalk Host’s background service.")
        }
        .alert(
            "Unpair “\(unpairTarget?.displayName ?? "Device")”?",
            isPresented: Binding(
                get: { unpairTarget != nil },
                set: { if !$0 { unpairTarget = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Unpair", role: .destructive) { performUnpair() }
            if unpairSessionId != nil {
                Button("End Session and Unpair", role: .destructive) { performUnpair(endingSession: true) }
            }
        } message: {
            Text(unpairSessionId == nil ? "It will need a new PIN to connect again." : "Unpair requires a new PIN for future connections. Choose End Session and Unpair to also end this device’s current connection.")
        }
    }

    private var settingsConfirmations: some View {
        sessionConfirmations
        .alert("Unpair All Devices?", isPresented: $showUnpairAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Unpair All", role: .destructive) { performUnpairAll() }
        } message: {
            Text("This unpairs all \(host.paired.count) paired device\(host.paired.count == 1 ? "" : "s"). Each will need a new PIN to connect again, and this ends any session in progress.")
        }
        .alert("Change the base port?", isPresented: Binding(
            get: { pendingPort != nil },
            set: { if !$0 { pendingPort = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingPort = nil }
            Button("Change Port", role: .destructive) { commitPendingPort() }
        } message: {
            Text("This breaks pairing and discovery until every Moonlight client is set to match. Moonwalk Host also needs to restart for it to take effect.")
        }
        .alert(actionResultTitle, isPresented: Binding(
            get: { actionResultMessage != nil },
            set: { if !$0 { actionResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionResultMessage ?? "")
        }
    }

    private var permissionSheets: some View {
        settingsConfirmations
        // Pairing, attached to this window (docs/design/2026-07-18-pairing-attached-to-settings.md
        // §2.2): a `.sheet` presents on the window that hosts the presenting view -- here, the
        // Settings window -- regardless of this app's `.accessory` activation policy (that policy
        // only governs the Dock icon/app menu, not a window's ability to host a sheet). Lifecycle
        // is carried entirely by `PairingSheet`'s own `onAppear`/`onDisappear` -> `.sheetOpened`/
        // `.sheetClosed`; nothing here reaches into the reducer.
        .sheet(isPresented: Binding(
            get: { pairing.isPresented },
            set: { pairing.isPresented = $0 }
        )) {
            PairingSheet(host: host)
        }
        .sheet(isPresented: $showPermissions) {
            VStack(alignment: .trailing, spacing: 16) {
                PermissionChecklistView(host: host, coordinator: permissionSetup)
                Button("Close") { showPermissions = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .frame(width: 430)
        }
    }

    private var saveErrors: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(host.settings.failures.values.sorted(by: { $0.key < $1.key })) { failure in
                HStack(alignment: .top) {
                    Label("\(failure.label): \(failure.message)", lucide: .triangleAlert, size: 14)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Retry") { host.settings.retry(key: failure.key) }
                        .accessibilityLabel("Retry saving \(failure.label)")
                }
            }
        }
        .padding(host.settings.failures.isEmpty ? 0 : 12)
    }

    private var externalChanges: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(host.settings.conflicts.values.sorted(by: { $0.key < $1.key })) { conflict in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(conflict.key) changed outside this window. Your edit is kept.").font(.callout)
                    Text("Outside: \(conflict.external ?? "Default") · Your edit: \(conflict.local)").font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Use Outside Value") { Task { await host.resolveExternalConflict(key: conflict.key, useExternal: true) } }
                        Button("Keep My Edit") { Task { await host.resolveExternalConflict(key: conflict.key, useExternal: false) } }
                    }
                    .disabled(host.settings.pending.contains(conflict.key))
                }
            }
            if let error = host.externalRefreshError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedSection) {
            ForEach(SettingsSection.allCases) { section in
                Label {
                    Text(section.title)
                } icon: {
                    SectionChip(glyph: section.chipGlyph, color: section.chipColor)
                }
                .tag(section)
                .accessibilityLabel(section.title)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if selectedSection == .status {
            sectionForm(.status)
        } else {
            switch loadState.phase {
            case .idle, .waitingForHost:
                unavailableState(
                    glyph: .hourglass,
                    title: "Starting Moonwalk Host…",
                    message: "Settings will load as soon as the streaming host is ready."
                )
            case .loading:
                ProgressView("Loading configuration…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                VStack(spacing: 12) {
                    unavailableState(
                        glyph: .triangleAlert,
                        title: "Configuration unavailable",
                        message: "Moonwalk Host could not load its settings. Check that the host is running, then try again."
                    )
                    Button("Try Again") {
                        if host.status != .connected { host.connect() }
                        handleLoad(.appeared(connected: host.status == .connected))
                    }
                }
            case .loaded:
                if let section = selectedSection {
                    sectionForm(section)
                } else {
                    unavailableState(
                        glyph: .panelLeft,
                        title: "Choose a section",
                        message: "Pick a category from the sidebar."
                    )
                }
            }
        }
    }

    private func handleLoad(_ event: SettingsLoadEvent) {
        for effect in loadState.reduce(event: event) {
            guard case .load(let generation) = effect else { continue }
            Task {
                let payload = await host.fetchConfigSchemaAndValues()
                guard loadState.accepts(generation: generation) else { return }
                let success = payload.map(host.applyConfigPayload) ?? false
                host.fetchPairedClients()
                _ = loadState.reduce(event: .loadFinished(generation: generation, success: success))
            }
        }
    }

    /// Native empty-state (ContentUnavailableView, macOS 14+, unlocked by the floor raise).
    @ViewBuilder
    private func unavailableState(glyph: LucideGlyph, title: String, message: String) -> some View {
        ContentUnavailableView {
            Label { Text(title) } icon: { LucideIcon(glyph, size: 40) }
        } description: {
            Text(message)
        }
    }

    @ViewBuilder
    private func sectionForm(_ section: SettingsSection) -> some View {
        // Each pane is a `Form { }.formStyle(.grouped)`, which is ALREADY its own scrolling
        // container with the native thin Tahoe overlay scrollbar. Do NOT wrap it in an outer
        // ScrollView — that nests two scroll views, and the outer one renders a heavy,
        // always-present, non-native scrollbar that fights the Form's own (the "weird
        // scrollbars" bug, 2026-07-16). The Form scrolls itself; nothing wraps it.
        Group {
            switch section {
            case .status:
                StatusPaneView(
                    host: host,
                    restart: restart,
                    loginItem: loginItem,
                    onManageDevices: { selectedSection = .devices },
                    onCheckPermissions: openOnboarding,
                    configurationAvailable: loadState.phase == .loaded,
                    onRetryConfiguration: {
                        if host.status != .connected { host.connect() }
                        handleLoad(.appeared(connected: host.status == .connected))
                    }
                )
            case .streaming: streamingForm
            case .display: displayForm
            case .devices: devicesForm
            case .network: networkForm
            }
        }
        .formStyle(.grouped)
        .navigationTitle(section.title)
    }

    /// A caption for a single control living inside a multi-control `AdvancedDisclosure` group,
    /// where a `Section` footer can't target one specific row. Not a resurrection of the retired
    /// `SettingsRow` — just a plain secondary line, paired with its control in a `VStack` by the
    /// call site.
    @ViewBuilder
    private func rowCaption(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Streaming (Video + Sound)

    /// `Video engine` picker options. Build note: `setConfigValue("encoder", "")` was verified
    /// against the host (src/platform/macos/xpc_control.mm's `SetConfigValueValidated`) and does
    /// NOT persist an "Automatic" choice — an empty value hits that function's "empty value =
    /// nothing to write" early-return, so the write silently no-ops instead of clearing the key,
    /// and the dedicated `setEncoder:reply:` convenience path flatly REJECTS anything but
    /// "videotoolbox"/"software". This ships Hardware/Software only, via the working convenience
    /// setter — no Automatic option in the UI.
    private var encoderBinding: Binding<String> {
        Binding(
            get: { host.encoder.isEmpty ? "videotoolbox" : host.encoder },
            set: { value in
                guard host.settings.conflicts["encoder"] == nil else { return }
                host.setEncoder(value) { success, _ in
                    if success { restart.markPersistedChange(key: "encoder") }
                }
            }
        )
    }

    private var fpsToggleBinding: Binding<Bool> {
        Binding(
            get: { host.fpsTarget != 0 },
            set: { host.setFpsTarget($0 ? 30 : 0) }
        )
    }

    private var isSoftwareEncoder: Bool { encoderBinding.wrappedValue == "software" }

    private var vtRealtimeBinding: Binding<Bool> {
        Binding(
            get: { ConfigBool.isOn(host.configValues["vt_realtime"], default: true) },
            set: { setBool("vt_realtime", $0) }
        )
    }

    private var swPresetBinding: Binding<SoftwarePreset> {
        Binding(
            get: { SoftwarePreset(rawValue: host.configValues["sw_preset"] ?? "") ?? .superfast },
            set: { setString("sw_preset", $0.rawValue) }
        )
    }

    private var codecBinding: Binding<VideoCodec> {
        Binding(
            get: { VideoCodec.from(hevcMode: host.configValues["hevc_mode"], av1Mode: host.configValues["av1_mode"]) },
            set: { newValue in
                guard host.settings.conflicts["hevc_mode"] == nil, host.settings.conflicts["av1_mode"] == nil else { return }
                host.setCodecPolicy(newValue) { success, _ in
                    if success { restart.markPersistedChange(key: "hevc_mode") }
                }
            }
        )
    }

    private var streamAudioBinding: Binding<Bool> {
        Binding(
            get: { ConfigBool.isOn(host.configValues["stream_audio"], default: true) },
            set: { setBool("stream_audio", $0) }
        )
    }

    private var audioSinkValue: String { drafts["audio_sink"] ?? host.configValues["audio_sink"] ?? "" }

    private struct AudioSinkOption: Identifiable {
        let id: String
        let label: String
    }

    /// The host's native system-audio sentinels (src/platform/macos/microphone.mm:122-124):
    /// "system"/"desktop"/"screencapturekit" all mean "capture everything via ScreenCaptureKit",
    /// which is the recommended setup — NOT a CoreAudio device name. They must be a first-class
    /// named option, or a working "system" value shows up as "system (not found)".
    private static let systemAudioSentinels: Set<String> = ["system", "desktop", "screencapturekit"]

    private var audioSinkOptions: [AudioSinkOption] {
        // System audio first (the recommended sink), then real input devices, then mic-off.
        var options = [AudioSinkOption(id: "system", label: "This Mac’s system audio (recommended)")]
        options += audioDevices.map { AudioSinkOption(id: $0.name, label: $0.name) }
        let raw = audioSinkValue
        // A non-empty value that's neither a system-audio sentinel nor a live device is a stale
        // reference to an unplugged device — surface it honestly rather than silently dropping it.
        if !raw.isEmpty
            && !Self.systemAudioSentinels.contains(raw.lowercased())
            && !audioDevices.contains(where: { $0.name == raw }) {
            options.append(AudioSinkOption(id: raw, label: "\(raw) (not found)"))
        }
        return options
    }

    private var audioSinkBinding: Binding<String> {
        Binding(
            // Collapse every system-audio sentinel ("desktop"/"screencapturekit") onto the one
            // "system" option so the picker always resolves a selection.
            get: {
                let raw = audioSinkValue
                return raw.isEmpty || Self.systemAudioSentinels.contains(raw.lowercased()) ? "system" : raw
            },
            set: { setString("audio_sink", $0) }
        )
    }

    private var streamingForm: some View {
        Form {
            Section {
                Picker("Video codec", selection: codecBinding) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text(codec.label).tag(codec)
                    }
                }
                if let error = fieldErrors["hevc_mode"] ?? fieldErrors["av1_mode"] {
                    inlineError(error)
                }
            } header: {
                Text("Video")
            } footer: {
                Text("The client chooses from the formats this Mac offers. H.264 stays available as a fallback. Main10 choices need 10-bit support. Restart Moonwalk Host to apply a codec change.")
            }

            Section {
                AdvancedDisclosure {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Video engine", selection: encoderBinding) {
                            Text("Hardware").tag("videotoolbox")
                            Text("Software").tag("software")
                        }
                        rowCaption("Hardware uses this Mac’s media engine. Try Software to check whether a problem is specific to hardware encoding.")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Low-latency encoding", isOn: vtRealtimeBinding)
                        rowCaption("Favors quicker delivery over compression efficiency. Leave this on if you want the desktop to respond promptly.")
                    }

                    if isSoftwareEncoder {
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("Software encoding speed", selection: swPresetBinding) {
                                ForEach(SoftwarePreset.allCases) { preset in
                                    Text(preset.displayLabel).tag(preset)
                                }
                            }
                            rowCaption("Faster settings use less CPU. Slower settings can retain more detail at the same bitrate.")
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Keep motion smooth when the screen is still", isOn: fpsToggleBinding)
                        rowCaption("Keeps a 30 FPS target when the desktop is still so motion can resume smoothly.")
                    }
                }
            } footer: {
                Text("Video engine and software encoding speed take effect after Moonwalk Host restarts.")
            }

            Section {
                Toggle("Stream this Mac’s sound", isOn: streamAudioBinding)

                Picker("Sound source", selection: audioSinkBinding) {
                    ForEach(audioSinkOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .disabled(!streamAudioBinding.wrappedValue)
                Button("Refresh Sound Sources") { refreshAudioDevices() }
                SoundTestView(host: host, source: audioSinkBinding.wrappedValue)

                if let error = fieldErrors["audio_sink"] {
                    inlineError(error)
                }
            } header: {
                Text("Sound")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("“This Mac’s system audio” captures everything playing on this Mac directly through macOS — no extra software needed. Choose an input device instead to stream from a microphone or a virtual audio tool like BlackHole.")
                    Button("About audio capture options…") {
                        NSWorkspace.shared.open(AudioDeviceLister.blackHoleInfoURL)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: - Display

    private var displayForm: some View {
        Form {
            Section {
                Toggle("Virtual display", isOn: Binding(
                    get: { host.virtualDisplay },
                    set: { host.setVirtualDisplay($0) }
                ))
            } footer: {
                Text("Asks macOS for a separate screen at the client’s requested size. Turn this off to share an existing display.")
            }

            Section {
                AdvancedDisclosure {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Capture display", selection: Binding(
                            get: { host.configValues["output_name"] ?? "" },
                            set: { setString("output_name", $0) }
                        )) {
                            ForEach(CaptureDisplay.options(host.captureDisplays, selected: host.configValues["output_name"] ?? "")) { display in
                                Text(display.name).tag(display.id)
                            }
                        }
                        .disabled(host.virtualDisplay)
                        rowCaption(host.virtualDisplay
                            ? "Not used while Virtual display is on."
                            : "Automatic captures the main display. An unavailable saved display stays selected until you choose another.")
                        if !host.captureDisplaysAvailable {
                            Text("Couldn’t list current displays.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Refresh Displays") { Task { await host.refreshCaptureDisplays() } }
                        if let error = fieldErrors["output_name"] {
                            inlineError(error)
                        }
                    }

                }
            } footer: {
                Text("The client requests the virtual display’s size and refresh rate. Restart Moonwalk Host after choosing a different capture display.")
            }
        }
    }

    // MARK: - Devices

    private var quitOnDisconnectBinding: Binding<Bool> {
        Binding(get: { host.quitOnDisconnect }, set: { host.setQuitOnDisconnect($0) })
    }

    private var keyboardBinding: Binding<Bool> {
        Binding(
            get: { ConfigBool.isOn(host.configValues["keyboard"], default: true) },
            set: { setBool("keyboard", $0) }
        )
    }

    private var mouseBinding: Binding<Bool> {
        Binding(
            get: { ConfigBool.isOn(host.configValues["mouse"], default: true) },
            set: { setBool("mouse", $0) }
        )
    }

    /// `clipboard_sync` is bool/default-true in `config_schema.json`, declared identically to
    /// `keyboard`/`mouse` — the compiled default is also `true`, so an absent conf key correctly
    /// reads ON here (no default-mismatch risk, contrast `web_ui_enabled`'s earlier bug).
    /// Round-trips through the same generic `setConfigValue` XPC path; zero host change.
    private var clipboardSyncBinding: Binding<Bool> {
        Binding(
            get: { ConfigBool.isOn(host.configValues["clipboard_sync"], default: true) },
            set: { setBool("clipboard_sync", $0) }
        )
    }

    /// The bare "Pair New Device…" action, shared by both device-list states below so the action
    /// itself is never duplicated -- only its surrounding row differs (item 5). Settings is
    /// already open and frontmost here -- no window hop, no run-loop hop needed (design §2.4);
    /// the scene hosting this `.sheet` is guaranteed to already exist.
    private var pairNewDeviceAction: some View {
        Button("Pair New Device…") {
            pairing.isPresented = true
        }
    }

    private var devicesForm: some View {
        Form {
            if host.richStatus.streaming {
                Section("Current Connection") {
                    Text(host.richStatus.clientName.isEmpty ? "Device identity unavailable" : host.richStatus.clientName)
                    LiveSessionActionsView(host: host)
                }
            }
            Section {
                if host.pairedClients.phase == .unavailable {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(host.pairedClients.hasValue
                              ? "Couldn’t refresh devices. Showing the last known list."
                              : "Paired devices are unavailable.", lucide: .triangleAlert, size: 14)
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Try Again") { host.fetchPairedClients() }
                    }
                }
                if !host.pairedClients.hasValue {
                    if host.pairedClients.phase == .loading { ProgressView("Loading paired devices…") }
                    pairNewDeviceAction
                } else if host.paired.isEmpty {
                    // Item 5: the empty-state text and the Pair button are one `VStack` (one Form
                    // row), not two separate top-level rows — separate rows each carry their own
                    // Form row padding, which read as an awkward gap between them.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No devices paired yet.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            pairNewDeviceAction
                        }
                    }
                } else {
                    ForEach(host.paired) { client in
                        HStack {
                            Text(client.displayName)
                            if host.richStatus.streaming, host.richStatus.clientUUID == client.uuid {
                                Text("Connected").font(.caption).foregroundStyle(.green)
                            }
                            Spacer()
                            Button("Unpair") {
                                unpairTarget = client
                                unpairSessionId = host.richStatus.streaming && host.richStatus.clientUUID == client.uuid ? host.richStatus.sessionId : nil
                            }
                            .buttonStyle(.link)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Unpair \(client.displayName)")
                        }
                    }

                    Divider()

                    LabeledContent {
                        pairNewDeviceAction
                    } label: {
                        rowCaption("Add another device to stream to this Mac.")
                    }

                    // The confirmation carries the destructive action.
                    LabeledContent {
                        Button("Unpair All Devices…") {
                            showUnpairAllConfirm = true
                        }
                        .buttonStyle(.bordered)
                    } label: {
                        rowCaption("Unpairs every paired device. Each will need a new PIN to connect again.")
                    }
                }
            } header: {
                Text("Paired Devices")
            } footer: {
                Text("Devices you’ve paired with this Mac. Unpair one to require it to pair again.")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Allow keyboard control", isOn: keyboardBinding)
                    rowCaption("Lets the connected device type on this Mac.")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Allow mouse control", isOn: mouseBinding)
                    rowCaption("Lets the connected device move and click this Mac’s pointer.")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("End session when the last device disconnects", isOn: quitOnDisconnectBinding)
                    rowCaption("Leave off to allow the Desktop session to resume after an interruption. Capture and the virtual display stop either way.")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Share clipboard with devices", isOn: clipboardSyncBinding)
                    rowCaption("Lets a paired device copy and paste to and from this Mac while streaming. On by default; turn off for a shared or public Mac.")
                }
            }
        }
    }

    // MARK: - Network

    private var upnpBinding: Binding<Bool> {
        Binding(
            get: { ConfigBool.isOn(host.configValues["upnp"], default: false) },
            set: { setBool("upnp", $0) }
        )
    }

    private var wanEncryptionBinding: Binding<EncryptionMode> {
        Binding(
            get: { EncryptionMode(rawValue: Int(host.configValues["wan_encryption_mode"] ?? "") ?? 1) ?? .optional },
            set: { setString("wan_encryption_mode", String($0.rawValue)) }
        )
    }

    private var lanEncryptionBinding: Binding<EncryptionMode> {
        Binding(
            get: { EncryptionMode(rawValue: Int(host.configValues["lan_encryption_mode"] ?? "") ?? 0) ?? .off },
            set: { setString("lan_encryption_mode", String($0.rawValue)) }
        )
    }

    private var committedPort: Int { Int(host.configValues["port"] ?? "") ?? 47989 }

    private var portBinding: Binding<Int> {
        Binding(
            get: { pendingPort ?? committedPort },
            set: { newValue in
                guard newValue != committedPort else { return }
                pendingPort = newValue
            }
        )
    }

    /// Audit papercut 5(b): a `Stepper` is a poor fit for a 5-digit port a user wants to type
    /// directly. This draft mirrors the pattern the other generic string fields use (typed text,
    /// committed via `commitPortDraft`), while still funneling into `portBinding`'s existing
    /// stage-then-confirm write (unchanged) — cancelling the resulting alert reverts the display
    /// to `committedPort` for free, same as before.
    private var portDraftBinding: Binding<String> {
        Binding(
            get: { drafts["port"] ?? String(portBinding.wrappedValue) },
            set: { drafts["port"] = $0 }
        )
    }

    private func commitPortDraft() {
        guard let raw = drafts["port"] else { return }
        guard host.settings.conflicts["port"] == nil else {
            fieldErrors["port"] = "Resolve the outside change above before saving this edit."; return
        }
        guard let value = Int(raw), (1019...65514).contains(value) else {
            fieldErrors["port"] = "Enter a number between 1019 and 65514."
            return
        }
        fieldErrors["port"] = nil
        drafts["port"] = nil
        portBinding.wrappedValue = value
    }

    private var webUIEnabledBinding: Binding<Bool> {
        Binding(
            // default: false matches the compiled default (config.cpp) -- configValues reflects
            // only the raw conf file (GetConfigValuesJSON parses the file, not resolved defaults),
            // so a fresh install with no web_ui_enabled line must read as OFF, not ON.
            get: { ConfigBool.isOn(host.configValues["web_ui_enabled"], default: false) },
            set: { setBool("web_ui_enabled", $0) }
        )
    }

    private var webConsoleAccessBinding: Binding<WebConsoleAccess> {
        Binding(
            get: { WebConsoleAccess(rawValue: host.configValues["origin_web_ui_allowed"] ?? "") ?? .lan },
            set: { setString("origin_web_ui_allowed", $0.rawValue) }
        )
    }

    private var ipv6Binding: Binding<Bool> {
        Binding(
            get: { (host.configValues["address_family"] ?? "ipv4") == "both" },
            set: { setString("address_family", $0 ? "both" : "ipv4") }
        )
    }

    private var networkForm: some View {
        Form {
            // §1.5: the default Network view collapses to a single calm sentence — every actual
            // control (UPnP, encryption, port, web UI) moves into the one AdvancedDisclosure
            // below. Reversible, view-only; nothing here changes which keys are written or read.
            Section {
                ConnectionHandoffView(host: host)
            }

            Section {
                AdvancedDisclosure {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Set up router automatically (UPnP)", isOn: upnpBinding)
                        rowCaption("Asks your router to forward the ports Moonwalk Host needs for streaming over the internet. Works only if your router has UPnP enabled — otherwise forward the ports yourself.")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Internet encryption", selection: wanEncryptionBinding) {
                            ForEach(EncryptionMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        rowCaption("Encrypts streams coming from outside your network. Required is safest for internet streaming; encryption costs a little performance.")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Local network encryption", selection: lanEncryptionBinding) {
                            ForEach(EncryptionMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        rowCaption("Encrypts streams on your own network. Usually unnecessary at home and costs a little performance.")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Base port", text: portDraftBinding)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedDraftField, equals: .port)
                            .onSubmit { commitPortDraft() }
                        rowCaption("The main port devices connect to; the others derive from it. Leave it at 47989 unless you have a port conflict.")
                        if let error = fieldErrors["port"] {
                            inlineError(error)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Web configuration page", isOn: webUIEnabledBinding)
                        rowCaption("Moonwalk Host’s browser-based settings page. This native app covers pairing and everyday Mac settings. Enable the browser page when you need its additional settings or app-list editor.")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Web console access", selection: webConsoleAccessBinding) {
                            ForEach(WebConsoleAccess.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .disabled(!webUIEnabledBinding.wrappedValue)
                        rowCaption("Who can reach Moonwalk Host’s browser configuration page. ‘Anyone’ exposes it to the internet — a real security risk. Local network is the safe default.")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Public IP address", text: Binding(
                            get: { drafts["external_ip"] ?? host.configValues["external_ip"] ?? "" },
                            set: { drafts["external_ip"] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedDraftField, equals: .externalIP)
                        .onSubmit {
                            if let value = SettingsStore.submittedDraft(drafts["external_ip"]) { setString("external_ip", value) }
                        }
                        rowCaption("Set only if Moonwalk Host detects the wrong internet address for your connection. Normally left blank.")
                        if let error = fieldErrors["external_ip"] {
                            inlineError(error)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Allow IPv6 connections", isOn: ipv6Binding)
                        rowCaption("Also listen over IPv6, not just IPv4. Enable if your network is IPv6-only.")
                    }
                }
            } footer: {
                Text("Network changes take effect after Moonwalk Host restarts.")
            }
        }
    }

    // MARK: - Actions

    private func openOnboarding() {
        showPermissions = true
    }

    private func refreshAudioDevices() {
        audioDevices = AudioDeviceLister.inputDevices()
    }

    private func requestBannerRestart() {
        if RestartCoordinator.requiresConfirmation(streaming: host.richStatus.streaming) {
            confirmBannerRestart = true
        } else {
            performBannerRestart()
        }
    }

    private func performBannerRestart() {
        isRestartingViaBanner = true
        Task {
            await host.settings.waitForPendingSaves()
            HostProcessActions.restartHost { result in
                isRestartingViaBanner = false
                if result.success {
                    restart.clear()
                }
                actionResultTitle = result.success ? "Restart requested" : "Restart failed"
                actionResultMessage = result.success
                    ? "Moonwalk Host is relaunching."
                    : (result.output.isEmpty ? "Unknown error." : result.output)
            }
        }
    }

    private func commitPendingPort() {
        guard let value = pendingPort else { return }
        pendingPort = nil
        setString("port", String(value))
    }

    /// Audit papercut 5(c): fires on focus-loss for whichever draft field the user just left.
    /// Only commits fields that actually have a staged edit (`drafts[key] != nil`) — a field the
    /// user merely tabbed through without typing must not trigger a redundant write.
    private func commitDraftOnBlur(from field: DraftField?) {
        guard let field else { return }
        switch field {
        case .externalIP:
            guard let value = drafts["external_ip"] else { return }
            setString("external_ip", value)
        case .port:
            guard drafts["port"] != nil else { return }
            commitPortDraft()
        }
    }

    private func performUnpair(endingSession: Bool = false) {
        guard let target = unpairTarget else { return }
        let sessionId = unpairSessionId
        unpairTarget = nil
        unpairSessionId = nil
        if endingSession, let sessionId {
            Task {
                guard await host.endSession(sessionId: sessionId, deviceUUID: target.uuid) else {
                    actionResultTitle = "Session changed"
                    actionResultMessage = "The selected connection could not be ended. Refresh Devices and try again."
                    return
                }
                unpair(target)
            }
        } else { unpair(target) }
    }

    private func unpair(_ target: PairedClient) {
        host.unpair(uuid: target.uuid) { success in
            actionResultTitle = success ? "Device unpaired" : "Unpair failed"
            actionResultMessage = success
                ? "\(target.displayName) will need a new PIN to connect again."
                : "Couldn’t unpair. Try again."
        }
    }

    private func performUnpairAll() {
        host.unpairAll { success in
            actionResultTitle = success ? "All devices unpaired" : "Unpair failed"
            actionResultMessage = success
                ? "Every device will need a new PIN to connect again."
                : "Couldn’t unpair. Try again."
        }
    }

    // MARK: - Generic config-key writes

    /// The single funnel every restart-gated ("persist-21") control writes through. On success,
    /// arms `restart` — this is the entire mechanical basis of the trust fix (design §0.1, §3.1):
    /// a control that writes here is restart-pending; a control that calls a dedicated
    /// `HostConnection` setter directly (fps/virtual display/quit-on-disconnect) is live
    /// and never touches this path.
    private func setBool(_ key: String, _ value: Bool) {
        guard host.settings.conflicts[key] == nil else { return }
        fieldErrors[key] = nil
        host.setConfigValue(key, value: ConfigBool.string(value)) { success, message in
            if success {
                restart.markPersistedChange(key: key)
            }
        }
    }

    private func setString(_ key: String, _ value: String) {
        guard host.settings.conflicts[key] == nil else { return }
        fieldErrors[key] = nil
        host.setConfigValue(key, value: value) { success, message in
            if success {
                if SettingsStore.shouldClearDraft(current: drafts[key], submitted: value) { drafts[key] = nil }
                restart.markPersistedChange(key: key)
            }
        }
    }

    @ViewBuilder
    private func inlineError(_ message: String) -> some View {
        Label(message, lucide: .triangleAlert, size: 12)
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityLabel("Error: \(message)")
    }
}
