import Foundation
import Observation

/// Tracks acknowledged changes whose consumers need a host restart. The dedicated encoder
/// setter updates configuration, while video can retain a cached selected encoder.
/// Acknowledgements from Retry use the same path. Only an explicit successful restart clears it.
@MainActor
@Observable
public final class RestartCoordinator {
    public private(set) var pendingRestart: Bool = false

    public init() {}

    public static func requiresConfirmation(streaming: Bool) -> Bool { streaming }

    /// Call after a successful configuration write, including the dedicated encoder setter.
    public func markPersistedChange(key: String) {
        guard RestartCoordinator.persistOnlyKeys.contains(key) else { return }
        pendingRestart = true
    }

    /// Call after a successful daemon restart (the banner's own "Restart Now", or the Status
    /// pane's remediation restart) -- the only way `pendingRestart` clears.
    public func clear() {
        pendingRestart = false
    }
    public func synchronize(pendingKeys: Set<String>) {
        pendingRestart = !pendingKeys.isEmpty
    }

    /// Settings whose runtime consumers need restart, including cached encoder selection.
    public static let persistOnlyKeys: Set<String> = [
        "hevc_mode", "av1_mode", "encoder",
        "vt_realtime",
        "sw_preset",
        "stream_audio",
        "audio_sink",
        "dd_resolution_option", "dd_manual_resolution",
        "dd_refresh_rate_option", "dd_manual_refresh_rate",
        "dd_hdr_option",
        "dd_configuration_option",
        "sunshine_name",
        "keyboard",
        "mouse",
        "upnp",
        "wan_encryption_mode",
        "lan_encryption_mode",
        "port",
        "origin_web_ui_allowed",
        "web_ui_enabled",
        "external_ip",
        "address_family",
        "notify_pre_releases",
        "min_log_level",
        "clipboard_sync",
        "output_name",
    ]

    /// Dedicated setters whose current consumers apply the setting live.
    public static let liveSetterKeys: Set<String> = [
        "minimum_fps_target", "virtual_display", "quit_app_on_disconnect", "hide_cursor",
    ]

    /// File-only restore/external edits still need restart when these live consumers differ.
    /// hide_cursor is an in-memory action, not a configuration-file key.
    public static let liveConfigurationKeys: Set<String> = [
        "minimum_fps_target", "virtual_display", "quit_app_on_disconnect",
    ]

    public static func configurationDiffers(key: String, saved: String?, running: String?) -> Bool {
        switch key {
        case "virtual_display":
            return (saved ?? "enabled") != (running ?? "enabled")
        case "quit_app_on_disconnect":
            return ConfigBool.isOn(saved, default: false) != ConfigBool.isOn(running, default: false)
        case "minimum_fps_target":
            return (Double(saved ?? "") ?? 0) != (Double(running ?? "") ?? 0)
        default:
            return saved != running
        }
    }
}
