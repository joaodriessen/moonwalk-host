import SwiftUI
import AppKit
import SkylightMenuCore

/// Settings — Status: the "missing piece" (design doc §2.2). First sidebar item, System-Settings
/// style. Read + remediate: daemon reachability, live session stats, paired-device count,
/// permission grants, and general maintenance actions — all data already flows over XPC through
/// the existing `HostConnection` surface (`richStatus`, `permissionState`, `paired`, `status`), so
/// there is no new backend and no new XPC method here. Rows are read-outs (`LabeledContent`), not
/// controls; remediation buttons live next to the state they explain (Restart Skylight next to
/// reachability's offline case; Check Permissions next to an ungranted permission), per the
/// design's "remediation belongs next to what it fixes" rule.
///
/// The window-level restart-pending banner (`RestartBanner`, driven by `RestartCoordinator`) is
/// rendered by `SettingsView` above every pane, Status included — this view does not duplicate it
/// with a second in-form "restart pending" row.
struct StatusPaneView: View {
    var host: HostConnection
    var restart: RestartCoordinator
    var loginItem: LoginItemManager
    var onManageDevices: () -> Void
    var onCheckPermissions: () -> Void
    var configurationAvailable: Bool
    var onRetryConfiguration: () -> Void

    @State private var showRestartConfirm = false
    @State private var actionResultTitle = ""
    @State private var actionResultMessage: String?
    @State private var showRemoveServiceConfirm = false
    @State private var showUninstallConfirm = false
    @State private var diagnosticsTask: Task<Void, Never>?

    /// Item 3 (General → Status merge): the former `SettingsView.generalForm`'s uncommitted
    /// `sunshine_name` draft/error state, moved here with it. Scoped to this one field (unlike
    /// `SettingsView`'s multi-key `drafts`/`fieldErrors` dictionaries) since this pane only ever
    /// writes this one generic string key.
    private var sunshineNameDraft: String? {
        get { host.settings.drafts["sunshine_name"] }
        nonmutating set { host.settings.drafts["sunshine_name"] = newValue }
    }
    @FocusState private var sunshineNameFocused: Bool

    var body: some View {
        Form {
            Section("Moonwalk Host") {
                LabeledContent("Streaming service", value: reachabilityText)

                LabeledContent("Streaming") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(sessionHeadline)
                        if let detail = sessionDetail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LiveSessionActionsView(host: host)
                if host.status != .connected { HostRepairView(host: host) }
            }

            Section("Devices & Permissions") {
                LabeledContent("Paired devices") {
                    HStack(spacing: 6) {
                        Text(host.pairedClients.hasValue ? "\(host.paired.count)" : (host.pairedClients.phase == .loading ? "Loading…" : "Unavailable"))
                        if host.pairedClients.phase == .unavailable {
                            Text("Couldn’t refresh").font(.caption).foregroundStyle(.secondary)
                            Button("Retry") { host.fetchPairedClients() }.buttonStyle(.link)
                        }
                        Button("Manage") { onManageDevices() }
                            .buttonStyle(.link)
                    }
                }

                LabeledContent("Screen Recording") {
                    if host.status == .connected { permissionValue(host.permissionState.screenRecording) }
                    else { Text("Unavailable").foregroundStyle(.secondary) }
                }

                LabeledContent("Accessibility") {
                    if host.status == .connected { permissionValue(host.permissionState.accessibility) }
                    else { Text("Unavailable").foregroundStyle(.secondary) }
                }

                HStack {
                    Spacer()
                    Button("Check Permissions…") { onCheckPermissions() }
                }
            }

            Section("Recovery") {
                LabeledContent {
                    Button("Restart Moonwalk Host…") { requestRestart() }
                        .buttonStyle(.bordered)
                } label: {
                    rowCaption("Restart if the connection or picture is stuck. This ends the current session and applies pending settings.")
                }
            }

            if !configurationAvailable {
                Section {
                    Text("Configuration is unavailable. Status and support actions are still available.")
                        .foregroundStyle(.secondary)
                    Button("Try Loading Settings Again", action: onRetryConfiguration)
                }
            }
            generalSection

            aboutSection
            supportSection
            Section("Saved Setups") { ConfigurationSnapshotsView(host: host) }
        }
        .onAppear {
            // The Status pane DISPLAYS permission grants and the paired-device count, so it must
            // fetch them — otherwise it shows the unfetched defaults (permissions "Not Granted"
            // even though the daemon holds the grants, paired count 0). These are on-demand
            // fetches, not part of the periodic poll (2026-07-16 debug pass).
            refreshStatus()
            host.fetchPairedClients()
        }
        .onDisappear { diagnosticsTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshStatus() }
        .onChange(of: host.status) { _, status in
            if status == .connected { refreshStatus() }
        }
        // Item 3/audit papercut 5(c) parity: commit the `sunshine_name` draft on blur (click-away,
        // Tab, window resign), same as `SettingsView`'s `commitDraftOnBlur` — only if the user
        // actually staged an edit (`sunshineNameDraft != nil`), so tabbing through untouched never
        // triggers a redundant write.
        .onChange(of: sunshineNameFocused) { wasFocused, isFocused in
            guard wasFocused, !isFocused, let value = sunshineNameDraft else { return }
            commitSunshineName(value)
        }
        .alert("Restart Moonwalk Host?", isPresented: $showRestartConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Restart", role: .destructive) { performRestart() }
        } message: {
            Text("This stops any current session. Moonwalk Host comes back on its own within a few seconds.")
        }
        .alert(actionResultTitle, isPresented: Binding(
            get: { actionResultMessage != nil },
            set: { if !$0 { actionResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionResultMessage ?? "")
        }
        .alert("Remove Moonwalk Host’s background service?", isPresented: $showRemoveServiceConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Service") { removeBackgroundService() }
        } message: {
            Text("Turns off Open at Login and removes the background service. Keeps settings and paired devices. You can then move Moonwalk Host to Trash.")
        }
        .alert("Uninstall Moonwalk Host?", isPresented: $showUninstallConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { uninstallSkylight() }
        } message: {
            Text("Turns off Open at Login, removes the background service, deletes your settings and paired devices, moves Moonwalk Host to the Trash, and quits.")
        }
    }

    // MARK: - Chrome helpers

    /// Mirrors `SettingsView.rowCaption` (same styling: footnote, secondary) — duplicated rather
    /// than shared because the two are separate `View` types in separate files with no existing
    /// common chrome home for a single-line `Text` helper this small.
    @ViewBuilder
    private func rowCaption(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// Mirrors `SettingsView.inlineError` (same styling) — duplicated for the same reason as
    /// `rowCaption` above.
    @ViewBuilder
    private func inlineError(_ message: String) -> some View {
        Label(message, lucide: .triangleAlert, size: 12)
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityLabel("Error: \(message)")
    }

    // MARK: - General (item 3: merged in from the retired General tab)

    /// Audit defect 2: `host.configValues["sunshine_name"]` mirrors the raw `sunshine.conf` file
    /// only (empty when the key is absent) — it never reflects the runtime default the daemon
    /// actually computes and advertises to pairing/discovering clients, which is this Mac's real
    /// network hostname. `Host.current().localizedName` is the user-facing computer name, the
    /// same identity the empty-key runtime default resolves to.
    private var resolvedMacName: String { Host.current().localizedName ?? "This Mac" }

    private var detailedLoggingBinding: Binding<Bool> {
        Binding(
            get: { (host.configValues["min_log_level"] ?? "2") == "0" },
            set: { setDetailedLogging($0) }
        )
    }

    private var sunshineNameBinding: Binding<String> {
        Binding(
            get: { sunshineNameDraft ?? host.configValues["sunshine_name"] ?? "" },
            set: { sunshineNameDraft = $0 }
        )
    }

    /// Item 4: a persistent left-side description ("Name devices see") plus the editable field on
    /// the right, replacing the old build where the label was only the grey placeholder text and
    /// the explanation lived in a Section footer the user could easily miss. The "empty uses this
    /// Mac's name" hint now lives directly under the label instead of below the whole Section, but
    /// stays exactly as discoverable.
    private var generalSection: some View {
        Group {
            Section("General") {
                LabeledContent {
                    // Deliberately NO placeholder text here (live-verified: this exact TextField,
                    // inside this LabeledContent's trailing slot, in this Form, renders whatever
                    // string is passed as its placeholder OUTSIDE the visible rounded-border box --
                    // wrapping and hyphenating like a narrow multi-line Text column, not like an
                    // NSTextField's native single-line placeholder at all -- across every width/
                    // alignment variant tried. Rather than fight that rendering defect, the
                    // resolved-name information it was meant to convey lives entirely in the
                    // caption below (which renders correctly, being a plain `Text`), so no
                    // placeholder string is needed to communicate it.
                    TextField("", text: sunshineNameBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .focused($sunshineNameFocused)
                        .onSubmit {
                            if let value = SettingsStore.submittedDraft(sunshineNameDraft) { commitSunshineName(value) }
                        }
                        .disabled(host.status != .connected || !configurationAvailable)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Name devices see")
                        Text("Empty uses this Mac’s name — currently “\(resolvedMacName)”.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Open Moonwalk Host at Login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { newValue in
                        if let error = loginItem.setEnabled(newValue) {
                            actionResultTitle = "Open at Login failed"
                            actionResultMessage = error
                        }
                    }
                ))
                if loginItem.requiresApproval {
                    Text("Open at Login is waiting for your approval in System Settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Open Login Items…") { loginItem.openLoginItems() }
                } else if loginItem.state == .unavailable {
                    Text("Open at Login is unavailable. Check that Moonwalk Host is installed in Applications.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                AdvancedDisclosure {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Detailed logging", isOn: detailedLoggingBinding)
                            .disabled(host.status != .connected || !configurationAvailable)
                        rowCaption("Records verbose logs to help diagnose problems. Turn on, reproduce the issue, then open the config folder for the log. Leave off for normal use.")
                    }

                    Button("Open Config Folder…") { openConfigFolder() }
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("About Moonwalk Host") {
            LabeledContent("App version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
            LabeledContent("App build", value: Bundle.main.object(forInfoDictionaryKey: "SkylightSourceRevision") as? String ?? "Unknown")
                .textSelection(.enabled)
            if host.status == .connected {
                LabeledContent("Host version", value: host.richStatus.appVersion.isEmpty ? "Unknown" : host.richStatus.appVersion)
                LabeledContent("Host build", value: host.richStatus.sourceRevision.isEmpty ? "Unknown" : host.richStatus.sourceRevision)
                    .textSelection(.enabled)
            }
            Link("View Releases…", destination: URL(string: "https://github.com/joaodriessen/moonwalk-host/releases")!)
            Text("Updates are optional. Review a release, download its signed DMG, then quit Moonwalk Host and replace the app in Applications. Your settings and paired devices stay on this Mac.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var supportSection: some View {
        Section {
            DisclosureGroup("Diagnostics and maintenance") {
                Button("Save Diagnostics…") { saveDiagnostics() }
                    .disabled(diagnosticsTask != nil)
                if diagnosticsTask != nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Saving diagnostics…")
                        Spacer()
                        Button("Cancel") { diagnosticsTask?.cancel() }
                    }
                }
                Button("Remove Background Service…") { showRemoveServiceConfirm = true }
                Button("Uninstall Moonwalk Host…", role: .destructive) { showUninstallConfirm = true }
            }
        } header: {
            Text("Support")
        } footer: {
            Text("Diagnostics stay on your Mac until you share them. Removing the service turns off Open at Login and keeps settings and paired devices; move Moonwalk Host to Trash separately. Uninstall does everything in one step, including moving Moonwalk Host to the Trash.")
        }
    }

    // MARK: - Read-outs

    private var reachabilityText: String {
        switch host.status {
        case .connecting: return "Starting Up…"
        case .connected: return "Host connected"
        case .offline: return "Not Running"
        case .untrusted: return "Can't Verify"
        }
    }

    private var sessionHeadline: String {
        guard host.status == .connected else { return "—" }
        guard host.richStatus.streaming else {
            return host.richStatus.resumable ? "Ready to resume · no device connected" : "Ready · no device connected"
        }
        return host.richStatus.clientName.isEmpty
            ? "In use"
            : "In use by \(host.richStatus.clientName)"
    }

    private var sessionDetail: String? {
        guard host.status == .connected, host.richStatus.streaming else { return nil }
        var parts: [String] = []
        if host.richStatus.sessionSeconds > 0 {
            parts.append(StatusLineFormatting.durationString(host.richStatus.sessionSeconds))
        }
        if host.richStatus.height > 0 {
            let fps = host.richStatus.fps > 0 ? "\(host.richStatus.fps)" : ""
            parts.append(StatusLineFormatting.resolutionBucket(host.richStatus.height) + fps)
        }
        if let codec = codecLabel() {
            parts.append(codec)
        }
        if host.richStatus.bitrateKbps > 0 {
            // Round to the nearest Mbps rather than truncating via integer division -- e.g.
            // 3500 kbps was previously reported as "3 Mbps" (3500 / 1000 == 3, Int division
            // truncates), silently dropping the fractional Mbps for anything not an exact
            // multiple of 1000.
            let mbps = (Double(host.richStatus.bitrateKbps) / 1000.0).rounded()
            parts.append("\(Int(mbps)) Mbps")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func codecLabel() -> String? {
        // The one shared codec-label FormatStyle (SkylightMenuCore) — same recognized set as the
        // menu status line, so the two surfaces can never disagree.
        host.richStatus.encoder.formatted(.codecLabel)
    }

    @ViewBuilder
    private func permissionValue(_ state: PermissionGrantState) -> some View {
        if state == .granted {
            Text("Granted")
                .foregroundStyle(.green)
        } else if state == .checking {
            Text("Checking…")
                .foregroundStyle(.secondary)
        } else {
            Text("Not Granted")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func requestRestart() {
        if RestartCoordinator.requiresConfirmation(streaming: host.richStatus.streaming) {
            showRestartConfirm = true
        } else {
            performRestart()
        }
    }

    private func performRestart() {
        HostProcessActions.restartAfterSaving(host.settings) { result in
            if result.success { restart.clear() }
            actionResultTitle = result.success ? "Restart requested" : "Restart failed"
            actionResultMessage = result.success
                ? "Moonwalk Host is relaunching. Check the picture again after it reconnects."
                : (result.output.isEmpty ? "Unknown error." : result.output)
        }
    }

    /// The generic config-key write for `sunshine_name`, same funnel shape as `SettingsView`'s
    /// `setString` (arms `restart.markPersistedChange` on success) — kept local since this pane
    /// only ever writes this one draft-backed key, unlike `SettingsView`'s multi-key funnel.
    private func refreshStatus() {
        loginItem.refresh()
        Task { _ = await host.fetchPermissionState() }
    }

    private func commitSunshineName(_ value: String) {
        guard host.settings.conflicts["sunshine_name"] == nil else { return }
        host.setConfigValue("sunshine_name", value: value) { success, message in
            if success {
                if SettingsStore.shouldClearDraft(current: sunshineNameDraft, submitted: value) { sunshineNameDraft = nil }
                restart.markPersistedChange(key: "sunshine_name")
            }
        }
    }

    private func setDetailedLogging(_ verbose: Bool) {
        host.setConfigValue("min_log_level", value: verbose ? "0" : "2") { success, message in
            if success {
                restart.markPersistedChange(key: "min_log_level")
            }
        }
    }

    private func openConfigFolder() {
        let path = SkylightDataPaths.configuration(home: FileManager.default.homeDirectoryForCurrentUser).path
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func saveDiagnostics() {
        guard diagnosticsTask == nil else { return }
        diagnosticsTask = Task {
            defer { diagnosticsTask = nil }
            guard let destination = await DiagnosticsExporter.chooseDestination(), !Task.isCancelled else { return }
            do {
                let url = try await DiagnosticsExporter.save(
                    to: destination,
                    settingNames: Array(host.configValues.keys),
                    session: host.richStatus,
                    service: HostServiceManager().status,
                    permissions: host.permissionState
                )
                actionResultTitle = "Diagnostics saved"
                actionResultMessage = url.path
            } catch is CancellationError {
                // Cancel is an ordinary exit; worker cleanup completes before it returns.
            } catch {
                actionResultTitle = "Couldn’t save diagnostics"
                actionResultMessage = error.localizedDescription
            }
        }
    }

    /// The keep-data path ("Remove Background Service"). Unregisters the service only; settings
    /// and paired devices stay on disk, and the app itself is not touched -- the user moves it to
    /// Trash on their own schedule, same as before this change.
    private func removeBackgroundService() {
        defer { loginItem.refresh() }
        do {
            try UninstallCoordinator.removeService(deleteData: false)
            actionResultTitle = "Background service removed"
            actionResultMessage = "Open at Login is off. Move Moonwalk Host to Trash when you’re ready."
        } catch {
            actionResultTitle = "Couldn’t remove Moonwalk Host"
            actionResultMessage = error.localizedDescription
        }
    }

    /// The one-click uninstall path. Unregisters the service, deletes settings/paired-device data,
    /// and moves the app bundle to the Trash (`UninstallCoordinator.uninstall()` -- see that type
    /// for why the ordering is fixed). The trash step can come back `.skipped`/`.failed` (unusual
    /// install location, permission denied) without the uninstall itself having failed -- data
    /// removal already happened -- so this only changes which success copy is shown, and still
    /// quits the app either way via the existing `quitAfterDeleteData()` path (latch + final
    /// domain wipe unchanged).
    private func uninstallSkylight() {
        defer { loginItem.refresh() }
        do {
            let outcome = try UninstallCoordinator.uninstall()
            switch outcome {
            case .trashed:
                actionResultTitle = "Moonwalk Host uninstalled"
                actionResultMessage = "Moonwalk Host was uninstalled. It is now in the Trash."
            case .skipped, .failed:
                actionResultTitle = "Moonwalk Host data deleted"
                actionResultMessage = "Moonwalk Host will now quit. Drag it to the Trash to finish."
            }
            quitAfterDeleteData()
        } catch {
            actionResultTitle = "Couldn’t remove Moonwalk Host"
            actionResultMessage = error.localizedDescription
        }
    }

    /// I2 fix: a delete-data uninstall must not leave the app running to silently undo itself.
    /// Left running, the very next menu open would otherwise re-seed everything just removed --
    /// `MenuContent.onAppear` unconditionally calls `firstRun.refresh(...)`, and
    /// `FirstRunCoordinator` (via `FirstRunState.reduce`) sees the now-missing config/service and
    /// returns `[.createDefaultConfiguration, .registerService]`. Quitting closes that reentry
    /// window entirely by not being a running process anymore -- scoped strictly to the
    /// delete-data path, since deleting data is what leaves the app in a state
    /// (`.notRegistered`/no config) that first-run convergence reacts to.
    ///
    /// I4/M6 correction: the plain "Remove Background Service" path (`deleteData: false`, no
    /// quit) is not re-seed-*proof* by virtue of leaving config/state intact -- unregistering the
    /// service alone puts `FirstRunEnvironment.service` at `.notRegistered`, which is exactly the
    /// condition `FirstRunState.evaluate` maps to `[.registerService]`. What actually stops the
    /// re-registration on that path now is `UninstallCoordinator.didRemoveService`, a latch set
    /// at the top of `removeService(deleteData:)` that `FirstRunCoordinator.refresh`/`perform`
    /// check before running any convergence effect (see those types). The app deliberately keeps
    /// running after a plain removal so the user can quit/trash it on their own schedule, same as
    /// before -- it just no longer silently undoes its own action while it does.
    ///
    /// Same shape as `MenuContent`'s "Quit Skylight" (`Task { ... NSApplication.shared.terminate
    /// }`). The short delay only exists so the alert copy above is legible before the menu bar
    /// item disappears -- `UninstallCoordinator.removePersistentDomain()` runs a second time
    /// immediately before `terminate(nil)`, as late as possible, as a final safety net against
    /// anything that could repopulate the domain in the gap since the first removal inside
    /// `removeService(deleteData:)`, up until that second call itself runs (see that type's doc
    /// comment for the M7 correction on what this second call does and doesn't guard against --
    /// it is not a guard against AppKit's window-frame write during `terminate(nil)`, which runs
    /// after this).
    private func quitAfterDeleteData() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            UninstallCoordinator.removePersistentDomain()
            NSApplication.shared.terminate(nil)
        }
    }
}
