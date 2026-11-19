import Foundation
import Observation
import SkylightMenuCore

/// S1 connection lifecycle to the sunshine daemon over XPC. Reachability/trust is tracked
/// here separately from the actual control VALUES (see the `@Observable`-tracked properties
/// below) -- once `status == .connected`, those values are considered live; before that they
/// hold their startup defaults and every control in ContentView disables itself off
/// `isConnected`.
enum HostStatus: Equatable {
    case connecting
    case connected
    /// The Mach service isn't reachable (daemon not running, or launchd hasn't vended it).
    case offline
    /// Now UNREACHABLE: peer code-signature mismatch is enforced by the OS
    /// (setCodeSigningRequirement) and surfaces as `.offline`, not a distinguishable trust
    /// failure. The case is retained (menuPhase/reachabilityText still map it) so a future
    /// distinguishable-trust signal has a home, but nothing sets it today.
    case untrusted
}

extension HostStatus {
    var firstRunAvailability: FirstRunEnvironment.HostAvailability {
        switch self {
        case .connecting: .connecting
        case .connected: .connected
        case .offline, .untrusted: .offline
        }
    }
}

/// Mirrors the host's `richStatus` XPC reply (src/platform/macos/xpc_control.mm). Fields the
/// host could not cheaply/honestly determine in-process arrive as documented sentinels
/// (empty string / 0) rather than fabricated values -- see the host-side `richStatusWithReply:`
/// comment for what each sentinel is waiting on and why.
struct RichStatus: Equatable {
    var appVersion = ""
    var sourceRevision = ""
    var streaming = false
    var resumable = false
    var clientName = ""
    var clientUUID = ""
    var sessionId = 0
    var width = 0
    var height = 0
    var fps = 0
    var encoder = ""
    var bitrateKbps = 0
    var sessionSeconds = 0
    /// Workstream D: true while at least one device is waiting for its pairing PIN to be
    /// entered. The host prunes stale (>5 min) requests before reporting this, so it never
    /// sticks past the pairing-session TTL. Drives the menubar badge + notification below.
    var pendingPairing = false
}

struct PermissionState: Equatable {
    var screenRecording: PermissionGrantState = .checking
    var accessibility: PermissionGrantState = .checking
}

struct ConfigPayload: Sendable {
    let schemaJSON: String
    let valuesJSON: String
    let startedAtRevision: Int
    let connectionGeneration: Int
}

struct PermissionSnapshot: Sendable {
    let generation: Int
    let state: PermissionState
}

// `PendingPairing` moved to `SkylightMenuCore` (design-pairing-statemachine.md §1, mechanical --
// pure Codable value data, no behavior change) so `PairingState`/`PairingReducer` can reference it
// without depending on this executable target. See SkylightMenuCore/PendingPairing.swift.

/// Connects to the configured XPC service after validating the daemon's signing identity.
@MainActor
@Observable
final class HostConnection {
    private(set) var status: HostStatus = .connecting
    private(set) var richStatus = RichStatus()

    private(set) var virtualDisplay = false
    private(set) var quitOnDisconnect = false

    // The compact Video group. Defaults below are display-only placeholders shown briefly
    // before the first successful fetch overwrites them with the real config values.
    // 30, not 60 -- this is a placeholder shown briefly before the first fetch overwrites it,
    // and 30 is the documented safe value for `minimum_fps_target` (src/video.cpp:2010-2020,
    // ContentView's "Keepalive FPS floor" control); a 60 placeholder would momentarily display
    // the exact judder-inducing value this UI now steers users away from.
    private(set) var fpsTarget = 30
    private(set) var encoder = "videotoolbox"

    // S2 schema-driven long-tail state (docs/design/menubar-app.md "S2"). Fetched on demand
    // when the Settings window opens, not on every popover `connect()` -- 88 options is more
    // than the popover's daily-glance surface needs to pay for on every menubar click.
    private(set) var configSchema: ConfigSchema?
    let settings = SettingsStore()
    var configValues: [String: String] { settings.values }
    var advertisedName: String {
        let configured = configValues["sunshine_name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? (Host.current().localizedName ?? "This Mac") : configured
    }
    /// True once a fetch has completed and the schema came back empty/unparseable -- lets
    /// SettingsView show a graceful "schema unavailable" state instead of an infinite spinner.
    private(set) var configSchemaUnavailable = false
    private(set) var connectionInfo: HostConnectionInfo?
    private(set) var snapshotKeys: Set<String> = []
    private(set) var externalRefreshError: String?
    var startupError: String?
    private(set) var repairingService = false
    private(set) var repairMessage: String?
    private var externalFingerprint = ""
    private var refreshingExternal = false

    // S3 permission onboarding (docs/design/menubar-app.md "S3"). Fetched on demand (onboarding
    // window appears / regains focus), not on every popover connect -- same rationale as the
    // S2 schema fetch above.
    private(set) var permissionState = PermissionState()

    // Workstream C (Skylight ONE redesign): the paired-clients list for Settings > Devices.
    // Fetched on demand (Settings window appears / after any unpair), not on every popover
    // connect -- same rationale as the S2 schema fetch above.
    private(set) var pairedClients = RemoteList<PairedClient>()
    var paired: [PairedClient] { pairedClients.values }
    private var pairedRequest = 0

    private var connection: NSXPCConnection?
    /// S3: periodic richStatus poll while connected, so a streaming-state TRANSITION can be
    /// detected for the local-notification feature (docs/design/menubar-app.md "S3
    /// notifications" -- "derived from the existing status poll"). Neither S0 nor S1/S2 had any
    /// periodic polling; this timer is new. Deliberately not invalidated in a `deinit` -- this
    /// object is the app's single process-lifetime `@State` root, never deallocated before the
    /// app itself exits (matching the "daemon-lifetime singleton" leak-by-design pattern the
    /// host's own xpc_control.mm documents for its listener).
    private var pollTimer: Timer?
    /// Retry timer that reconnects after the daemon drops (restart / quit-on-disconnect); nil
    /// while connected. See scheduleReconnect().
    private var reconnectTimer: Timer?
    /// Daemon lifecycle coupling (docs/design/2026-07-19-daemon-lifecycle-coupling.md §2C):
    /// dedicated ~2s ping that refreshes the host's `last_validated_contact`, separate from
    /// `pollTimer`'s 5s `richStatus` cadence (the daemon's `NoteValidatedContact()` now refreshes
    /// from BOTH calls -- two independent cadences, post-judge-review P1.3). `tolerance = 0` is
    /// set on this timer (see `startHeartbeat()`) specifically so it is NOT coalesced -- combined
    /// with the App Nap prevention token (`appNapActivityToken`) held while connected, this is
    /// the root fix for a judge-caught false-kill: without both, this timer could drift under App
    /// Nap while the menu sits idle in the background during an active stream, past the daemon's
    /// presence-window backstop, killing a healthy daemon. Not invalidated in `deinit` for the
    /// same reason `pollTimer` isn't (see that property's doc comment).
    private var heartbeatTimer: Timer?
    /// Set true only after the first `ping` round-trips on a live connection. Every proxy send
    /// is gated on this so a write can never reach a not-yet-confirmed connection (e.g. if the
    /// user toggles before the first ping completes). The peer's code signature is guaranteed by
    /// the OS (setCodeSigningRequirement) — this flag is now purely a liveness gate, not a trust
    /// check. Reset whenever we (re)connect or lose the peer.
    private var peerValidated = false
    private(set) var connectionGeneration = 0
    private var pendingReplies: [UUID: () -> Void] = [:]
    private var permissionRefresh: (generation: Int, id: UUID, task: Task<PermissionSnapshot?, Never>)?
    private var captureDisplaysRequest = 0
    private(set) var captureDisplays: [CaptureDisplay] = []
    private(set) var captureDisplaysAvailable = false

    /// App Nap prevention token (docs/design/2026-07-19-daemon-lifecycle-coupling.md P1.1,
    /// post-judge-review). Held for as long as `status == .connected`; nil otherwise. This app is
    /// an `LSUIElement` background menu-bar app with no other App Nap defense -- while idle in
    /// the background during an active stream (the canonical App Nap / timer-coalescing target),
    /// `heartbeatTimer`'s 2s cadence could drift past the daemon's presence-window backstop,
    /// which would then kill a healthy, actively-streaming daemon even though the menu itself is
    /// still alive. `.userInitiatedAllowingIdleSystemSleep` specifically prevents App Nap WITHOUT
    /// preventing the Mac from sleeping when genuinely idle -- this must never become a
    /// caffeinate-style "keep the Mac awake" assertion just because the menu happens to be
    /// connected. Managed exclusively by `setStatus(_:)` below so begin/end always balance
    /// regardless of which of the several call sites (interruption, invalidation, refresh, a
    /// proxy error) drives the `.connected` <-> other transition.
    private var appNapActivityToken: NSObjectProtocol?

    // The build generates both peer requirements from the bundle identifiers and signer.
    private static let hostRequirementString = GeneratedIdentity.hostPeerRequirement

    /// The ONE place `status` is ever mutated (P1.1, post-judge-review) -- every direct
    /// `status = ...` assignment below was replaced with a call to this, so the App Nap
    /// activity token (`appNapActivityToken`) always begins exactly once on entering
    /// `.connected` and ends exactly once on leaving it, no matter which call site (interruption,
    /// invalidation, `refresh()`, a proxy error) drives the transition. A no-op transition
    /// (`newStatus == status`) touches neither `status` nor the token.
    private func setStatus(_ newStatus: HostStatus) {
        guard newStatus != status else { return }
        let wasConnected = status == .connected
        status = newStatus
        if status != .connected {
            connectionInfo = nil
            peerValidated = false
            if status == .offline || status == .untrusted { connectionGeneration += 1 }
            pairedClients.receive(nil)
            let cancel = Array(pendingReplies.values)
            pendingReplies.removeAll()
            cancel.forEach { $0() }
            permissionRefresh?.task.cancel()
            permissionRefresh = nil
        }
        if status == .connected, !wasConnected {
            appNapActivityToken = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "keeping the host heartbeat responsive while connected"
            )
        } else if status != .connected, wasConnected, let token = appNapActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            appNapActivityToken = nil
        }
    }

    /// Connect at construction by default. The production app opts out once: AppDelegate owns
    /// the process-lifetime connection and starts it immediately after service-registration
    /// migration. That still guarantees a launch-time connection rather than relying on a
    /// `.menu`-style MenuBarExtra's unreliable `onAppear`; tests and other callers retain the
    /// convenient eager default. MenuContent's `onAppear` connect() stays as a cheap retry.
    init(connectImmediately: Bool = true) {
        if connectImmediately { connect() }
    }

    func connect() {
        // Reopening the menu should keep a validated connection and its pending replies.
        guard !(status == .connected && connection != nil) else {
            SkylightLog.lifecycle.info("connect() called while already connected -- skipping redundant reconnect")
            return
        }

        SkylightLog.lifecycle.info("connecting to host XPC service")
        setStatus(.connecting)
        peerValidated = false

        // Explicitly invalidate any prior connection before replacing it, rather than just
        // dropping the reference -- Apple's guidance is that it's only safe to drop an
        // NSXPCConnection without invalidating if you're certain it's already invalid/will
        // remain so, which isn't guaranteed here (this path runs on retries/reconnects where
        // the old connection could still be technically live). Clear its handlers first so
        // the intentional teardown below doesn't bounce back through
        // interruptionHandler/invalidationHandler and race this same reconnect (e.g.
        // re-triggering scheduleReconnect for a connect we're already replacing).
        if let old = connection {
            old.interruptionHandler = nil
            old.invalidationHandler = nil
            old.invalidate()
        }

        let conn = NSXPCConnection(machServiceName: SkylightXPC.machServiceName, options: [])
        connectionGeneration += 1
        let generation = connectionGeneration
        conn.remoteObjectInterface = NSXPCInterface(with: SkylightControl.self)

        // Pin the daemon's designated requirement at the OS layer (macOS 13+, DTS-blessed): a
        // daemon whose code signature doesn't match is rejected by libxpc, surfacing via the
        // interruption/invalidation handlers below (→ .offline). Replaces the old manual
        // SecCode-by-pid validatePeer() check and closes its PID-reuse race. The string is a
        // proven-valid compile-time constant (a malformed one would trap, per the API contract).
        conn.setCodeSigningRequirement(Self.hostRequirementString)

        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.connectionGeneration else { return }
                SkylightLog.lifecycle.info("XPC connection interrupted -- marking offline")
                self.setStatus(.offline)
                self.scheduleReconnect()
            }
        }
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.connectionGeneration else { return }
                SkylightLog.lifecycle.info("XPC connection invalidated -- marking offline")
                self.setStatus(.offline)
                self.scheduleReconnect()
            }
        }

        conn.resume()
        connection = conn

        refresh()
        startPolling()
        startHeartbeat()
    }

    /// The daemon restarts routinely — on deploy, and on `quit_app_on_disconnect` after a
    /// session ends — which drops this XPC connection. Without this, the menu would sit at
    /// "Not Running" until the user relaunched the app (a `.menu`-style MenuBarExtra's content
    /// onAppear doesn't reliably fire to trigger the retry). Retry `connect()` on a modest fixed
    /// cadence while offline; the timer stops itself the moment a connection succeeds.
    ///
    /// `tolerance = 0` (P1-residual mitigation, post-judge-review): the App Nap activity token
    /// (`appNapActivityToken`) is released the instant `status` leaves `.connected`, so THIS
    /// timer -- the one that re-establishes the connection -- runs with no App Nap defense of
    /// its own during a transient control-channel drop mid-stream. Without a tolerance pin, a
    /// coalesced/delayed reconnect attempt could in principle drift past the daemon's
    /// presence-window backstop and false-kill an otherwise-healthy, actively-streaming daemon
    /// (the menu is alive, just slow to retry). Cheap, minimal fix for now -- the fuller "hold
    /// the token across the reconnect window too" is deferred to a live App-Nap soak, not done
    /// here.
    private func scheduleReconnect() {
        guard reconnectTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.status == .connected {
                    self.stopReconnect()
                } else {
                    SkylightLog.lifecycle.info("reconnect attempt")
                    self.connect()
                }
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        reconnectTimer = timer
    }

    private func stopReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    /// S3: re-fetch `richStatus` every few seconds while connected so a streaming-state
    /// transition (idle -> streaming, or a different client while already streaming) can drive
    /// the local-notification feature. Cheap -- one small XPC round trip -- and a no-op via the
    /// `status == .connected` guard whenever the host is offline/untrusted/still connecting.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.status == .connected else { return }
                if let rs = await self.fetchRichStatus() {
                    self.richStatus = rs
                }
                await self.refreshExternalConfiguration()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Daemon lifecycle coupling (§2C): dedicated ~2s ping that refreshes the host's
    /// `last_validated_contact`, so its presence-window self-check backstop never mistakes an
    /// ordinary connected menu for a detached one. A no-op via the `status == .connected` guard
    /// whenever offline/untrusted/still connecting, same as `startPolling()`.
    ///
    /// `tolerance = 0` (post-judge-review, P1.1) is load-bearing, not cosmetic: `Timer`'s default
    /// tolerance lets the system coalesce/delay firings for power efficiency, which is exactly
    /// the kind of drift App Nap would otherwise compound on this background `LSUIElement` app --
    /// see `heartbeatTimer`'s doc comment for the failure this (combined with
    /// `appNapActivityToken`) fixes.
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.status == .connected else { return }
                _ = await self.menuHeartbeatXPC()
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func menuHeartbeatXPC() async -> Bool {
        await withXPC(requireValidated: true, fallback: false) { proxy, reply in
            proxy.menuHeartbeat(withReply: { reply(true) })
        }
    }

    /// Re-validate the peer (via `ping`) and, once trusted, fetch every S1 control value.
    func refresh() {
        guard connection != nil else { return }
        let generation = connectionGeneration
        Task { @MainActor in
            let alive = await self.ping()
            guard generation == self.connectionGeneration else { return }
            guard alive else {
                self.setStatus(.offline)
                self.scheduleReconnect()
                return
            }

            // The daemon's code signature is enforced by the OS via setCodeSigningRequirement
            // (see connect()): a non-matching daemon never gets this far — it's rejected by
            // libxpc and surfaces through the proxy error / invalidation handlers as .offline.
            // So a successful ping reply means the peer is both live AND (OS-guaranteed) the
            // pinned daemon; no manual check needed.
            self.peerValidated = true
            self.setStatus(.connected)
            self.stopReconnect()
            SkylightLog.lifecycle.info("connected, peer requirement enforced by OS")
            self.fetchAll()
            await self.refreshConnectionInfo()
            await self.refreshExternalConfiguration(force: true)
        }
    }

    /// Fetch every S1 published value in parallel. Only called once the peer is validated.
    private func fetchAll() {
        guard connection != nil, peerValidated else { return }
        Task { @MainActor in
            guard self.peerValidated else { return }

            let revision = self.settings.revision
            let generation = self.connectionGeneration
            async let richStatusResult = self.fetchRichStatus()
            async let virtualDisplayResult = self.getVirtualDisplayXPC()
            async let quitOnDisconnectResult = self.getQuitOnDisconnectXPC()
            async let fpsTargetResult = self.getFpsTargetXPC()
            async let encoderResult = self.getEncoderXPC()
            async let configResult = self.getConfigValuesXPC()

            let (rs, vd, qod, fps, enc, config) = await (richStatusResult, virtualDisplayResult, quitOnDisconnectResult, fpsTargetResult, encoderResult, configResult)
            guard generation == self.connectionGeneration, self.status == .connected else { return }
            if let config { _ = self.applyConfigValues(config, startedAt: revision) }
            if let rs { self.richStatus = rs }
            if let vd, self.settings.acceptsSnapshot(key: "virtual_display", startedAt: revision) { self.virtualDisplay = vd }
            if let qod, self.settings.acceptsSnapshot(key: "quit_app_on_disconnect", startedAt: revision) { self.quitOnDisconnect = qod }
            if let fps, self.settings.acceptsSnapshot(key: "minimum_fps_target", startedAt: revision) { self.fpsTarget = fps }
            if let enc, self.settings.acceptsSnapshot(key: "encoder", startedAt: revision) { self.encoder = enc }
        }
    }

    // MARK: - Async XPC call plumbing

    /// Every XPC call has a real deadline and cancellation path. Old connections and late
    /// callbacks cannot publish results or take a replacement connection offline.
    private func withXPC<T: Sendable>(
        requireValidated: Bool,
        fallback: T,
        timeout: TimeInterval = 5,
        _ send: @escaping (SkylightControl, @escaping (T) -> Void) -> Void
    ) async -> T {
        guard let conn = connection, (!requireValidated || peerValidated) else { return fallback }
        let generation = connectionGeneration
        let request = UUID()
        let box = BoundedReply<T>()
        pendingReplies[request] = { box.resolve(fallback) }
        defer { pendingReplies[request] = nil }
        let result = await box.value(timeout: timeout, fallback: fallback, onTimeout: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.connectionGeneration else { return }
                self.setStatus(.offline)
                self.scheduleReconnect()
            }
        }) { finish in
            let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
                guard box.resolve(fallback) else { return }
                SkylightLog.xpc.error("XPC proxy error: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    guard let self, generation == self.connectionGeneration else { return }
                    self.setStatus(.offline)
                    self.scheduleReconnect()
                }
            } as? SkylightControl
            guard let proxy else { box.resolve(fallback); return }
            send(proxy, finish)
        }
        guard generation == connectionGeneration, connection === conn else { return fallback }
        return result
    }

    /// The cheap peer-validating handshake call. Deliberately `requireValidated: false` -- this
    /// IS the call that establishes `peerValidated`, so it must be reachable before that flag is
    /// true. Returns whether the round trip actually completed; the reply's payload itself was
    /// never used (see the original `ping(withReply: { _ in ... })`).
    private func ping() async -> Bool {
        await withXPC(requireValidated: false, fallback: false) { proxy, reply in
            proxy.ping(withReply: { _ in reply(true) })
        }
    }

    /// Parses the reply dict to `RichStatus` INSIDE the XPC reply closure (a plain, non-isolated
    /// computation touching no actor state) rather than returning the raw `[String: Any]` across
    /// the continuation -- `Any` isn't `Sendable`, and the whole point of `RichStatus` existing
    /// as a typed struct is that it IS (all-value-type, all-Sendable members).
    private func fetchRichStatus() async -> RichStatus? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.richStatus(withReply: { dict in reply(Self.parseRichStatus(dict)) })
        }
    }

    private static func parseRichStatus(_ dict: [String: Any]) -> RichStatus {
        RichStatus(
            appVersion: dict["appVersion"] as? String ?? "",
            sourceRevision: dict["sourceRevision"] as? String ?? "",
            streaming: (dict["streaming"] as? Bool) ?? false,
            resumable: (dict["resumable"] as? Bool) ?? false,
            clientName: (dict["clientName"] as? String) ?? "",
            clientUUID: (dict["clientUUID"] as? String) ?? "",
            sessionId: (dict["sessionId"] as? NSNumber)?.intValue ?? 0,
            width: (dict["width"] as? NSNumber)?.intValue ?? 0,
            height: (dict["height"] as? NSNumber)?.intValue ?? 0,
            fps: (dict["fps"] as? NSNumber)?.intValue ?? 0,
            encoder: (dict["encoder"] as? String) ?? "",
            bitrateKbps: (dict["bitrateKbps"] as? NSNumber)?.intValue ?? 0,
            sessionSeconds: (dict["sessionSeconds"] as? NSNumber)?.intValue ?? 0,
            pendingPairing: (dict["pendingPairing"] as? Bool) ?? false
        )
    }

    private func getVirtualDisplayXPC() async -> Bool? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.getVirtualDisplay(withReply: { reply($0) })
        }
    }

    private func getQuitOnDisconnectXPC() async -> Bool? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.getQuitOnDisconnect(withReply: { reply($0) })
        }
    }

    private func getFpsTargetXPC() async -> Int? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.getFpsTarget(withReply: { reply($0) })
        }
    }

    private func getEncoderXPC() async -> String? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.getEncoder(withReply: { reply($0) })
        }
    }

    // MARK: - S2: schema-driven long-tail Settings window

    private func getConfigSchemaXPC() async -> String? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.getConfigSchema(withReply: { reply($0) })
        }
    }

    private func getConfigValuesXPC() async -> String? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.getConfigValues(withReply: { reply($0) })
        }
    }

    /// Fetch the full `config_schema.json` + the live config value bag over XPC. Safe to call
    /// repeatedly (window reopen, manual refresh) -- always re-fetches both rather than trusting
    /// a stale cache, since `sunshine.conf` can change underneath the app (hand-edit, the web
    /// UI, a restart). No-op if the peer isn't validated yet; callers should gate on
    /// `status == .connected` (same as every other control) and retry after `refresh()`.
    @discardableResult
    func fetchConfigSchemaAndValues() async -> ConfigPayload? {
        let revision = settings.revision
        let generation = connectionGeneration
        async let schemaReply = getConfigSchemaXPC()
        async let valuesReply = getConfigValuesXPC()
        guard let schemaJSON = await schemaReply, let valuesJSON = await valuesReply else {
            return nil
        }
        return ConfigPayload(schemaJSON: schemaJSON, valuesJSON: valuesJSON, startedAtRevision: revision, connectionGeneration: generation)
    }

    func applyConfigPayload(_ payload: ConfigPayload) -> Bool {
        guard payload.connectionGeneration == connectionGeneration, status == .connected else { return false }
        let schemaLoaded = applyConfigSchema(payload.schemaJSON)
        let valuesLoaded = applyConfigValues(payload.valuesJSON, startedAt: payload.startedAtRevision)
        return schemaLoaded && valuesLoaded
    }

    @discardableResult
    private func applyConfigSchema(_ json: String) -> Bool {
        guard !json.isEmpty else {
            SkylightLog.xpc.error("getConfigSchema returned empty -- schema unavailable on this host")
            configSchema = nil
            configSchemaUnavailable = true
            return false
        }
        do {
            let data = Data(json.utf8)
            configSchema = try JSONDecoder().decode(ConfigSchema.self, from: data)
            configSchemaUnavailable = false
            return true
        } catch {
            SkylightLog.xpc.error("config_schema.json decode failed (\(json.count, privacy: .public) bytes): \(error.localizedDescription, privacy: .public)")
            configSchema = nil
            configSchemaUnavailable = true
            return false
        }
    }

    @discardableResult
    private func applyConfigValues(_ json: String, startedAt: Int) -> Bool {
        do {
            let data = Data(json.utf8)
            let values = try JSONDecoder().decode([String: String].self, from: data)
            settings.applySnapshot(values, startedAt: startedAt)
            return true
        } catch {
            // Config values (e.g. `sunshine_name`) can be personally identifying -- keep the
            // payload itself out of the log, only the fact and size of the decode failure.
            SkylightLog.xpc.error("getConfigValues decode failed (\(json.count, privacy: .public) bytes): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// All writes use one ordered queue so late replies and configuration reads cannot undo
    /// newer edits. Rejections remain visible and retain the exact failed request for Retry.
    func setConfigValue(_ key: String, value: String, completion: @escaping @MainActor (Bool, String) -> Void) {
        settings.save(key: key, value: value, label: Self.settingLabel(key), send: { [self] in
            guard connection != nil, peerValidated else {
                connect()
                return "Not connected to the streaming host. Wait for it to start, then retry."
            }
            guard let (success, message) = await setConfigValueXPC(key, value: value) else {
                return "Lost connection while saving. Reconnect, then retry."
            }
            return success ? nil : (message.isEmpty ? "Couldn’t save. Try again." : message)
        }, completion: completion)
    }

    private static func settingLabel(_ key: String) -> String {
        let labels = [
            "sunshine_name": "Name devices see", "min_log_level": "Detailed logging",
            "encoder": "Video engine", "minimum_fps_target": "Smooth motion",
            "virtual_display": "Virtual display", "quit_app_on_disconnect": "Quit on disconnect",
            "hevc_mode": "Video codec", "av1_mode": "Video codec", "vt_realtime": "Low-latency encoding",
            "sw_preset": "Software encoding speed", "stream_audio": "Stream this Mac’s sound",
            "audio_sink": "Sound source", "output_name": "Capture display", "keyboard": "Keyboard control",
            "mouse": "Mouse control", "clipboard_sync": "Clipboard sharing", "upnp": "Router setup",
            "wan_encryption_mode": "Internet encryption", "lan_encryption_mode": "Local network encryption",
            "port": "Base port", "web_ui_enabled": "Web configuration page",
            "origin_web_ui_allowed": "Web console access", "external_ip": "Public IP address",
            "address_family": "IPv6 connections"
        ]
        return labels[key] ?? "Setting"
    }

    private func setConfigValueXPC(_ key: String, value: String) async -> (Bool, String)? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.setConfigValue(key, value: value, reply: { success, errorMessage in
                reply((success, errorMessage))
            })
        }
    }

    // MARK: - S3: permission onboarding + native pairing

    /// Fetch the daemon's live TCC state over XPC. Safe to call repeatedly (onboarding window
    /// open, regained focus) -- always re-fetches rather than trusting a stale cache, since a
    /// grant can change underneath the daemon at any moment (the user just came back from
    /// System Settings). Returns false if the validated peer is not yet reachable so callers
    /// retain the honest `.checking` state and retry on connection changes.
    @discardableResult
    func fetchPermissionState() async -> PermissionSnapshot? {
        let generation = connectionGeneration
        if let refresh = permissionRefresh, refresh.generation == generation { return await refresh.task.value }
        let id = UUID()
        let task = Task { @MainActor [self] () -> PermissionSnapshot? in
            guard let dict = await getPermissionStateXPC(), generation == connectionGeneration,
                  status == .connected else { return nil }
            let state = PermissionState(
                screenRecording: dict["screenRecording"]?.boolValue == true ? .granted : .required,
                accessibility: dict["accessibility"]?.boolValue == true ? .granted : .required
            )
            permissionState = state
            return PermissionSnapshot(generation: generation, state: state)
        }
        permissionRefresh = (generation, id, task)
        let result = await task.value
        if permissionRefresh?.id == id { permissionRefresh = nil }
        return result
    }

    func refreshCaptureDisplays() async {
        captureDisplaysRequest += 1
        let request = captureDisplaysRequest
        let generation = connectionGeneration
        let json: String? = await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.getCaptureDisplays(withReply: { reply($0) })
        }
        guard request == captureDisplaysRequest, generation == connectionGeneration, status == .connected else { return }
        if let json, let data = json.data(using: .utf8), let displays = try? JSONDecoder().decode([CaptureDisplay].self, from: data) {
            captureDisplays = displays
            captureDisplaysAvailable = !displays.isEmpty
        } else { captureDisplays = []; captureDisplaysAvailable = false }
    }

    func setCodecPolicy(_ codec: VideoCodec, completion: @escaping @MainActor (Bool, String) -> Void) {
        let pair = codec.rawPair
        settings.save(values: ["hevc_mode": pair.hevcMode, "av1_mode": pair.av1Mode],
                      operationKey: "video_codec", label: "Video codec", send: { [self] in
            guard connection != nil, peerValidated else { return "Not connected. Reconnect, then retry." }
            let result: (Bool, String)? = await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
                proxy.setCodecPolicy(pair.hevcMode, av1Mode: pair.av1Mode, reply: { reply(($0, $1)) })
            }
            guard let (success, message) = result else { return "Lost connection while saving. Reconnect, then retry the complete codec choice." }
            return success ? nil : (message.isEmpty ? "Couldn’t save the codec choice. Retry." : message)
        }, completion: completion)
    }

    func markPermissionsChecking() {
        permissionState = PermissionState()
    }

    private func getPermissionStateXPC() async -> [String: NSNumber]? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.getPermissionState(withReply: { dict in reply(dict) })
        }
    }

    func requestScreenRecording() async -> Bool {
        await withXPC(requireValidated: true, fallback: false) { proxy, reply in
            proxy.requestScreenRecording(withReply: { reply($0) })
        }
    }

    func requestAccessibility() async -> Bool {
        await withXPC(requireValidated: true, fallback: false) { proxy, reply in
            proxy.requestAccessibility(withReply: { reply($0) })
        }
    }

    /// S3 pairing-DoS/hijack fix, Layer A: arm the owner-initiated pairing eligibility window on
    /// the host. `PairingSheet.swift` calls this from its `.onAppear` -- opening the pairing
    /// sheet IS the owner-gated "arm" signal (mirrors `confighttp.cpp`'s authenticated
    /// `getPinPage` GET for the web flow). No-op if the peer isn't validated yet; the sheet's
    /// blind PIN form still works in that case (it just won't have been armed, so the host's
    /// `pin()` will correctly refuse until a window IS armed -- fail-closed, not fail-open).
    func beginPairingWindow() {
        guard connection != nil, peerValidated else { return }
        Task { @MainActor in
            _ = await self.beginPairingWindowXPC()
        }
    }

    /// Returns whether the round trip completed -- mirrors `ping()`'s "no meaningful payload,
    /// just confirm it happened" pattern above, rather than plumbing an unused `Void` through
    /// `withXPC`'s generic result type.
    private func beginPairingWindowXPC() async -> Bool {
        await withXPC(requireValidated: true, fallback: false) { proxy, reply in
            proxy.beginPairingWindow(withReply: { reply(true) })
        }
    }

    /// Fetch eligible pairing sessions. Nil means the service/data is unavailable; only a
    /// real empty array means no device is currently asking to pair.
    func fetchPendingPairings(completion: @escaping ([PendingPairing]?) -> Void) {
        guard connection != nil, peerValidated else {
            completion(nil)
            return
        }
        let generation = connectionGeneration
        Task { @MainActor in
            guard let json = await self.pendingPairingsXPC(), !json.isEmpty else {
                completion(nil)
                return
            }
            guard generation == connectionGeneration, status == .connected else { completion(nil); return }
            do {
                let data = Data(json.utf8)
                completion(try JSONDecoder().decode([PendingPairing].self, from: data))
            } catch {
                SkylightLog.xpc.error("pendingPairings decode failed (\(json.count, privacy: .public) bytes): \(error.localizedDescription, privacy: .public)")
                completion(nil)
            }
        }
    }

    private func pendingPairingsXPC() async -> String? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.pendingPairings(withReply: { json in reply(json) })
        }
    }

    enum PairOutcomeReply: Sendable {
        case waiting, complete(Bool), unavailable
    }

    /// Nil outcome is "not decided yet" only when the host actually answered.
    func fetchPairOutcome(forUniqueid uniqueid: String, completion: @escaping (PairOutcomeReply) -> Void) {
        let generation = connectionGeneration
        Task { @MainActor in
            let result = await self.pairOutcomeXPC(uniqueid)
            guard generation == connectionGeneration, status == .connected else { completion(.unavailable); return }
            completion(result)
        }
    }

    private func pairOutcomeXPC(_ uniqueid: String) async -> PairOutcomeReply {
        await withXPC(requireValidated: true, fallback: .unavailable) { proxy, reply in
            proxy.pairOutcome(forUniqueid: uniqueid, withReply: { outcome in
                reply(outcome.map { .complete($0.boolValue) } ?? .waiting)
            })
        }
    }

    /// S3 native pairing sheet: submit a PIN + device name (+ optional owner-picked target) over
    /// XPC. `completion` receives `(success, message)` verbatim from the host -- `message` is
    /// always non-empty and human-readable for either outcome
    /// (src/platform/macos/xpc_control.mm's `pair:name:targetUniqueid:reply:`). Gates on
    /// `peerValidated` (and kicks a `refresh()` if not yet validated) since this call mutates host
    /// pairing state, matching every other XPC write in this file.
    /// - Parameter target: the `uniqueid` the owner explicitly picked from
    ///   `fetchPendingPairings`'s list, or `""` for the common 0/1-eligible one-click case. The
    ///   HOST re-validates eligibility for any non-empty target; this call does not (and cannot)
    ///   pre-authorize it by sending it.
    func pair(pin: String, name: String, target: String = "", completion: @escaping (Bool, String) -> Void) {
        guard connection != nil, peerValidated else {
            refresh()
            completion(false, "Not connected to host")
            return
        }
        Task { @MainActor in
            let (success, message) = await self.pairXPC(pin, name: name, target: target)
                ?? (false, "Lost connection to host mid-request")
            completion(success, message)
        }
    }

    private func pairXPC(_ pin: String, name: String, target: String) async -> (Bool, String)? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.pair(pin, name: name, targetUniqueid: target, reply: { success, message in reply((success, message)) })
        }
    }

    // MARK: - Workstream C: native paired-clients management

    /// Fetch the full paired-clients list over XPC. Safe to call repeatedly (Settings window
    /// reopen, after any unpair) -- always re-fetches rather than trusting a stale cache, since
    /// the list can change underneath the app (web unpair, a new pairing). No-op if the peer
    /// isn't validated yet, same as `fetchConfigSchemaAndValues`.
    func fetchPairedClients() {
        pairedRequest += 1
        let request = pairedRequest
        let generation = connectionGeneration
        fetchPairedClientsList { [self] clients in
            guard request == pairedRequest, generation == connectionGeneration, status == .connected else { return }
            pairedClients.receive(clients)
        }
    }

    private func getPairedClientsXPC() async -> String? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.getPairedClients(withReply: { json in reply(json) })
        }
    }

    /// Snapshot used by pairing verification as well as Devices. Nil means unavailable,
    /// preserving the distinction from a valid empty list and preventing false pairing growth.
    func fetchPairedClientsList(completion: @escaping ([PairedClient]?) -> Void) {
        guard connection != nil, peerValidated else {
            completion(nil)
            return
        }
        let generation = connectionGeneration
        Task { @MainActor in
            // Empty string is the documented "call failed" sentinel (a real empty list is "[]").
            guard let json = await self.getPairedClientsXPC(), !json.isEmpty else {
                completion(nil)
                return
            }
            guard generation == connectionGeneration, status == .connected else { completion(nil); return }
            do {
                let data = Data(json.utf8)
                completion(try JSONDecoder().decode([PairedClient].self, from: data))
            } catch {
                SkylightLog.xpc.error("getPairedClients decode failed (\(json.count, privacy: .public) bytes): \(error.localizedDescription, privacy: .public)")
                completion(nil)
            }
        }
    }

    /// Revoke one paired client by uuid. Re-fetches the list on success so the row disappears
    /// without the caller having to remember to do it. `completion` receives success verbatim.
    func unpair(uuid: String, completion: @escaping (Bool) -> Void) {
        guard connection != nil, peerValidated else {
            refresh()
            completion(false)
            return
        }
        Task { @MainActor in
            let success = await self.unpairClientXPC(uuid) ?? false
            if success { self.fetchPairedClients() }
            completion(success)
        }
    }

    private func unpairClientXPC(_ uuid: String) async -> Bool? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.unpairClient(uuid, reply: { success in reply(success) })
        }
    }

    /// Revoke every paired client. Host-side this also ends any active session (web parity --
    /// see the protocol doc comment); the caller's destructive confirm must name that. Re-fetches
    /// the list on success.
    func unpairAll(completion: @escaping (Bool) -> Void) {
        guard connection != nil, peerValidated else {
            refresh()
            completion(false)
            return
        }
        Task { @MainActor in
            let success = await self.unpairAllClientsXPC() ?? false
            if success { self.fetchPairedClients() }
            completion(success)
        }
    }

    private func unpairAllClientsXPC() async -> Bool? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.unpairAllClients(withReply: { success in reply(success) })
        }
    }

    // MARK: - Daemon lifecycle coupling (quit flow)

    func refreshConnectionInfo() async {
        let generation = connectionGeneration
        let json: String? = await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.getConnectionInfo(withReply: { reply($0) })
        }
        guard generation == connectionGeneration else { return }
        connectionInfo = json.flatMap { try? JSONDecoder().decode(HostConnectionInfo.self, from: Data($0.utf8)) }
    }

    func refreshExternalConfiguration(force: Bool = false) async {
        await refreshExternalConfiguration(force: force, connected: { self.status == .connected },
            readRevision: { [self] in
                await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
                    proxy.getConfigurationRevision(withReply: { reply($0) })
                }
            }, readState: { [self] in
                await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
                    proxy.getConfigurationState(withReply: { reply($0) })
                }
            })
    }

    /// The same refresh transaction with inert read seams for failure/retry tests.
    func refreshExternalConfiguration(force: Bool, connected: @MainActor () -> Bool,
                                      readRevision: @MainActor () async -> String?,
                                      readState: @MainActor () async -> String?) async {
        if refreshingExternal {
            guard force else { return }
            while refreshingExternal, connected(), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard !Task.isCancelled else { return }
        guard connected() else {
            externalRefreshError = "Couldn’t refresh settings. Reconnect and try again. Your edits have been kept."; return
        }
        refreshingExternal = true
        defer { refreshingExternal = false }
        let generation = connectionGeneration
        let fingerprint = await readRevision()
        guard generation == connectionGeneration else { return }
        guard let fingerprint, !fingerprint.isEmpty else {
            externalRefreshError = "Couldn’t refresh settings. Try again. Your edits have been kept."; return
        }
        guard force || externalRefreshError != nil || fingerprint != externalFingerprint else { return }
        let startedAt = settings.revision
        let json = await readState()
        guard generation == connectionGeneration else { return }
        guard let json,
              let snapshot = try? JSONDecoder().decode(ConfigurationState.self, from: Data(json.utf8)) else {
            externalRefreshError = "Couldn’t refresh settings. Your edits have been kept."; return
        }
        settings.applyExternalSnapshot(snapshot.values, running: snapshot.runningValues, revision: snapshot.revision, startedAt: startedAt)
        snapshotKeys = snapshot.snapshotKeys
        if settings.acceptsSnapshot(key: "encoder", startedAt: startedAt) { encoder = snapshot.values["encoder"] ?? "videotoolbox" }
        if settings.acceptsSnapshot(key: "virtual_display", startedAt: startedAt) { virtualDisplay = snapshot.runningValues["virtual_display"] == "enabled" }
        if settings.acceptsSnapshot(key: "quit_app_on_disconnect", startedAt: startedAt) { quitOnDisconnect = ConfigBool.isOn(snapshot.runningValues["quit_app_on_disconnect"], default: false) }
        if settings.acceptsSnapshot(key: "minimum_fps_target", startedAt: startedAt) { fpsTarget = Int(Double(snapshot.runningValues["minimum_fps_target"] ?? "0") ?? 0) }
        externalRefreshError = nil
        // A concurrent write makes this fingerprint stale; retry on the next poll.
        if startedAt == settings.revision { externalFingerprint = fingerprint }
        fetchPairedClients()
    }

    func restoreConfiguration(_ snapshot: ConfigurationSnapshot, expectedRevision: String) async -> String? {
        await settings.waitForPendingSaves()
        guard settings.drafts.isEmpty, settings.conflicts.isEmpty else { return "Finish or resolve your edits before restoring a setup." }
        guard let data = try? JSONEncoder().encode(snapshot.values), let json = String(data: data, encoding: .utf8) else { return "Couldn’t read the setup." }
        let result: String? = await withXPC(requireValidated: true, fallback: "Lost connection while restoring. Refresh to check the saved settings.") { proxy, reply in
            proxy.restoreConfiguration(json, expectedRevision: expectedRevision, reply: { success, message in reply(success ? nil : message) })
        }
        await refreshExternalConfiguration(force: true)
        return result
    }

    func resolveExternalConflict(key: String, useExternal: Bool) async {
        guard let conflict = settings.conflicts[key] else { return }
        let originalDraft = settings.drafts[key]
        await settings.waitForPendingSaves()
        await refreshExternalConfiguration(force: true)
        guard externalRefreshError == nil, settings.canResolve(conflict, originalDraft: originalDraft) else { return }
        let selected: String? = useExternal ? conflict.external : conflict.local
        guard let data = try? JSONEncoder().encode(selected), let json = String(data: data, encoding: .utf8) else { return }
        let expected = settings.fileRevision
        settings.save(key: key, value: selected ?? "", label: Self.settingLabel(key), send: { [self] in
            await withXPC(requireValidated: true, fallback: "Lost connection while resolving this setting.") { proxy, reply in
                proxy.resolveConfigurationValue(key, jsonValue: json, expectedRevision: expected, reply: { success, message in reply(success ? nil : message) })
            }
        }, completion: { [self] success, _ in
            if success {
                if useExternal {
                    let currentDraft = settings.drafts[key]
                    settings.useExternalValue(for: key)
                    if currentDraft != originalDraft { settings.drafts[key] = currentDraft }
                }
                else {
                    _ = settings.keepLocalValue(for: key)
                    if settings.drafts[key] == conflict.local { settings.drafts[key] = nil }
                }
            }
            Task { await self.refreshExternalConfiguration(force: true) }
        })
    }

    func endSession(sessionId: Int, deviceUUID: String) async -> Bool {
        let result = await withXPC(requireValidated: true, fallback: false) { proxy, reply in
            proxy.endSession(sessionId, deviceUUID: deviceUUID, reply: reply)
        }
        if let status = await fetchRichStatus() { richStatus = status }
        return result
    }

    func microphonePermission(request: Bool = false) async -> String {
        if request {
            _ = await withXPC(requireValidated: true, fallback: false, timeout: 120) { proxy, reply in
                proxy.requestMicrophonePermission(withReply: reply)
            }
        }
        return await withXPC(requireValidated: true, fallback: "unknown") { proxy, reply in proxy.getMicrophonePermission(withReply: reply) }
    }

    func testSound(source: String, token: String) async -> SoundTestResult? {
        let json: String? = await withXPC(requireValidated: true, fallback: nil, timeout: 20) { proxy, reply in
            proxy.testSound(source, token: token, reply: { reply($0) })
        }
        return json.flatMap { try? JSONDecoder().decode(SoundTestResult.self, from: Data($0.utf8)) }
    }

    func cancelSoundTest(token: String) async {
        _ = await withXPC(requireValidated: true, fallback: false) { proxy, reply in proxy.cancelSoundTest(token, reply: { reply(true) }) }
    }

    func repairHostService(
        prepare: (@MainActor () throws -> String?)? = nil,
        restart: @escaping @MainActor (@escaping @MainActor (HostProcessActions.ActionResult) -> Void) -> Void = HostProcessActions.restartHost
    ) async {
        guard !repairingService else { return }
        repairingService = true
        defer { repairingService = false }
        // Registration refresh can replace the host too: drain before either preparation or restart.
        await settings.waitForPendingSaves()
        let saveWarning = settings.failures.isEmpty ? "" : " Some settings could not be saved. Your edits have been kept; use Retry in Settings after the host reconnects."
        do {
            let message: String?
            if let prepare { message = try prepare() }
            else {
                let manager = HostServiceManager()
                message = try HostRepairPreparation.prepare(
                    installed: InstallationLocation.isInstalled(Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser),
                    executablePresent: FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent(GeneratedIdentity.hostExecutableRelativePath).path),
                    service: manager, refreshRegistered: { try manager.refreshRegistrationIfExecutableChanged() })
            }
            if let message { repairMessage = message + saveWarning; return }
        } catch { startupError = error.localizedDescription; repairMessage = "Couldn’t register the streaming host: \(error.localizedDescription)" + saveWarning; return }
        let before = connectionGeneration
        let result: HostProcessActions.ActionResult = await withCheckedContinuation { continuation in
            restart { continuation.resume(returning: $0) }
        }
        guard result.success else { repairMessage = (result.output.isEmpty ? "The host could not be started. The XPC cause is unknown." : result.output) + saveWarning; return }
        connect()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !Task.isCancelled {
            if status == .connected, connectionGeneration > before, !richStatus.appVersion.isEmpty {
                startupError = nil; repairMessage = "The streaming host reconnected successfully." + saveWarning; return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        repairMessage = "Registration was checked, but the streaming host did not reconnect. The XPC cause is unknown. Save Diagnostics for the startup logs." + saveWarning
    }

    /// Daemon lifecycle coupling (docs/design/2026-07-19-daemon-lifecycle-coupling.md §3 "Quit
    /// flow"): tell the host to shut itself down gracefully. `MenuContent`'s "Quit Skylight"
    /// awaits this BEFORE calling `NSApplication.shared.terminate(nil)`, in that order.
    /// Best-effort and bounded to ~1s -- if the daemon is unreachable (already dead, or the XPC
    /// round trip just hangs) this returns anyway rather than delaying the app's own quit; the
    /// daemon's independent NOTE_EXIT/presence-window self-check tears it down regardless of
    /// whether this call ever lands (§3 step 5, the documented backstop).
    func shutdownHost() async {
        guard connection != nil, peerValidated else { return }
        _ = await withXPC(requireValidated: true, fallback: false, timeout: 1) { proxy, reply in
            proxy.shutdownHost(withReply: { reply(true) })
        }
    }

    // MARK: - Dedicated live setters, using the same acknowledged-save/error contract

    private func saveLive(_ key: String, value: String,
                          send: @escaping @MainActor () async -> Bool?,
                          apply: @escaping @MainActor () -> Void,
                          completion: @escaping @MainActor (Bool, String) -> Void = { _, _ in }) {
        settings.save(key: key, value: value, label: Self.settingLabel(key), send: { [self] in
            guard connection != nil, peerValidated else {
                connect()
                return "Not connected to the streaming host. Wait for it to start, then retry."
            }
            guard let success = await send() else { return "Lost connection while saving. Reconnect, then retry." }
            return success ? nil : "The host couldn’t save this setting. Check available disk space and retry."
        }, completion: { success, message in
            if success { apply() }
            completion(success, message)
        })
    }

    func setVirtualDisplay(_ value: Bool) {
        saveLive("virtual_display", value: value ? "enabled" : "disabled",
                 send: { await self.setVirtualDisplayXPC(value) }, apply: { self.virtualDisplay = value })
    }

    private func setVirtualDisplayXPC(_ value: Bool) async -> Bool? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.setVirtualDisplay(value, reply: { success in reply(success) })
        }
    }

    func setQuitOnDisconnect(_ value: Bool) {
        saveLive("quit_app_on_disconnect", value: value ? "enabled" : "disabled",
                 send: { await self.setQuitOnDisconnectXPC(value) }, apply: { self.quitOnDisconnect = value })
    }

    private func setQuitOnDisconnectXPC(_ value: Bool) async -> Bool? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.setQuitOnDisconnect(value, reply: { success in reply(success) })
        }
    }

    func setFpsTarget(_ value: Int) {
        saveLive("minimum_fps_target", value: String(value),
                 send: { await self.setFpsTargetXPC(value) }, apply: { self.fpsTarget = value })
    }

    private func setFpsTargetXPC(_ value: Int) async -> Bool? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.setFpsTarget(value, reply: { success in reply(success) })
        }
    }

    func setEncoder(_ value: String, completion: @escaping @MainActor (Bool, String) -> Void = { _, _ in }) {
        saveLive("encoder", value: value,
                 send: { await self.setEncoderXPC(value) }, apply: { self.encoder = value }, completion: completion)
    }

    private func setEncoderXPC(_ value: String) async -> Bool? {
        await withXPC(requireValidated: true, fallback: nil) { proxy, reply in
            proxy.setEncoder(value, reply: { success in reply(success) })
        }
    }

}

extension HostConnection {
    var firstRunAvailability: FirstRunEnvironment.HostAvailability {
        status.firstRunAvailability
    }
}

extension HostStatus {
    /// Bridges to `SkylightMenuCore.MenuHostPhase` for `MenuStatusLine.text` -- a tiny mapping
    /// rather than making `MenuStatusLine` depend on this executable-target-only enum directly,
    /// so `SkylightMenuCore` stays free of any dependency on `HostConnection`.
    var menuPhase: MenuHostPhase {
        switch self {
        case .connecting: return .connecting
        case .connected: return .connected
        case .offline: return .offline
        case .untrusted: return .untrusted
        }
    }
}
