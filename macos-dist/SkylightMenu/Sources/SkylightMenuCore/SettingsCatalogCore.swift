import Foundation

/// Pure, non-SwiftUI half of `SettingsCatalog.swift` (docs/design/settings-ux.md, rev 2): the
/// hand-authored option-abstraction enums and their string/int codec logic. Lives in
/// `SkylightMenuCore` so it's unit-testable in isolation. The SwiftUI
/// chrome (`SettingsSection`, `SectionChip`, `SettingsRow`, `AdvancedDisclosure`) stays behind in
/// the executable target's `SettingsCatalog.swift` -- those are View types with no logic worth
/// testing on their own.

// MARK: - Video codec abstraction (§5)

/// Advertised codec policy; the client negotiates the session codec. Main10 is explicit.
public enum VideoCodec: String, CaseIterable, Identifiable {
    case automatic, h264, hevc, av1, hevcMain10, av1Main10

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        case .hevcMain10: return "HEVC (require Main10)"
        case .av1Main10: return "AV1 (require Main10)"
        }
    }

    /// Mode 2 requires ordinary codec support; mode 3 additionally requires Main10.
    /// H.264 remains available for client negotiation with every policy.
    public var rawPair: (hevcMode: String, av1Mode: String) {
        switch self {
        case .automatic: return ("0", "0")
        case .h264: return ("1", "1")
        case .hevc: return ("2", "1")
        case .av1: return ("0", "2")
        case .hevcMain10: return ("3", "1")
        case .av1Main10: return ("0", "3")
        }
    }

    /// Preserve explicit Main10 settings when loading existing configuration.
    public static func from(hevcMode: String?, av1Mode: String?) -> VideoCodec {
        let hevc = Int(hevcMode ?? "") ?? 0
        let av1 = Int(av1Mode ?? "") ?? 0
        if av1 >= 3 { return .av1Main10 }
        if av1 == 2 { return .av1 }
        if hevc >= 3 { return .hevcMain10 }
        if hevc == 2 { return .hevc }
        // A new install writes hevc_mode = 1 and leaves av1_mode unset. That is H.264 only,
        // and calling it Automatic meant re-choosing Automatic quietly turned HEVC on.
        if hevc == 1 && av1 <= 1 { return .h264 }
        return .automatic
    }
}

/// `sw_preset` (§1 ADV, conditional on Video engine = Software) -- the fixed x264 preset list
/// the old web `<select>` used (SoftwareEncoder.vue); a raw `string` key in the schema, so any
/// of these values round-trips as plain text via `setConfigValue`.
public enum SoftwarePreset: String, CaseIterable, Identifiable {
    case ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

// MARK: - Display abstraction (§5)

/// Shared by `dd_resolution_option` and `dd_refresh_rate_option` -- both are the same
/// `disabled`/`auto`/`manual` enum shape on the host, just applied to a different axis.
public enum DisplayMatchOption: String, CaseIterable, Identifiable {
    case auto, disabled, manual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Automatic"
        case .disabled: return "Keep this Mac's"
        case .manual: return "Set manually"
        }
    }
}

/// `dd_configuration_option` (§4 "Display activation").
public enum DisplayActivation: String, CaseIterable, Identifiable {
    case disabled = "disabled"
    case checkOnly = "verify_only"
    case turnOnIfNeeded = "ensure_active"
    case turnOnPrimary = "ensure_primary"
    case turnOnDisableOthers = "ensure_only_display"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .disabled: return "Don't change"
        case .checkOnly: return "Check only"
        case .turnOnIfNeeded: return "Turn on if needed"
        case .turnOnPrimary: return "Turn on and make primary"
        case .turnOnDisableOthers: return "Turn on and disable others"
        }
    }
}

// MARK: - Network abstraction (§5)

/// `wan_encryption_mode` / `lan_encryption_mode` -- same Off/Optional/Required int shape (0/1/2)
/// on both keys, just scoped to internet vs. local-network traffic (§4).
public enum EncryptionMode: Int, CaseIterable, Identifiable {
    case off = 0
    case optional = 1
    case required = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .optional: return "Optional"
        case .required: return "Required"
        }
    }
}

/// `origin_web_ui_allowed` (§4 "Web console access") -- a footgun key (§6): the "Anyone,
/// including the internet" case MUST carry its warning wherever it's rendered.
public enum WebConsoleAccess: String, CaseIterable, Identifiable {
    case pc, lan, wan

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pc: return "This Mac only"
        case .lan: return "Local network"
        case .wan: return "Anyone, including the internet"
        }
    }
}

// MARK: - Generic config-key bool helpers (§4)

/// Shared truthy-string vocabulary `sunshine.conf` itself uses (mirrors the old generic
/// renderer's `boolControl` and `config_validate.cpp`'s `try_parse_bool`) -- used by the small
/// number of surfaced BASIC/ADV keys that have no dedicated `HostConnection` convenience setter
/// (`stream_audio`, `keyboard`, `mouse`, `notify_pre_releases`) and so round-trip through the
/// generic `host.setConfigValue` path instead.
public enum ConfigBool {
    public static func isOn(_ raw: String?, default defaultValue: Bool) -> Bool {
        guard let raw, !raw.isEmpty else { return defaultValue }
        return ["enabled", "true", "yes", "on", "1"].contains(raw.lowercased())
    }

    public static func string(_ value: Bool) -> String {
        value ? "enabled" : "disabled"
    }
}

// MARK: - Status-line formatting helpers (ContentView, docs/design/settings-ux.md §2 rev 2)

/// Pure formatting helpers behind `ContentView`'s status line ("18 min · 1080p60 · HEVC ·
/// 28 Mbps"). Extracted verbatim (no signature change -- both already took a plain `Int`) so
/// they're unit-testable without a live `HostConnection`. Call sites (this target's own
/// `MenuStatusLine`, and the executable target's `StatusPaneView`) keep calling these exact
/// static functions -- the byte-identical output is now produced through a native `FormatStyle`
/// conformance underneath (see `ResolutionBucketFormatStyle`/`DurationBucketFormatStyle` below)
/// rather than a bare free function, but the call shape is unchanged.
public enum StatusLineFormatting {
    /// `<duration> · <resolution><fps> · <codec> · <Mbps>` resolution half.
    public static func resolutionBucket(_ height: Int) -> String {
        height.formatted(.resolutionBucket)
    }

    public static func durationString(_ seconds: Int) -> String {
        seconds.formatted(.durationBucket)
    }
}

// MARK: - FormatStyle conformances (native protocol wrapper, byte-identical output)

/// `FormatStyle` conformance for the status line's resolution-bucket half ("4K"/"1440p"/"1080p"/
/// "<n>p"). There is no built-in Foundation formatter for this TV-marketing-name bucketing of a
/// pixel height (`Measurement`/`ByteCountFormatStyle` don't apply -- this isn't a unit
/// conversion), so the exact original switch is reproduced verbatim inside `format(_:)`; only the
/// expression form changed, not a single character of output.
public struct ResolutionBucketFormatStyle: FormatStyle {
    public init() {}

    public func format(_ height: Int) -> String {
        switch height {
        case 2160...: return "4K"
        case 1440..<2160: return "1440p"
        case 1080..<1440: return "1080p"
        default: return "\(height)p"
        }
    }
}

extension FormatStyle where Self == ResolutionBucketFormatStyle {
    public static var resolutionBucket: ResolutionBucketFormatStyle { .init() }
}

/// `FormatStyle` conformance for the status line's duration half (seconds truncated to "Ns"
/// under a minute, else whole "N min"). Deliberately NOT built on `Duration.formatted` --
/// `Duration.formatted(.units(...))` spells its units "sec"/"min" (not bare "s"/" min"), does not
/// truncate-below-a-minute-else-show-only-minutes the way this does, and renders multi-unit
/// breakdowns (e.g. "1 hr, 0 min") rather than a single collapsed unit -- any of that would
/// change existing pinned output (`durationString(3600) == "60 min"`, never "1 hr";
/// `durationString(0) == "0s"`, never "0 sec"). The hand math is kept, just expressed as
/// `format(_:)` instead of a free function.
public struct DurationBucketFormatStyle: FormatStyle {
    public init() {}

    public func format(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return minutes < 1 ? "\(seconds)s" : "\(minutes) min"
    }
}

extension FormatStyle where Self == DurationBucketFormatStyle {
    public static var durationBucket: DurationBucketFormatStyle { .init() }
}

// MARK: - Paired-client model (workstream C, docs/design/skylight-one-design.md §C)

/// One entry from the host's `getPairedClients` XPC reply -- the SAME `{name, uuid}` shape
/// `nvhttp::get_all_clients()` already emits for `GET /api/clients` (no cert, no last-seen
/// timestamp -- neither exists anywhere in `named_cert_t`, so neither is fabricated here).
/// `Codable` so `HostConnection` can decode the JSON array verbatim; lives in `SkylightMenuCore`
/// so the display-name fallback below is unit-testable without a live XPC connection.
public struct PairedClient: Codable, Identifiable, Equatable, Sendable {
    public let name: String
    public let uuid: String

    public init(name: String, uuid: String) {
        self.name = name
        self.uuid = uuid
    }

    public var id: String { uuid }

    /// The paired name, or a short form of the uuid when the host has no name on file -- a row
    /// must never render blank, but it also must never invent a name the host didn't supply.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? PairedClient.shortUUID(uuid) : trimmed
    }

    /// First 8 characters of the uuid -- enough to disambiguate at a glance without printing the
    /// full GUID in a settings row.
    public static func shortUUID(_ uuid: String) -> String {
        String(uuid.prefix(8))
    }
}

// MARK: - Menu-bar icon state (workstream D, docs/design/skylight-one-design.md §D)

/// Pure derivation of the menubar glyph from the three states that can be true at once
/// (connected/streaming/pendingPairing) -- extracted so the precedence rule (a pending pairing
/// request always wins the badge, even mid-stream) is unit-tested without a live `HostConnection`
/// or `MenuBarExtra`. Mirrors `StatusLineFormatting`'s split: `SkylightMenuApp` keeps the single
/// call site, this owns the decision table.
public enum MenuBarIcon {
    /// Lucide glyph for the menubar. A pending pairing request takes precedence over the
    /// streaming state -- it is the more actionable signal and must stay visible even while a
    /// session is already live. Not connected always reads as idle (no badge, no claim about a
    /// state this app cannot currently verify).
    public static func glyph(connected: Bool, streaming: Bool, pendingPairing: Bool) -> LucideGlyph {
        guard connected else { return .monitor }
        if pendingPairing { return .userRoundPlus }
        if streaming { return .monitorPlay }
        return .monitor
    }

    /// Opacity for the menubar glyph (Tahoe-native redesign §1.3): state is expressed via
    /// opacity, never color, so the template icon keeps adapting correctly to light/dark and the
    /// menu-bar "selected" highlight. `connected` bundles offline/untrusted/connecting into one
    /// dimmed state -- there is no distinct glyph for each, only "not currently usable" vs. "usable
    /// right now" (matching Apple's own ~35% opacity convention for disabled menu-bar icon
    /// artwork, HIG: The menu bar).
    public static func opacity(connected: Bool) -> Double {
        connected ? 1.0 : 0.35
    }
}
