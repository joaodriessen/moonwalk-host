/**
 * @file src/rtsp.h
 * @brief Declarations for RTSP streaming.
 */
#pragma once

// standard includes
#include <atomic>
#include <optional>

// lib includes
#include <boost/system/error_code.hpp>

// local includes
#include "crypto.h"
#include "thread_safe.h"
#include "pending_launch.h"

namespace rtsp_stream {
  constexpr auto RTSP_SETUP_PORT = 21;

  /**
   * @brief Decide whether a failed RTSP setup-port bind attempt should be retried.
   *
   * Recovery seatbelt (P1, docs/design/2026-07-12-black-screen-permanent-fix.md, Mode 3): after a
   * capture crash, launchd relaunches Sunshine immediately, but the crashed instance's RTSP socket
   * can still be draining -- the new instance's first bind attempt(s) can transiently fail with
   * EADDRINUSE even though the port is about to be free. Only that specific, transient error is
   * worth retrying, up to a bounded attempt count; any other bind error (bad address, permission,
   * etc.) is not retryable and should fail immediately. Extracted as a pure function so the
   * decision is unit-testable without real sockets.
   * @param ec The error code returned by the bind attempt that just failed.
   * @param attempt The 1-based attempt number that just failed.
   * @param max_attempts The maximum number of attempts allowed.
   * @return true if another bind attempt should be made.
   */
  bool should_retry_bind(const boost::system::error_code &ec, int attempt, int max_attempts);
  std::string audio_stream_parameters(int channel_limit, std::string_view surround_params);

  struct launch_session_t {
    uint32_t id;

    crypto::aes_t gcm_key;
    crypto::aes_t iv;

    std::string av_ping_payload;
    uint32_t control_connect_data;

    bool host_audio;
    std::string unique_id;
    int width;
    int height;
    int fps;
    int gcmap;
    int appid;
    int surround_info;
    std::string surround_params;
    bool continuous_audio;
    bool enable_hdr;
    bool enable_sops;

    // Per-session client cursor-drawing declaration, from the optional `clientSideCursor`
    // launch/resume query param (parsed in nvhttp.cpp's make_launch_session()). The name
    // matches existing ecosystem prior art -- moonlight-qt PR #1785 / Apollo PR #1336 (both
    // closed unmerged, no shipped implementation anywhere) -- deliberately, so a future client
    // that resurrects that convention needs no host-side renaming.
    // - true  -> the client draws its own local OS cursor; the host should NOT composite one
    //            (avoids a double cursor).
    // - false -> the client does not draw a local cursor; the host SHOULD composite one.
    // - absent (nullopt) -> the param was not sent at all, i.e. a legacy/stock Moonlight client
    //   that has no opinion. This must be distinguished from `false` -- see the apply site in
    //   nvhttp.cpp's launch()/resume() for why an absent param resets to the configured default
    //   rather than reusing whatever a *previous* session on this host last requested.
    std::optional<bool> client_side_cursor;
    int desktop_scale = 0;  // 0=Auto, 1=1x, 2=2x; optional launch extension
    bool adaptive_bitrate = false;
    std::string authenticated_device_uuid;
    std::string authenticated_device_name;

    std::optional<crypto::cipher::gcm_t> rtsp_cipher;
    std::string rtsp_url_scheme;
    uint32_t rtsp_iv_counter;

    // We currently only support a single pending RTSP session per launch, and that
    // session must only ever be consumed by a single ANNOUNCE (see cmd_announce()).
    // This flag guards against a second (or later) TCP connection racing in during
    // the pending window and spawning a duplicate streaming session from the same
    // launch. It is freshly constructed (false) for every new launch_session_t, so
    // each /launch or /resume gets exactly one use.
    std::atomic<bool> consumed {false};
    pending_launch_t pending;
  };

  bool launch_session_raise(std::shared_ptr<launch_session_t> launch_session);
  bool has_pending_launch();

  /**
   * @brief Clear state for the specified launch session.
   * @param launch_session_id The ID of the session to clear.
   */
  void launch_session_clear(uint32_t launch_session_id);

  /**
   * @brief Get the number of active sessions.
   * @return Count of active sessions.
   */
  int session_count();

  // Status-only count. Unlike session_count(), never joins/clears sessions or
  // performs display teardown from an HTTP/status reader.
  int active_session_count();

  /**
   * @brief Read-only snapshot of the (single) active session's negotiated video params, for
   * status-reporting callers (S1 XPC `richStatus`, see docs/design/menubar-app.md) that must
   * never reach into or perturb the streaming/capture path itself.
   *
   * Deliberately NOT a live/measured value: `bitrate_kbps` is the negotiated request the client
   * asked for (host-adjusted for FEC/audio overhead at ANNOUNCE time), not actual encode
   * throughput -- there is no public "measured encode bitrate" accessor anywhere in the
   * capture/encode path, and this type does not add one.
   */
  struct session_snapshot_t {
    int width = 0;
    int height = 0;
    int fps = 0;
    int bitrate_kbps = 0;
    long session_seconds = 0;
    uint32_t session_id = 0;
    std::string device_uuid;
    std::string device_name;
  };

  /**
   * @brief Snapshot the first (and, per current invariant, only) running session's negotiated
   * video params and elapsed duration.
   * @return `std::nullopt` when no session is active; otherwise a snapshot copied out under the
   * session-slot lock (mirrors `session_count()`'s locking) -- no reference into the live
   * session escapes this call.
   */
  std::optional<session_snapshot_t> active_session_snapshot();

  /**
   * @brief Terminates all running streaming sessions.
   */
  void terminate_sessions();
  bool terminate_session(uint32_t expected_session_id, std::string_view expected_device_uuid);

  /**
   * @brief Runs the RTSP server loop.
   */
  void start();
}  // namespace rtsp_stream
