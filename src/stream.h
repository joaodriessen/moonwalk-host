/**
 * @file src/stream.h
 * @brief Declarations for the streaming protocols.
 */
#pragma once

// standard includes
#include <utility>

// lib includes
#include <boost/asio.hpp>

// local includes
#include "audio.h"
#include "crypto.h"
#include "video.h"

namespace stream {
  constexpr auto VIDEO_STREAM_PORT = 9;
  constexpr auto CONTROL_PORT = 10;
  constexpr auto AUDIO_STREAM_PORT = 11;

  struct session_t;

  struct config_t {
    audio::config_t audio;
    video::config_t monitor;

    int packetsize;
    int minRequiredFecPackets;
    int mlFeatureFlags;
    int controlProtocolType;
    int audioQosType;
    int videoQosType;

    uint32_t encryptionFlagsEnabled;

    std::optional<int> gcmap;
  };

  namespace session {
    enum class state_e : int {
      STOPPED,  ///< The session is stopped
      STOPPING,  ///< The session is stopping
      STARTING,  ///< The session is starting
      RUNNING,  ///< The session is running
    };

    std::shared_ptr<session_t> alloc(config_t &config, rtsp_stream::launch_session_t &launch_session);
    int start(session_t &session, const std::string &addr_string);
    void stop(session_t &session);
    void join(session_t &session);
    state_e state(session_t &session);

    /**
     * @brief Negotiated video params + elapsed duration for a single running session, copied out
     * as plain values -- the cross-TU escape hatch `rtsp_stream::active_session_snapshot()` needs
     * to read a `session_t`'s fields without `session_t` (defined in stream.cpp) ever becoming a
     * complete type outside this translation unit. Mirrors the existing `state()`/`stop()`/
     * `join()` pattern: an opaque accessor over `session_t&`, not a new public struct layout.
     */
    struct video_snapshot_t {
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
     * @brief Read `session.config.monitor.{width,height,framerate,bitrate}` and elapsed time
     * since `session.start_time`. Read-only; does not mutate the session.
     * @param session The session to snapshot. Caller must hold whatever lock protects the
     * session's membership in its owning collection (rtsp.cpp's `_session_slots`) for the
     * duration of the call -- this function itself takes no lock.
     */
    video_snapshot_t snapshot(session_t &session);
  }  // namespace session
}  // namespace stream
