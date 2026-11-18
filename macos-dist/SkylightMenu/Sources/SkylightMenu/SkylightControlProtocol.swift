import Foundation

/// Swift mirror of the ObjC `SkylightControl` protocol vended by the host daemon
/// (src/platform/macos/xpc_control.mm). Selector names must match EXACTLY -- there is no
/// shared source of truth across the Swift/ObjC++ boundary, so a rename on one side without
/// the other silently breaks the XPC call at runtime (it fails, it doesn't refuse to compile).
///
///   ObjC selector                              Swift declaration below
///   pingWithReply:                             ping(withReply:)
///   getQuitOnDisconnectWithReply:               getQuitOnDisconnect(withReply:)
///   setQuitOnDisconnect:reply:                  setQuitOnDisconnect(_:reply:)
///   richStatusWithReply:                        richStatus(withReply:)
///   getVirtualDisplayWithReply:                 getVirtualDisplay(withReply:)
///   setVirtualDisplay:reply:                    setVirtualDisplay(_:reply:)
///   getFpsTargetWithReply:                      getFpsTarget(withReply:)
///   setFpsTarget:reply:                         setFpsTarget(_:reply:)
///   getEncoderWithReply:                        getEncoder(withReply:)
///   setEncoder:reply:                           setEncoder(_:reply:)
///   getConfigSchemaWithReply:                   getConfigSchema(withReply:)
///   getConfigValuesWithReply:                   getConfigValues(withReply:)
///   setConfigValue:value:reply:                 setConfigValue(_:value:reply:)
///   getPermissionStateWithReply:                 getPermissionState(withReply:)
///   beginPairingWindowWithReply:                 beginPairingWindow(withReply:)
///   pendingPairingsWithReply:                    pendingPairings(withReply:)
///   pairOutcomeForUniqueid:withReply:            pairOutcome(forUniqueid:withReply:)
///   pair:name:targetUniqueid:reply:             pair(_:name:targetUniqueid:reply:)
///   getPairedClientsWithReply:                  getPairedClients(withReply:)
///   unpairClient:reply:                         unpairClient(_:reply:)
///   unpairAllClientsWithReply:                  unpairAllClients(withReply:)
///   shutdownHostWithReply:                      shutdownHost(withReply:)
///   menuHeartbeatWithReply:                     menuHeartbeat(withReply:)
///
/// `max_bitrate`/`QualityPreset` were removed from this app entirely (owner decision, Skylight
/// ONE redesign): no selector, no schema-key binding anywhere in this target. The host's bitrate
/// ceiling is config-file-only now; Starlight (the client) is the sole quality surface.
@objc(SkylightControl)
protocol SkylightControl {
    func getConnectionInfo(withReply reply: @escaping (String) -> Void)
    func getConfigurationState(withReply reply: @escaping (String) -> Void)
    func getConfigurationRevision(withReply reply: @escaping (String) -> Void)
    func restoreConfiguration(_ json: String, expectedRevision: String, reply: @escaping (Bool, String) -> Void)
    func resolveConfigurationValue(_ key: String, jsonValue: String, expectedRevision: String, reply: @escaping (Bool, String) -> Void)
    func endSession(_ sessionId: Int, deviceUUID: String, reply: @escaping (Bool) -> Void)
    func getMicrophonePermission(withReply reply: @escaping (String) -> Void)
    func requestMicrophonePermission(withReply reply: @escaping (Bool) -> Void)
    func testSound(_ source: String, token: String, reply: @escaping (String) -> Void)
    func cancelSoundTest(_ token: String, reply: @escaping () -> Void)
    /// Live host status: `{ "streaming": Bool, "quitOnDisconnect": Bool }`. The cheap
    /// peer-validating handshake call -- see `richStatus` for the full S1 status feed.
    func ping(withReply reply: @escaping ([String: NSNumber]) -> Void)

    /// Current value of `config::sunshine.quit_app_on_disconnect`.
    func getQuitOnDisconnect(withReply reply: @escaping (Bool) -> Void)

    /// Persist a new value to sunshine.conf and update the live in-memory config.
    func setQuitOnDisconnect(_ value: Bool, reply: @escaping (Bool) -> Void)

    /// Everything the S1 popover's status card needs in one call. Some fields arrive as
    /// documented sentinels (empty string / 0) when the host cannot cheaply/honestly
    /// determine them in-process -- see the host-side `richStatusWithReply:` comment.
    /// Additive field for workstream D: `pendingPairing` (Bool) -- true while at least one
    /// pairing request is waiting for a PIN (host prunes stale requests before reporting this,
    /// so it never sticks past the pairing-session TTL). Rides this same 5s poll; no new
    /// selector.
    func richStatus(withReply reply: @escaping ([String: Any]) -> Void)

    /// Current value of `config::video.virtual_display`.
    func getVirtualDisplay(withReply reply: @escaping (Bool) -> Void)
    /// Persist a new `virtual_display` value to sunshine.conf.
    func setVirtualDisplay(_ value: Bool, reply: @escaping (Bool) -> Void)

    /// Current value of `config::video.minimum_fps_target`, truncated to an integer.
    func getFpsTarget(withReply reply: @escaping (Int) -> Void)
    /// Persist a new `minimum_fps_target` to sunshine.conf.
    func setFpsTarget(_ value: Int, reply: @escaping (Bool) -> Void)

    /// Current value of `config::video.encoder` ("videotoolbox" or "software").
    func getEncoder(withReply reply: @escaping (String) -> Void)
    /// Persist a new `encoder` to sunshine.conf. Host rejects anything but the two known values.
    func setEncoder(_ value: String, reply: @escaping (Bool) -> Void)

    /// The full `config_schema.json` contents (name/type/default/constraints/tab/platform/
    /// discrepancies metadata for all ~88 options), verbatim, for the S2 Settings window.
    /// Empty string means the schema is unavailable on this host.
    func getConfigSchema(withReply reply: @escaping (String) -> Void)

    /// ALL current config values, read from the live sunshine.conf, as a flat JSON object of
    /// `{key: stringValue}` -- the persisted truth the S2 Settings window edits.
    func getConfigValues(withReply reply: @escaping (String) -> Void)

    /// GENERIC validated setter for the S2 schema-driven long-tail options. The host rejects any
    /// `key` not present in config_schema.json and any `value` failing that option's declared
    /// type/constraints -- see src/platform/macos/xpc_control.mm's `SetConfigValueValidated` for
    /// the full contract. `errorMessage` is non-empty (and `success` is false) on rejection.
    func setConfigValue(_ key: String, value: String, reply: @escaping (Bool, String) -> Void)
    /// One atomic choice; success acknowledges both persisted modes.
    func setCodecPolicy(_ hevcMode: String, av1Mode: String, reply: @escaping (Bool, String) -> Void)
    /// Current physical capture displays, JSON [{id:string,name:string}].
    func getCaptureDisplays(withReply reply: @escaping (String) -> Void)

    /// S3 permission onboarding: the daemon's REAL, live TCC state as
    /// `{ "screenRecording": Bool, "accessibility": Bool }`. Both checks are read-only and
    /// cheap on the host side -- see src/platform/macos/xpc_control.mm's
    /// `getPermissionStateWithReply:` for exactly which signal each field reuses. TCC keys on
    /// the DAEMON's own bundle identity, not this app's.
    func getPermissionState(withReply reply: @escaping ([String: NSNumber]) -> Void)

    /// User-initiated macOS prompts. These are the only XPC methods allowed to invoke the
    /// prompting TCC APIs; startup and streaming preflight remain read-only.
    func requestScreenRecording(withReply reply: @escaping (Bool) -> Void)
    func requestAccessibility(withReply reply: @escaping (Bool) -> Void)

    /// S3 pairing-DoS/hijack fix, Layer A: arm the owner-initiated pairing eligibility window on
    /// the host -- thin caller of `nvhttp::arm_pairing_window()` (src/nvhttp.cpp). Call this from
    /// `PairingSheet.swift`'s `.onAppear`; the pairing window opening IS the owner-gated "arm"
    /// signal, mirroring `confighttp.cpp`'s authenticated `getPinPage` GET for the web flow. See
    /// src/platform/macos/xpc_control.mm's `beginPairingWindowWithReply:` for the full contract.
    func beginPairingWindow(withReply reply: @escaping () -> Void)

    /// S3 pairing-DoS/hijack fix, Layer B: the currently-ELIGIBLE pending pairing sessions, as a
    /// JSON array of `{"uniqueid": String, "source_ip": String, "age_sec": Int, "hostname_hint":
    /// String, "client_name": String}` -- the SAME shape `GET /api/pending-pairings` serves. A
    /// non-eligible phantom session never appears here (and can therefore never be selected
    /// either) -- see src/platform/macos/xpc_control.mm's `pendingPairingsWithReply:` /
    /// `nvhttp::list_pending_pair_sessions()` for the full contract. Empty string means the call
    /// failed (peer not validated, or the host errored); `"[]"` means zero sessions are eligible.
    /// `hostname_hint` is a best-effort, UNTRUSTED reverse-DNS label for `source_ip` (empty when
    /// unresolved/unavailable) -- `source_ip` remains the actual security-relevant identifier.
    /// `client_name` is the UNTRUSTED, attacker-controllable `devicename` the pairing CLIENT
    /// itself sent -- decoded by `PendingPairing.swift` and consumed ONLY as the pairing sheet's
    /// editable device-name-field default (`PairingReducer.swift`'s `.deviceSelected` case),
    /// never as part of this picker's identity labeling.
    func pendingPairings(withReply reply: @escaping (String) -> Void)

    /// Fast pairing outcome (owner-test-motivated fix -- kills the blind 30s wait on a wrong PIN):
    /// read-only observation of a terminal pairing decision the host has ALREADY made for
    /// `uniqueid`, via `nvhttp::take_pair_outcome()` -- src/nvhttp.cpp's `clientpairingsecret()`/
    /// `fail_pair()` record it the instant phase 4 completes; does NOT touch the crypto
    /// verification path at all. `NSNumber` wrapping `true`/`false` for a known outcome, or `nil`
    /// when nothing terminal has happened yet (no outcome recorded, an unknown uniqueid, or one
    /// already consumed by an earlier call -- see the host implementation's doc comment; all
    /// three collapse to the same "keep waiting" meaning). SINGLE-CONSUMPTION: a non-nil reply
    /// also ERASES the outcome host-side -- call this at most once per `uniqueid` per pairing
    /// attempt. `PairingSheet.swift` polls this on the SAME tick as its existing set-growth poll
    /// (`fetchPairedClientsList`), not a second timer -- `nil` is handled identically to today's
    /// silence, so this is purely additive.
    func pairOutcome(forUniqueid uniqueid: String, withReply reply: @escaping (NSNumber?) -> Void)

    /// S3 native pairing sheet: drive the SAME pairing path the web UI's `POST /api/pin` uses.
    /// The host rejects any `pin` that isn't exactly 4 numeric digits without touching pairing
    /// state -- see src/platform/macos/xpc_control.mm's `pair:name:targetUniqueid:reply:` for the
    /// full contract. `message` is always non-empty and human-readable for either outcome.
    /// `targetUniqueid` (S3 pairing-DoS/hijack fix, Layer B): the specific pending session's
    /// `uniqueid` the owner explicitly picked in `PairingSheet.swift`'s source-IP picker, or `""`
    /// when there was nothing to pick from (0/1 eligible session -- the common one-click case).
    /// The host re-validates that a non-empty target is itself eligible before ever applying the
    /// PIN to it -- this call carries the target, it does not (and cannot) authorize it.
    func pair(_ pin: String, name: String, targetUniqueid: String, reply: @escaping (Bool, String) -> Void)

    /// C: the full paired-clients list, as a JSON array of `{name, uuid}` -- the SAME shape
    /// `nvhttp::get_all_clients()` already serves `GET /api/clients`. No cert, no last-seen
    /// timestamp: neither exists anywhere in `named_cert_t`, so neither is surfaced. Empty
    /// string means the call failed (peer not validated, or the host errored); an empty JSON
    /// array `"[]"` means zero devices are paired.
    func getPairedClients(withReply reply: @escaping (String) -> Void)

    /// C: revoke one paired client by uuid -- calls `nvhttp::unpair_client(uuid)` directly, no
    /// cert logic reimplemented here or on the host side. Reply `Bool` success.
    func unpairClient(_ uuid: String, reply: @escaping (Bool) -> Void)

    /// C: revoke every paired client. Exact web parity with confighttp's `unpairAll`: the host
    /// calls `nvhttp::erase_all_clients()` THEN `proc::proc.terminate()`, ending any session in
    /// progress the same way the web path already does -- this is a deliberate side effect, not
    /// a bug, and the calling UI's destructive confirm must name it. Reply `Bool` success.
    func unpairAllClients(withReply reply: @escaping (Bool) -> Void)

    /// Daemon lifecycle coupling (docs/design/2026-07-19-daemon-lifecycle-coupling.md §3 "Quit
    /// flow"): call this BEFORE `NSApplication.shared.terminate(nil)` on "Quit Skylight". The
    /// host acks immediately (this reply fires right away) then, ~200ms later, raises the same
    /// graceful self-shutdown every other lifecycle trigger uses -- ending any active stream and
    /// releasing the virtual display. Best-effort: if the daemon is unreachable the reply simply
    /// never arrives (see `HostConnection.shutdownHost()`'s ≤1s timeout) and the menu quits
    /// anyway; the daemon's own NOTE_EXIT/self-check backstop tears it down independently.
    func shutdownHost(withReply reply: @escaping () -> Void)

    /// Daemon lifecycle coupling §2C: a cheap no-op called on a dedicated ~2s timer while
    /// connected (see `HostConnection`'s heartbeat timer) -- its only purpose is refreshing the
    /// host's `last_validated_contact` for the presence-window self-check backstop. Carries no
    /// payload either direction; the validated round trip itself IS the signal.
    func menuHeartbeat(withReply reply: @escaping () -> Void)
}

/// Mach service name the host daemon vends the listener on (must match
/// src/platform/macos/xpc_control.mm's `kSkylightMachServiceName` and the `MachServices`
/// key in macos-dist/com.lumen.sunshine.plist).
enum SkylightXPC {
    // Build-time generated (GeneratedIdentity.swift, from skylight-identity.conf)
    // -- see macos-dist/generate-identity.sh.
    static let machServiceName = GeneratedIdentity.xpcServiceName
}
