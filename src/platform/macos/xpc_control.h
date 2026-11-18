/**
 * @file src/platform/macos/xpc_control.h
 * @brief Declarations for the macOS XPC control service (S0 walking skeleton) and the
 *        validated-menu capture-gate authority added by
 *        docs/design/2026-07-19-daemon-lifecycle-coupling.md.
 *
 * Stands up an NSXPCListener on the Mach service `com.example.lumen.xpc` so the native
 * SkylightMenu.app (macos-dist/SkylightMenu) can talk to the running daemon in-process,
 * authenticated purely by code signature (no passwords, no HTTP). See
 * docs/design/menubar-app.md for the S0-S3 control-surface design and
 * docs/design/2026-07-19-daemon-lifecycle-coupling.md for the capture-gate/lifetime-coupling
 * design this header's new entry points implement; this header is the ONLY thing the rest of
 * the C++ codebase needs to know about either.
 */
#pragma once

#include <chrono>
#include <filesystem>
#include <vector>
#include <string>

namespace platf::macos {
  /**
   * @brief Return config-schema paths in production lookup order.
   *
   * An installed daemon prefers the schema sealed inside its enclosing `.app`; development
   * and non-bundle runs use the configured build-assets path. Pure and exposed for regression
   * tests so production never silently regains a dependency on a temporary build directory.
   */
  std::vector<std::filesystem::path> config_schema_candidates(
    const std::filesystem::path &executable_path,
    const std::filesystem::path &configured_schema_path);

  /**
   * @brief Start the XPC control listener on a background queue and return immediately.
   *
   * Safe to call from `platf::init()`. Never blocks and never touches the capture / encode /
   * protocol path -- it only reads/writes `config::sunshine` fields and the config file.
   * If listener setup fails (e.g. the Mach service isn't vended by launchd, such as when
   * running un-launchd'd from a terminal), this logs a warning and returns without throwing;
   * the rest of the daemon continues to function normally, just without the menubar app
   * control channel. Also starts the ~2s presence-window self-check backstop thread (see
   * `xpc_control.mm`'s `SelfCheckLoop`) exactly once, for the process lifetime.
   */
  void start_xpc_control_service();

  /**
   * @brief True iff a code-signature-validated `SkylightMenu` peer is currently attached, per
   *        the `validated_menu_attached` authority (design doc §2A).
   *
   * "Attached" here means: a peer-validated connection has been accepted and its rolling
   * `last_validated_contact` has not yet gone stale (cleared the instant either the `NOTE_EXIT`
   * watch fires or the periodic self-check backstop trips -- see the design's §2C). Cheap,
   * lock-guarded, non-blocking. Consumed as the session-acceptance gate (§2B.2) by
   * `rtsp.cpp`/`nvhttp.cpp`'s pairing-completion path.
   */
  bool is_validated_menu_attached();

#ifdef SUNSHINE_TESTS
  std::string set_running_configuration_for_tests(const std::string &contents);
  std::string configuration_state_for_tests();
  std::string restore_configuration_for_tests(const std::string &values, const std::string &revision);
  std::string resolve_configuration_value_for_tests(const std::string &key, const std::string &value, const std::string &revision);
  bool local_listener_ready_for_tests(unsigned short port);
  bool owned_listener_ready_for_tests(unsigned short port);
  bool product_protocol_contract_for_tests();
  std::string capture_displays_for_tests();
  std::string capture_displays_on_worker_for_tests(std::chrono::milliseconds timeout);
  bool codec_display_protocol_contract_for_tests();
  std::string set_codec_policy_for_tests(const std::string &hevc, const std::string &av1);
  // Runs the production validated setter against the test process's isolated config file.
  std::string set_config_value_for_tests(const std::string &key, const std::string &value);
  /**
   * @brief Set the validated-menu gate in the unit-test process.
   *
   * Pairing tests have no launchd-vended, signed SkylightMenu peer, but still need to exercise
   * the successful phase-4 certificate path. This hook is absent from production builds and
   * must be reset by the calling test immediately after the gated operation.
   */
  void set_validated_menu_attached_for_tests(bool attached);
#endif

  /**
   * @brief Block the calling thread until a validated menu peer attaches, or `grace` elapses.
   *
   * This is the primary capture gate (§2B.1): called once from `main.cpp` between
   * `platf::init()` (which has already started the capture-inert control listener above) and
   * the mDNS/nvhttp/rtsp service starts. Returns `true` the moment a validated menu attaches
   * (including if one is already attached when called); returns `false` on timeout, in which
   * case the caller must shut the daemon down WITHOUT ever starting those services.
   *
   * @param grace How long to wait for a validated menu before giving up.
   * @return true if a validated menu attached within `grace`, false on timeout.
   */
  bool wait_for_validated_menu(std::chrono::milliseconds grace);
}  // namespace platf::macos
