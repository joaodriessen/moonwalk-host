/**
 * @file src/config.h
 * @brief Declarations for the configuration of Sunshine.
 */
#pragma once

// standard includes
#include <bitset>
#include <chrono>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

// local includes
#include "nvenc/nvenc_config.h"

namespace config {
  struct video_t {
    // ffmpeg params
    int qp;  // higher == more compression and less quality

    int hevc_mode;
    int av1_mode;

    int min_threads;  // Minimum number of threads/slices for CPU encoding

    struct {
      std::string sw_preset;
      std::string sw_tune;
      std::optional<int> svtav1_preset;
    } sw;

    nvenc::nvenc_config nv;
    bool nv_realtime_hags;
    bool nv_opengl_vulkan_on_dxgi;
    bool nv_sunshine_high_power_mode;

    struct {
      int preset;
      int multipass;
      int h264_coder;
      int aq;
      int vbv_percentage_increase;
    } nv_legacy;

    struct {
      std::optional<int> qsv_preset;
      std::optional<int> qsv_cavlc;
      bool qsv_slow_hevc;
    } qsv;

    struct {
      std::optional<int> amd_usage_h264;
      std::optional<int> amd_usage_hevc;
      std::optional<int> amd_usage_av1;
      std::optional<int> amd_rc_h264;
      std::optional<int> amd_rc_hevc;
      std::optional<int> amd_rc_av1;
      std::optional<int> amd_enforce_hrd;
      std::optional<int> amd_quality_h264;
      std::optional<int> amd_quality_hevc;
      std::optional<int> amd_quality_av1;
      std::optional<int> amd_preanalysis;
      std::optional<int> amd_vbaq;
      int amd_coder;
    } amd;

    struct {
      int vt_allow_sw;
      int vt_require_sw;
      int vt_realtime;
      int vt_coder;
      bool vt_low_delay;  // default false: byte-identical to pre-experiment behavior (LOW_DELAY still stripped)
      int vt_cbr;  // default 0: byte-identical to pre-experiment behavior (constant_bit_rate option not set)
      int vt_sync_output;  // default 1 on macOS; requires the locally-patched
                           // ffmpeg (patches/ffmpeg-vtenc-sync-output.patch) to have any effect -- see
                           // patches/README.md and docs/design/2026-07-13-vt-sync-output.md
      int vt_sync_deadline_us;  // default 14000 (14ms): only meaningful when vt_sync_output=1 on the patched
                                // ffmpeg. Caps the post-submit blocking pop so a transient VT encode-latency
                                // spike degrades (frame stays in flight, collected on a later call) instead of
                                // stalling the capture loop past its frame budget -- see the deadline-bounded-pop
                                // addendum in docs/design/2026-07-13-vt-sync-output.md for the 14ms rationale.
      bool vt_reinit_cure;  // default false since 2026-11-01 (the backlog re-forms within seconds, so a rebuild buys little for its hitch): single switch for the backlog-plateau cure (intentional
                            // encoder-session rebuild once vt_sync_deadline_us's permanent backlog plateau
                            // has demonstrably recovered and the session is old enough -- see
                            // video::should_reinit_for_backlog() and
                            // docs/design/2026-07-14-vt-backlog-reinit-cure.md). Auto-gated: inert unless
                            // vt_sync_output && vt_sync_deadline_us > 0 (the only config where a plateau can
                            // form). All thresholds are in-code constexpr (video::cure_params_t) -- this is
                            // the only knob, and it can disable the cure live without a rebuild if it ever
                            // misbehaves.
    } vt;

    struct {
      bool strict_rc_buffer;
    } vaapi;

    std::string capture;
    std::string encoder;
    std::string adapter_name;
    std::string output_name;

    struct dd_t {
      struct workarounds_t {
        std::chrono::milliseconds hdr_toggle_delay;  ///< Specify whether to apply HDR high-contrast color workaround and what delay to use.
      };

      enum class config_option_e {
        disabled,  ///< Disable the configuration for the device.
        verify_only,  ///< @seealso{display_device::SingleDisplayConfiguration::DevicePreparation}
        ensure_active,  ///< @seealso{display_device::SingleDisplayConfiguration::DevicePreparation}
        ensure_primary,  ///< @seealso{display_device::SingleDisplayConfiguration::DevicePreparation}
        ensure_only_display  ///< @seealso{display_device::SingleDisplayConfiguration::DevicePreparation}
      };

      enum class resolution_option_e {
        disabled,  ///< Do not change resolution.
        automatic,  ///< Change resolution and use the one received from Moonlight.
        manual  ///< Change resolution and use the manually provided one.
      };

      enum class refresh_rate_option_e {
        disabled,  ///< Do not change refresh rate.
        automatic,  ///< Change refresh rate and use the one received from Moonlight.
        manual  ///< Change refresh rate and use the manually provided one.
      };

      enum class hdr_option_e {
        disabled,  ///< Do not change HDR settings.
        automatic  ///< Change HDR settings and use the state requested by Moonlight.
      };

      struct mode_remapping_entry_t {
        std::string requested_resolution;
        std::string requested_fps;
        std::string final_resolution;
        std::string final_refresh_rate;
      };

      struct mode_remapping_t {
        std::vector<mode_remapping_entry_t> mixed;  ///< To be used when `resolution_option` and `refresh_rate_option` is set to `automatic`.
        std::vector<mode_remapping_entry_t> resolution_only;  ///< To be use when only `resolution_option` is set to `automatic`.
        std::vector<mode_remapping_entry_t> refresh_rate_only;  ///< To be use when only `refresh_rate_option` is set to `automatic`.
      };

      config_option_e configuration_option;
      resolution_option_e resolution_option;
      std::string manual_resolution;  ///< Manual resolution in case `resolution_option == resolution_option_e::manual`.
      refresh_rate_option_e refresh_rate_option;
      std::string manual_refresh_rate;  ///< Manual refresh rate in case `refresh_rate_option == refresh_rate_option_e::manual`.
      hdr_option_e hdr_option;
      std::chrono::milliseconds config_revert_delay;  ///< Time to wait until settings are reverted (after stream ends/app exists).
      bool config_revert_on_disconnect;  ///< Specify whether to revert display configuration on client disconnect.
      mode_remapping_t mode_remapping;
      workarounds_t wa;
    } dd;

    std::string virtual_display;  ///< "enabled" or "disabled" — whether to create on-demand virtual displays (macOS only).

    int max_bitrate;  // Maximum bitrate, sets ceiling in kbps for bitrate requested from client
    double minimum_fps_target;  ///< Lowest framerate that will be used when streaming. Range 0-1000, 0 = half of client's requested framerate.

    bool perf_trace;  ///< Ships dark (default false). When true, emits a rolling 1s [perf] summary log line with capture/mailbox/encode counters (docs/design/pipeline-overhaul.md §2). Zero behavior change; counter increments are relaxed atomics.
    int frame_departure_mode;  ///< Controls the gap-filler that keeps frame departures roughly on a 1/framerate cadence when SCK doesn't deliver on time. 0 = off (no gap-filler). 1 = capture-side v1 timer (macOS SCK frameDeliveryTimer, docs/design/pipeline-overhaul.md §3A) -- the default; this is shipped and LIVE in production (not dark), see config.cpp. 2 = encode-side v2-A phase-lock (docs/design/2026-07-13-cadence-phaselock.md §2), ships dark/selectable until it wins a live A/B against mode 1. Back-compat: the legacy bool key `steady_frame_delivery` is still accepted and maps true->1 / false->0 whenever `frame_departure_mode` itself is absent from the config. macOS-only; no-op elsewhere.
    double departure_guard_ms;  ///< Guard offset (ms) added to 1/framerate when computing the v2-A phase-lock's backfill deadline (frame_departure_mode == 2 only, docs/design/2026-07-13-cadence-phaselock.md §4.4); must exceed SCK's normal on-time inter-arrival jitter so on-time ticks never backfill. Default 2.5, range 0-8. No effect in modes 0/1.
    bool smooth_pacing;  ///< Ships dark (default false). When true, the video send pacer (stream.cpp's videoBroadcastThread) spreads a frame's packets across ~90% of the inter-frame interval derived from the negotiated framerate, instead of bursting them at an assumed line-rate budget. Reduces WiFi jitter drops from bursty sends. When false, byte-identical to the pre-existing burst pacer.
    bool capture_cursor = true;  ///< Seeds the initial value of the `display_cursor` global (src/globals.h) at daemon startup — whether ScreenCaptureKit composites the mouse cursor into captured frames. Default true (shown), matching the pre-existing hardcoded default. The live SkylightMenu XPC "hide cursor" toggle (src/platform/macos/xpc_control.mm setHideCursor:) still flips the same global at runtime exactly as today; this only changes what it starts at.
  };

  struct audio_t {
    std::string sink;
    std::string virtual_sink;
    bool stream;
    bool install_steam_drivers;
  };

  constexpr int ENCRYPTION_MODE_NEVER = 0;  // Never use video encryption, even if the client supports it
  constexpr int ENCRYPTION_MODE_OPPORTUNISTIC = 1;  // Use video encryption if available, but stream without it if not supported
  constexpr int ENCRYPTION_MODE_MANDATORY = 2;  // Always use video encryption and refuse clients that can't encrypt

  struct stream_t {
    std::chrono::milliseconds ping_timeout;

    std::string file_apps;

    int fec_percentage;

    // Video encryption settings for LAN and WAN streams
    int lan_encryption_mode;
    int wan_encryption_mode;
  };

  struct nvhttp_t {
    // Could be any of the following values:
    // pc|lan|wan
    std::string origin_web_ui_allowed;

    // Could be any of the following values:
    // pc|lan|wan
    // Gates the UNAUTHENTICATED phase-1 "getservercert" pairing request only (starting a brand
    // new pairing) -- mirrors origin_web_ui_allowed above (src/confighttp.cpp's authenticate()),
    // same net::net_e comparison via net::from_address(), same PC < LAN < WAN ordering
    // (src/network.h). Does NOT affect streaming/resume/launch by already-paired clients, nor the
    // later phases of an already-started pairing session (clientchallenge/serverchallengeresp/
    // clientpairingsecret) -- those continue a session that already passed this gate.
    // Default "lan": IMPORTANT, verified via net::from_address() (src/network.cpp) -- Tailscale
    // CGNAT (100.64.0.0/10) and IPv6 ULA (fc00::/7) both bucket as LAN, not WAN, so the default
    // does NOT block Tailscale/VPN pairing. Do not "tighten" this to "pc" under the mistaken
    // belief that VPN clients need "wan" to get through.
    std::string pair_origin_allowed;

    std::string pkey;
    std::string cert;

    std::string sunshine_name;

    std::string file_state;

    std::string external_ip;

    bool web_ui_enabled;  ///< Gate for the confighttp web UI thread/listener (port 47990). Default true, preserving upstream posture. When false, confighttp never starts (no web port opens); native SkylightMenu (macOS) remains fully functional either way since it talks to nvhttp/XPC directly, not the web UI.
  };

  struct input_t {
    std::unordered_map<int, int> keybindings;

    std::chrono::milliseconds back_button_timeout;
    std::chrono::milliseconds key_repeat_delay;
    std::chrono::duration<double> key_repeat_period;

    std::string gamepad;
    bool ds4_back_as_touchpad_click;
    bool motion_as_ds4;
    bool touchpad_as_ds4;
    bool ds5_inputtino_randomize_mac;

    bool keyboard;
    bool key_rightalt_to_key_win;
    bool mouse;
    bool controller;

    bool always_send_scancodes;

    bool high_resolution_scrolling;
    bool native_pen_touch;
  };

  namespace flag {
    enum flag_e : std::size_t {
      PIN_STDIN = 0,  ///< Read PIN from stdin instead of http
      FRESH_STATE,  ///< Do not load or save state
      FORCE_VIDEO_HEADER_REPLACE,  ///< force replacing headers inside video data
      UPNP,  ///< Try Universal Plug 'n Play
      CONST_PIN,  ///< Use "universal" pin
      FLAG_SIZE  ///< Number of flags
    };
  }  // namespace flag

  struct prep_cmd_t {
    prep_cmd_t(std::string &&do_cmd, std::string &&undo_cmd, bool &&elevated):
        do_cmd(std::move(do_cmd)),
        undo_cmd(std::move(undo_cmd)),
        elevated(std::move(elevated)) {
    }

    explicit prep_cmd_t(std::string &&do_cmd, bool &&elevated):
        do_cmd(std::move(do_cmd)),
        elevated(std::move(elevated)) {
    }

    std::string do_cmd;
    std::string undo_cmd;
    bool elevated;
  };

  struct sunshine_t {
    std::string locale;
    int min_log_level;
    std::bitset<flag::FLAG_SIZE> flags;
    std::string credentials_file;

    std::string username;
    std::string password;
    std::string salt;

    std::string config_file;

    struct cmd_t {
      std::string name;
      int argc;
      char **argv;
    } cmd;

    std::uint16_t port;
    std::string address_family;
    std::string bind_address;

    std::string log_file;
    bool notify_pre_releases;
    bool system_tray;
    bool quit_app_on_disconnect;  ///< Terminate the running app on client disconnect instead of leaving it resumable (every reconnect becomes a fresh launch, so global_prep_cmd re-fires).
    bool clipboard_sync;  ///< Gate for the native in-stream clipboard endpoints (nvhttp `/actions/clipboard`, https_server-only). Default true: a paired client already fully controls the host, so this is not a privilege escalation; the toggle exists for privacy-conscious/shared-host users who want to opt out.
    std::vector<prep_cmd_t> prep_cmds;
  };

  extern video_t video;
  extern audio_t audio;
  extern stream_t stream;
  extern nvhttp_t nvhttp;
  extern input_t input;
  extern sunshine_t sunshine;

  // Zero starts the host, a positive result ends a handled command, and a negative result reports an error.
  int parse(int argc, char *argv[]);
  std::unordered_map<std::string, std::string> parse_config(const std::string_view &file_content);

  /**
   * @brief Process-wide mutex serializing the entire read-modify-write of `sunshine.config_file`.
   *
   * Two independent code paths perform an unsynchronized read-modify-write of the same
   * `sunshine.conf` file: confighttp.cpp's `saveConfig()` (full-file rewrite from a posted JSON
   * bag) and xpc_control.mm's `SetConfValue()` (surgical find-or-append + atomic temp+rename).
   * With no shared lock, an XPC setter (menubar) racing a web-UI Save is a last-writer-wins lost
   * update -- one caller's edit silently vanishes. Both translation units already include this
   * header, so it is the natural shared home for the lock. Callers must take a
   * `std::lock_guard<std::mutex>` on this spanning their ENTIRE read -> modify -> write sequence
   * for the config file, and must NOT call back into anything that re-acquires it (plain
   * non-recursive mutex -- a second acquire on the same thread deadlocks).
   *
   * Meyers singleton (function-local static): thread-safe initialization per the standard,
   * no static-initialization-order concerns across translation units.
   */
  std::mutex &config_write_mutex();
}  // namespace config
