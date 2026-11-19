/**
 * @file src/nvhttp.cpp
 * @brief Definitions for the nvhttp (GameStream) server.
 */
// macros
#define BOOST_BIND_GLOBAL_PLACEHOLDERS

// standard includes
#include <algorithm>
#include <charconv>
#include <chrono>
#include <filesystem>
#include <format>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

// platform includes (POSIX reverse-DNS -- see hostname_hint_for_ip()'s doc comment)
#include <netdb.h>
#include <sys/socket.h>

// lib includes
#include <boost/asio/ssl/context.hpp>
#include <boost/asio/ssl/context_base.hpp>
#include <boost/property_tree/json_parser.hpp>
#include <boost/property_tree/ptree.hpp>
#include <boost/property_tree/xml_parser.hpp>
#include <Simple-Web-Server/server_http.hpp>

// local includes
#include "config.h"
#include "display_device.h"
#include "file_handler.h"
#include "globals.h"
#include "httpcommon.h"
#include "logging.h"
#include "network.h"
#include "nvhttp.h"
#include "file_transfer.h"
#include "png_clipboard.h"
#include <boost/asio/thread_pool.hpp>
#include <boost/asio/post.hpp>
#include "listener_readiness.h"
#include "platform/common.h"
#include "process.h"
#include "rtsp.h"
#include "streaming_options.h"
#include "system_tray.h"
#include "utility.h"
#include "uuid.h"
#include "video.h"

#ifdef __APPLE__
  // Screen Recording preflight (see call sites in launch()/resume() below) -- same
  // guarded-include pattern used elsewhere for macOS-only platform headers (e.g. video.cpp's
  // platform/macos/perf_trace.h include).
  #include "platform/macos/misc.h"
  #include "platform/macos/audio_capture_policy.h"
  #include "platform/macos/desktop_scale.h"
  #include "platform/macos/capture_health.h"

  // Pairing-completion gate (docs/design/2026-07-19-daemon-lifecycle-coupling.md §2B.2) -- see
  // call site in clientpairingsecret() below.
  #include "platform/macos/xpc_control.h"
#endif

using namespace std::literals;

namespace nvhttp {

  static constexpr std::string_view EMPTY_PROPERTY_TREE_ERROR_MSG = "Property tree is empty. Probably, control flow got interrupted by an unexpected C++ exception. This is a bug in Sunshine. Moonlight-qt will report Malformed XML (missing root element)."sv;

  namespace fs = std::filesystem;
  namespace pt = boost::property_tree;

  crypto::cert_chain_t cert_chain;

  class SunshineHTTPSServer: public SimpleWeb::ServerBase<SunshineHTTPS> {
  public:
    SunshineHTTPSServer(const std::string &certification_file, const std::string &private_key_file):
        ServerBase<SunshineHTTPS>::ServerBase(443),
        context(boost::asio::ssl::context::tls_server) {
      // Disabling TLS 1.0 and 1.1 (see RFC 8996)
      context.set_options(boost::asio::ssl::context::no_tlsv1);
      context.set_options(boost::asio::ssl::context::no_tlsv1_1);
      context.use_certificate_chain_file(certification_file);
      context.use_private_key_file(private_key_file, boost::asio::ssl::context::pem);
    }

    std::function<int(SSL *)> verify;
    std::function<void(std::shared_ptr<Response>, std::shared_ptr<Request>)> on_verify_failed;

  protected:
    boost::asio::ssl::context context;

    void after_bind() override {
      if (verify) {
        context.set_verify_mode(boost::asio::ssl::verify_peer | boost::asio::ssl::verify_fail_if_no_peer_cert | boost::asio::ssl::verify_client_once);
        context.set_verify_callback([](int verified, boost::asio::ssl::verify_context &ctx) {
          // To respond with an error message, a connection must be established
          return 1;
        });
      }
    }

    // This is Server<HTTPS>::accept() with SSL validation support added
    void accept() override {
      auto connection = create_connection(*io_service, context);

      acceptor->async_accept(connection->socket->lowest_layer(), [this, connection](const SimpleWeb::error_code &ec) {
        auto lock = connection->handler_runner->continue_lock();
        if (!lock) {
          return;
        }

        if (ec != SimpleWeb::error::operation_aborted) {
          this->accept();
        }

        auto session = std::make_shared<Session>(config.max_request_streambuf_size, connection);

        if (!ec) {
          boost::asio::ip::tcp::no_delay option(true);
          SimpleWeb::error_code ec;
          session->connection->socket->lowest_layer().set_option(option, ec);

          session->connection->set_timeout(config.timeout_request);
          session->connection->socket->async_handshake(boost::asio::ssl::stream_base::server, [this, session](const SimpleWeb::error_code &ec) {
            session->connection->cancel_timeout();
            auto lock = session->connection->handler_runner->continue_lock();
            if (!lock) {
              return;
            }
            if (!ec) {
              if (verify && !verify(session->connection->socket->native_handle())) {
                this->write(session, on_verify_failed);
              } else {
                this->read(session);
              }
            } else if (this->on_error) {
              this->on_error(session->request, ec);
            }
          });
        } else if (this->on_error) {
          this->on_error(session->request, ec);
        }
      });
    }
  };

  using https_server_t = SunshineHTTPSServer;
  using http_server_t = SimpleWeb::Server<SimpleWeb::HTTP>;

  struct conf_intern_t {
    std::string servercert;
    std::string pkey;
  } conf_intern;

  struct named_cert_t {
    std::string name;
    std::string uuid;
    std::string cert;
  };

  struct client_t {
    std::vector<named_cert_t> named_devices;
  };

  // uniqueID, session
  std::unordered_map<std::string, pair_session_t> map_id_sess;
  // Guards ALL access to map_id_sess. It is touched from (at least) 4 distinct thread contexts
  // with zero prior synchronization: the nvhttp ssl-server thread and tcp-server thread (both via
  // pair<T>()), the confighttp thread (via pin() <- savePin()), and the XPC per-connection GCD
  // queue (via pin() <- pair:name:targetUniqueid:reply:). A concurrent emplace() (which can rehash) racing a
  // find()/begin()/erase() on another thread is undefined behavior and crash-class. Take this
  // lock as the FIRST statement of pair<T>() and pin() -- the two outer entry points reachable
  // directly from a foreign thread -- and hold it for the entire function body. Do NOT lock it
  // again inside the inner phase helpers (getservercert/clientchallenge/serverchallengeresp/
  // clientpairingsecret/fail_pair/remove_session): they only ever run on the stack of pair<T>(),
  // and this is a plain (non-recursive) mutex -- locking it a second time on the same thread
  // deadlocks.
  std::mutex map_id_sess_mutex;

  // Creation timestamp for each pending entry in `map_id_sess`, keyed identically. Guarded by
  // `map_id_sess_mutex` exactly like `map_id_sess` itself -- see that mutex's declaration comment
  // above for the full thread-context rationale. Kept as a companion map (rather than a field on
  // pair_session_t) to avoid widening that struct's shape from this file alone.
  std::unordered_map<std::string, std::chrono::steady_clock::time_point> map_id_sess_created_at;

  // Fast pairing-outcome observation (owner-test-motivated fix): terminal PAIRING outcome
  // (true=paired, false=failed) for a `uniqueid` whose pairing session has ALREADY been removed
  // from `map_id_sess` by `fail_pair()`/`clientpairingsecret()` -- see those functions and
  // `record_pair_outcome_locked()` below. This is a companion map exactly like `map_id_sess_
  // created_at` above: guarded by `map_id_sess_mutex` on the WRITE side (both writers already run
  // on the stack of `pair<T>()` with that lock held -- see the mutex's declaration comment), and
  // by the same mutex (taken explicitly) on the READ side in `take_pair_outcome()`, which runs
  // from a different context (the XPC thread), not from inside `pair<T>()`.
  std::unordered_map<std::string, bool> map_id_outcome;

  // Creation timestamp for each entry in `map_id_outcome`, keyed identically -- same role as
  // `map_id_sess_created_at` plays for `map_id_sess`, feeding `PAIRING_OUTCOME_TTL` pruning below.
  std::unordered_map<std::string, std::chrono::steady_clock::time_point> map_id_outcome_created_at;

  // How long an unauthenticated pending pairing session (created by the "getservercert" phrase,
  // awaiting a PIN) is kept before it's considered abandoned. Unlike `login_throttle_map`
  // (confighttp.cpp), which is time-pruned, `map_id_sess` previously had no expiry at all --
  // entries were only ever erased by fail_pair()/clientpairingsecret() on the happy/sad path of
  // an in-progress pairing. A client that starts pairing and never finishes left its session (and
  // unclaimed cert bytes) in the map forever, needlessly widening the race window unauthenticated
  // sessions sit in. This constant governs expiry only -- it does not change which session pin()
  // or pair<T>() targets (see pin()'s target_uniqueid / single-pending-session logic for that).
  constexpr std::chrono::minutes PAIRING_SESSION_TTL {5};

  // How long after the owner submits a PIN (`pair_session_t::pin_submitted_at`) the client-driven
  // handshake has to reach phase 4 (`clientpairingsecret()`, which removes the session on success)
  // before it's considered stalled. Overwhelmingly a wrong PIN -- the client derives the wrong AES
  // key, detects the mismatch at its own verification stage, and aborts before ever sending phase
  // 4 (app/backend/nvpairingmanager.cpp's pair(), phase-3 hash check). A legit LAN handshake
  // completes phase 1->4 in well under 1s after PIN entry, so 10s clears even a slow-RTT legit
  // case with wide margin while still turning a would-be 30s-blind-wait/5-min-TTL-lingering
  // failure into a fast, honest one. Only sessions with `pin_submitted_at` set can trigger this --
  // see that field's doc comment on `pair_session_t`.
  constexpr std::chrono::seconds HANDSHAKE_TIMEOUT {10};

  // How long a recorded-but-unconsumed pairing OUTCOME (`map_id_outcome`) is kept before being
  // pruned as abandoned. Independent of `PAIRING_SESSION_TTL` above: that one governs an
  // UNFINISHED pairing attempt still awaiting a phase-4 result; this one governs an ALREADY-
  // DECIDED outcome waiting to be picked up exactly once by `take_pair_outcome()` and then
  // discarded. Must comfortably outlive the pairing sheet's 30s wait-for-growth deadline
  // (`PairingSheet.swift`'s `startWaitingForConfirmation()`) plus its one final reconcile poll, so
  // a slow/delayed poll tick can never miss an outcome that was already recorded -- 45s leaves
  // ~15s of margin over that 30s window.
  constexpr std::chrono::seconds PAIRING_OUTCOME_TTL {45};

  // Forward declaration: `prune_stale_pairing_sessions_locked()` below now also records the
  // post-PIN handshake-timeout outcome via this function (defined further down, alongside
  // `fail_pair()`/`clientpairingsecret()`, its other two callers).
  void record_pair_outcome_locked(const std::string &uniqueid, bool paired);

  /**
   * @brief Drop stale, never-completed pending pairing sessions (`map_id_sess`) AND stale,
   * never-consumed terminal outcomes (`map_id_outcome`) -- two independent TTLs pruned in one
   * pass, since every existing call site already holds `map_id_sess_mutex` here anyway (extending
   * this function keeps a single prune-then-use call shape rather than asking every caller to
   * remember a second prune call). PAIRING_SESSION_TTL governs the first sweep, PAIRING_OUTCOME_TTL
   * the second; see their declaration comments for why they're independent.
   * @note Caller must hold `map_id_sess_mutex`. This is a LEAF operation: it only ever touches
   * `map_id_sess` / `map_id_sess_created_at` / `map_id_outcome` / `map_id_outcome_created_at` and
   * never acquires `cert_state_mutex`, so it cannot introduce a new lock-ordering path beyond the
   * existing map_id_sess_mutex -> cert_state_mutex order documented on `cert_state_mutex` above.
   */
  void prune_stale_pairing_sessions_locked() {
    auto now = std::chrono::steady_clock::now();

    for (auto it = map_id_sess.begin(); it != map_id_sess.end();) {
      auto ts_it = map_id_sess_created_at.find(it->first);
      bool expired = ts_it == map_id_sess_created_at.end() || now - ts_it->second > PAIRING_SESSION_TTL;

      // Fast honest failure: the owner submitted a PIN (`pin_submitted_at` set) but the
      // client-driven handshake never reached phase 4 (clientpairingsecret() removes the session
      // on success) -- overwhelmingly a wrong PIN, since the client detects the key mismatch at
      // its own verification stage and aborts before phase 4
      // (app/backend/nvpairingmanager.cpp's pair()). See `HANDSHAKE_TIMEOUT`'s doc comment above.
      bool handshake_timed_out =
        !expired && it->second.pin_submitted_at.has_value() && now - *it->second.pin_submitted_at > HANDSHAKE_TIMEOUT;

      if (expired || handshake_timed_out) {
        if (handshake_timed_out) {
          // Record the failure BEFORE erasing below -- take_pair_outcome() can then still return
          // it. map_id_outcome != map_id_sess, so this write is safe mid-iteration over the latter.
          record_pair_outcome_locked(it->first, false);
          BOOST_LOG(info) << "nvhttp::pair: handshake stalled "sv << HANDSHAKE_TIMEOUT.count()
                          << "s after PIN entry -- recording pairing failure and dropping session"sv;
        }
        map_id_sess_created_at.erase(it->first);
        it = map_id_sess.erase(it);
      } else {
        ++it;
      }
    }

    for (auto it = map_id_outcome.begin(); it != map_id_outcome.end();) {
      auto ts_it = map_id_outcome_created_at.find(it->first);
      bool expired = ts_it == map_id_outcome_created_at.end() || now - ts_it->second > PAIRING_OUTCOME_TTL;
      if (expired) {
        map_id_outcome_created_at.erase(it->first);
        it = map_id_outcome.erase(it);
      } else {
        ++it;
      }
    }
  }

  /**
   * @brief Record the terminal pairing outcome for `uniqueid` (Fix: fast pairing outcome). Caller
   * must hold `map_id_sess_mutex` -- see that mutex's declaration comment for why `fail_pair()`
   * and `clientpairingsecret()` (this function's only two callers) already satisfy that on the
   * stack of `pair<T>()`, needing NO additional locking here.
   */
  void record_pair_outcome_locked(const std::string &uniqueid, bool paired) {
    map_id_outcome[uniqueid] = paired;
    map_id_outcome_created_at[uniqueid] = std::chrono::steady_clock::now();
  }

  // ---------------------------------------------------------------------------------------------
  // S3 pairing-DoS/hijack fix -- owner-armed eligibility window (see nvhttp.h's arm_pairing_
  // window()/pin() doc comments and docs/design/... for the full design). Everything below is
  // guarded by `map_id_sess_mutex` exactly like `map_id_sess`/`map_id_sess_created_at` -- every
  // caller of these helpers already holds that lock (they're only ever invoked from inside
  // pair<T>(), pin(), has_pending_pair_request(), list_pending_pair_sessions(), all of which take
  // the lock as their first statement).
  // ---------------------------------------------------------------------------------------------

  // The last time an operator-gated surface (confighttp's authenticated getPinPage GET, or the
  // XPC beginPairingWindowWithReply: call) armed the pairing window. Default-constructed
  // (epoch/zero `time_point`) means "never armed" -- `window_active_locked()` treats that as
  // inactive, so a freshly-started daemon with no owner action yet refuses every pin() call
  // rather than (incorrectly) treating "never armed" as "always open".
  std::chrono::steady_clock::time_point pairing_window_open_at {};

  // How long an armed window stays open. Generous enough that the owner opening the host's
  // pairing UI and then walking to their client device (or vice versa) doesn't race the window
  // shut, but bounded so an old arm event can't leave the host permanently one-click-eligible.
  constexpr std::chrono::seconds PAIRING_WINDOW_DURATION {180};

  // How far BEFORE the arm event a session's own creation time may fall and still count as
  // eligible -- covers the common ordering where the genuine Moonlight/Starlight client fires
  // `getservercert` (and shows its PIN to the owner) a moment before the owner opens the host's
  // "Pair New Device" UI (which is what actually arms the window).
  //
  // Deliberately pinned to `PAIRING_SESSION_TTL` rather than a shorter magic number: a pending
  // session already can't outlive its own TTL (see `prune_stale_pairing_sessions_locked()`), so a
  // lookback that reaches all the way back to TTL makes eligibility == "window is active AND the
  // session hasn't expired" -- no separate, tighter cliff inside that. That cliff used to be 60s,
  // sized for "same-room, near-instant" pairing. Real cross-device pairing isn't instant: the
  // owner clicks Pair on the client, then has to physically walk to the host and open its pairing
  // UI (or the reverse order), which routinely takes longer than 60s. A session created before
  // `open - 60s` was silently filtered out of `list_pending_pair_sessions()` -- the owner would
  // see an empty list despite a live, correct session sitting in `map_id_sess` -- and re-arming
  // the window in response only pushed `open` later, moving the genuine session *further* outside
  // the lookback (re-arming was actively counterproductive). Matching the lookback to the TTL
  // means any session that's still alive is, by construction, within lookback range, so re-arming
  // can never make an eligible session ineligible.
  constexpr std::chrono::seconds PAIRING_WINDOW_LOOKBACK {PAIRING_SESSION_TTL};

  // Layer C (always-on defense-in-depth, independent of whether a window is armed): max pending
  // (not-yet-paired) sessions tolerated from a single source IP. A genuine owner pairs one device
  // from one IP at a time; this bounds how large a phantom army a single attacker IP can maintain
  // without touching the legitimate multi-eligible-session UX at all (per-IP, never global -- see
  // the design's kill-list on why a global rate limit is NOT used here).
  constexpr std::size_t PER_IP_PENDING_CAP = 3;

  // Layer C: hard ceiling on map_id_sess's total size, independent of source IP -- bounds worst
  // case memory/lock-hold-time growth from many distinct attacker IPs each stroking under the
  // per-IP cap. Eviction (see enforce below) only ever removes the OLDEST NON-eligible entry, so
  // flooding at the cap can never evict the owner's own genuine, currently-eligible session.
  constexpr std::size_t MAP_ID_SESS_GLOBAL_CAP = 32;

  /// @brief True iff an armed pairing window is currently open. Caller must hold `map_id_sess_mutex`.
  bool window_active_locked(std::chrono::steady_clock::time_point now) {
    return pairing_window_open_at != std::chrono::steady_clock::time_point {} &&
           now <= pairing_window_open_at + PAIRING_WINDOW_DURATION;
  }

  /**
   * @brief True iff the pending session named by `uniqueid` is *eligible* for `pin()` to target:
   * a pairing window is currently active AND the session's own creation time falls within
   * `[pairing_window_open_at - PAIRING_WINDOW_LOOKBACK, pairing_window_open_at +
   * PAIRING_WINDOW_DURATION]`. A session with no recorded creation time (should not happen --
   * every `map_id_sess` entry gets one at emplace time in `pair<T>()`) is never eligible, fail
   * safe. Caller must hold `map_id_sess_mutex`.
   */
  bool session_eligible_locked(const std::string &uniqueid, std::chrono::steady_clock::time_point now) {
    if (!window_active_locked(now)) {
      return false;
    }
    auto ts_it = map_id_sess_created_at.find(uniqueid);
    if (ts_it == map_id_sess_created_at.end()) {
      return false;
    }
    return ts_it->second >= pairing_window_open_at - PAIRING_WINDOW_LOOKBACK;
  }

  /**
   * @brief Count currently-pending sessions whose captured `source_ip` matches `ip`. Used to
   * enforce `PER_IP_PENDING_CAP` in the getservercert branch of `pair<T>()`, BEFORE a new session
   * is emplaced. Caller must hold `map_id_sess_mutex` and should call
   * `prune_stale_pairing_sessions_locked()` first so expired sessions aren't counted.
   */
  std::size_t count_sessions_from_ip_locked(const std::string &ip) {
    std::size_t count = 0;
    for (auto &kv : map_id_sess) {
      if (kv.second.source_ip == ip) {
        ++count;
      }
    }
    return count;
  }

  /**
   * @brief Evict the OLDEST NON-eligible `map_id_sess` entry, if any exists. Used to enforce
   * `MAP_ID_SESS_GLOBAL_CAP` in the getservercert branch of `pair<T>()`: when the map is at
   * capacity, this makes room for a new (also non-eligible, by construction -- a brand-new
   * getservercert can only be eligible if it falls in an ALREADY-armed window, in which case it's
   * exactly the genuine-client-arrives-during-the-owner's-window case Layer A is designed to let
   * through) session WITHOUT ever removing a session the owner's armed window currently protects.
   * @return `true` if an entry was evicted (room was made), `false` if every entry is currently
   * eligible (in which case the caller must reject the new session instead of evicting one).
   * Caller must hold `map_id_sess_mutex`.
   */
  bool evict_oldest_non_eligible_locked() {
    auto now = std::chrono::steady_clock::now();
    std::string oldest_id;
    std::chrono::steady_clock::time_point oldest_ts;
    bool found = false;

    for (auto &[id, ts] : map_id_sess_created_at) {
      if (session_eligible_locked(id, now)) {
        continue;
      }
      if (!found || ts < oldest_ts) {
        found = true;
        oldest_id = id;
        oldest_ts = ts;
      }
    }

    if (!found) {
      return false;
    }
    map_id_sess.erase(oldest_id);
    map_id_sess_created_at.erase(oldest_id);
    return true;
  }

  void arm_pairing_window_locked() {
    pairing_window_open_at = std::chrono::steady_clock::now();
  }

  client_t client_root;
  static std::optional<authenticated_device_t> resolve_paired_device(const X509 *certificate, const std::vector<named_cert_t> &devices);
  std::atomic<uint32_t> session_id_counter;

  // Guards the paired device list and TLS certificate chain together.
  // When locks are nested, pairing sessions come first, then this lock,
  // then the credential file mutex shared with the web settings.
  std::mutex cert_state_mutex;

  using args_t = SimpleWeb::CaseInsensitiveMultimap;
  using resp_https_t = std::shared_ptr<typename SimpleWeb::ServerBase<SunshineHTTPS>::Response>;
  using req_https_t = std::shared_ptr<typename SimpleWeb::ServerBase<SunshineHTTPS>::Request>;
  using resp_http_t = std::shared_ptr<typename SimpleWeb::ServerBase<SimpleWeb::HTTP>::Response>;
  using req_http_t = std::shared_ptr<typename SimpleWeb::ServerBase<SimpleWeb::HTTP>::Request>;

  enum class op_e {
    ADD,  ///< Add certificate
    REMOVE  ///< Remove certificate
  };

  std::string get_arg(const args_t &args, const char *name, const char *default_value = nullptr) {
    auto it = args.find(name);
    if (it == std::end(args)) {
      if (default_value != nullptr) {
        return std::string(default_value);
      }

      throw std::out_of_range(name);
    }
    return it->second;
  }

  // Bounds/cleans the UNTRUSTED, attacker-controllable `devicename` query param sent by the
  // pairing client (see pair_session_t::client_device_name's doc comment) before it is ever
  // stored or surfaced to the owner. Treated the same way as source_ip-derived data: this is
  // display-only input, not a trust signal, so it just needs to be safe to store and render --
  // capped length (defends against a malicious client stuffing a huge value into host state),
  // control characters stripped (defends against terminal/log/UI injection via the picker JSON),
  // and -- critically -- the result must be STRICTLY VALID UTF-8 on a codepoint boundary. A byte
  // that merely "looks ASCII or continuation" is NOT enough: `list_pending_pair_sessions()` feeds
  // this straight into nlohmann::json, whose default strict `dump()` THROWS on invalid/truncated
  // UTF-8 (json.exception.type_error.316) -- uncaught at the XPC (xpc_control.mm) and confighttp
  // JSON-response call sites, which crashes the whole daemon. A single malformed byte
  // (e.g. `devicename=%C3`, a lone UTF-8 lead byte) sent by ANY LAN client during the owner's
  // pairing window would previously have reached `dump()` unvalidated -- this validator is the
  // single source of truth that closes that off, so every downstream serializer is safe by
  // construction rather than each needing its own escaping logic.
  std::string sanitize_client_device_name(const std::string &raw) {
    constexpr std::size_t max_len = 64;

    std::string out;
    out.reserve(std::min(raw.size(), max_len));
    std::size_t i = 0;
    const std::size_t n = raw.size();
    while (i < n) {
      unsigned char c = static_cast<unsigned char>(raw[i]);

      // ASCII fast path: strip control characters (0x00-0x1F, 0x7F), keep printable ASCII.
      if (c < 0x80) {
        if (c < 0x20 || c == 0x7F) {
          ++i;
          continue;
        }
        if (out.size() + 1 > max_len) {
          break;
        }
        out.push_back(static_cast<char>(c));
        ++i;
        continue;
      }

      // Multi-byte UTF-8: determine sequence length from the lead byte and validate every
      // continuation byte AND the specific lead/first-continuation combinations that would
      // otherwise admit overlong encodings, encoded surrogate halves (U+D800-U+DFFF, which are
      // not valid scalar values), or codepoints past U+10FFFF. A byte sequence failing ANY of
      // these checks is DROPPED (resync one byte forward), never truncated mid-sequence.
      std::size_t seq_len;
      unsigned char lo1 = 0x80, hi1 = 0xBF;  // valid range for the first continuation byte
      if ((c & 0xE0) == 0xC0) {
        seq_len = 2;
        if (c < 0xC2) {  // 0xC0/0xC1 can only encode overlong 1-byte values
          ++i;
          continue;
        }
      } else if ((c & 0xF0) == 0xE0) {
        seq_len = 3;
        if (c == 0xE0) {
          lo1 = 0xA0;  // else overlong
        } else if (c == 0xED) {
          hi1 = 0x9F;  // else a UTF-16 surrogate half (D800-DFFF)
        }
      } else if ((c & 0xF8) == 0xF0) {
        seq_len = 4;
        if (c == 0xF0) {
          lo1 = 0x90;  // else overlong
        } else if (c == 0xF4) {
          hi1 = 0x8F;  // else > U+10FFFF
        } else if (c > 0xF4) {
          ++i;  // lead byte alone already implies > U+10FFFF
          continue;
        }
      } else {
        ++i;  // stray continuation byte or an invalid lead (0x80-0xBF, 0xF8-0xFF)
        continue;
      }

      if (i + seq_len > n) {
        break;  // truncated sequence at end of input -- drop it, don't emit partial bytes
      }
      bool valid = true;
      for (std::size_t k = 1; k < seq_len && valid; ++k) {
        unsigned char cc = static_cast<unsigned char>(raw[i + k]);
        unsigned char lo = (k == 1) ? lo1 : 0x80;
        unsigned char hi = (k == 1) ? hi1 : 0xBF;
        valid = (cc >= lo && cc <= hi);
      }
      if (!valid) {
        ++i;  // resync one byte at a time rather than skipping the whole (invalid) sequence
        continue;
      }
      if (out.size() + seq_len > max_len) {
        break;  // never slice a codepoint at the length cap
      }
      out.append(raw, i, seq_len);
      i += seq_len;
    }
    return out;
  }

  // Persist the proposed list before changing the active authorization state.
  // The caller holds cert_state_mutex.
  bool save_state(const client_t &client) {
    if (config::sunshine.flags[config::flag::FRESH_STATE]) return true;
    std::lock_guard file_lock {http::credential_file_mutex};
    try {
      pt::ptree root;
      if (fs::exists(config::nvhttp.file_state)) {
        pt::read_json(config::nvhttp.file_state, root);
      }
      root.erase("root"s);
      root.put("root.uniqueid", http::unique_id);
      pt::ptree devices;
      for (const auto &device : client.named_devices) {
        pt::ptree entry;
        entry.put("name"s, device.name);
        entry.put("cert"s, device.cert);
        entry.put("uuid"s, device.uuid);
        devices.push_back(std::make_pair(""s, entry));
      }
      root.add_child("root.named_devices"s, devices);
      std::ostringstream serialized;
      pt::write_json(serialized, root);
      if (file_handler::write_file_atomic(config::nvhttp.file_state.c_str(), serialized.str(), file_handler::file_access::owner_only)) {
        return true;
      }
    } catch (std::exception &e) {
      BOOST_LOG(error) << "Couldn't save paired devices: "sv << e.what();
      return false;
    }
    BOOST_LOG(error) << "Couldn't save paired devices"sv;
    return false;
  }

  // The caller holds cert_state_mutex.
  void adopt_client_state(client_t client) {
    cert_chain.clear();
    for (const auto &device : client.named_devices) {
      if (auto cert = crypto::x509(device.cert)) cert_chain.add(std::move(cert));
    }
    client_root = std::move(client);
  }

  // Mutates `cert_chain` and `client_root`. Must be called with `cert_state_mutex` already held
  // by the caller -- this function does not lock it itself (see the mutex's declaration comment
  // above). Everything before the "Empty certificate chain..." section below only touches a local
  // ptree/client_t and does not require the lock, but callers must hold it for the whole call for
  // simplicity and to keep exactly one invariant ("hold the lock before calling load_state()") to
  // reason about.
  void load_state() {
    if (!fs::exists(config::nvhttp.file_state)) {
      BOOST_LOG(info) << "File "sv << config::nvhttp.file_state << " doesn't exist"sv;
      http::unique_id = uuid_util::uuid_t::generate().string();
      return;
    }

    pt::ptree tree;
    try {
      pt::read_json(config::nvhttp.file_state, tree);
    } catch (std::exception &e) {
      BOOST_LOG(error) << "Couldn't read "sv << config::nvhttp.file_state << ": "sv << e.what();

      return;
    }

    auto unique_id_p = tree.get_optional<std::string>("root.uniqueid");
    if (!unique_id_p) {
      // This file doesn't contain moonlight credentials
      http::unique_id = uuid_util::uuid_t::generate().string();
      return;
    }
    http::unique_id = std::move(*unique_id_p);

    auto root = tree.get_child("root");
    client_t client;

    // Import from old format
    if (root.get_child_optional("devices")) {
      auto device_nodes = root.get_child("devices");
      for (auto &[_, device_node] : device_nodes) {
        auto uniqID = device_node.get<std::string>("uniqueid");

        if (device_node.count("certs")) {
          for (auto &[_, el] : device_node.get_child("certs")) {
            named_cert_t named_cert;
            named_cert.name = ""s;
            named_cert.cert = el.get_value<std::string>();
            named_cert.uuid = uuid_util::uuid_t::generate().string();
            client.named_devices.emplace_back(named_cert);
          }
        }
      }
    }

    if (root.count("named_devices")) {
      for (auto &[_, el] : root.get_child("named_devices")) {
        named_cert_t named_cert;
        named_cert.name = el.get_child("name").get_value<std::string>();
        named_cert.cert = el.get_child("cert").get_value<std::string>();
        named_cert.uuid = el.get_child("uuid").get_value<std::string>();
        client.named_devices.emplace_back(named_cert);
      }
    }

    adopt_client_state(std::move(client));
  }

  bool add_authorized_client(const std::string &name, std::string &&cert) {
    named_cert_t named_cert;
    named_cert.name = name;
    named_cert.cert = std::move(cert);
    named_cert.uuid = uuid_util::uuid_t::generate().string();

    // Pairing holds map_id_sess_mutex before entering here. Preserve the lock order documented
    // on cert_state_mutex when saving the shared pairing and Web UI state.
    std::lock_guard<std::mutex> lock(cert_state_mutex);

    auto next = client_root;
    next.named_devices.emplace_back(std::move(named_cert));
    if (!save_state(next)) return false;
    client_root = std::move(next);
    return true;
  }

  std::shared_ptr<rtsp_stream::launch_session_t> make_launch_session(bool host_audio, const args_t &args, std::string &validation_error) {
    validation_error.clear();
    auto launch_session = std::make_shared<rtsp_stream::launch_session_t>();

    launch_session->id = ++session_id_counter;

    auto rikey = util::from_hex_vec(get_arg(args, "rikey"), true);
    if (rikey.size() != 16) {
      // gcm_key is consumed as a fixed 16-byte AES-128-GCM key further down the RTSP
      // pipeline regardless of how many bytes actually landed in it -- a short/malformed
      // rikey would otherwise cause a 16-byte heap over-read for the lifetime of the
      // session. Reject the request instead of ever constructing a session around it.
      BOOST_LOG(error) << "Rejecting launch/resume request with invalid rikey length ("sv << rikey.size() << " bytes, expected 16)"sv;
      validation_error = "Invalid input encryption key. Reconnect from the client.";
      return nullptr;
    }
    std::copy(rikey.cbegin(), rikey.cend(), std::back_inserter(launch_session->gcm_key));

    launch_session->host_audio = host_audio;
    std::stringstream mode = std::stringstream(get_arg(args, "mode", "0x0x0"));
    // Split mode by the char "x", to populate width/height/fps
    int x = 0;
    std::string segment;
    while (std::getline(mode, segment, 'x')) {
      if (x == 0) {
        launch_session->width = atoi(segment.c_str());
        if (launch_session->width <= 0 || launch_session->width > 8192) {
          // Unbounded client-supplied width would otherwise reach display_device's
          // ">0" check and pass straight through to a subprocess spawn/kill + display
          // reconfiguration sweep on an absurd value. Reject at the parse site instead,
          // mirroring the rtsp.cpp launch-field bounds checks (packetsize/framerate/etc).
          BOOST_LOG(error) << "Rejecting launch/resume request with invalid width ("sv << launch_session->width << ", expected 1-8192)"sv;
          validation_error = "Choose a video width between 1 and 8192 pixels.";
          return nullptr;
        }
      }
      if (x == 1) {
        launch_session->height = atoi(segment.c_str());
        if (launch_session->height <= 0 || launch_session->height > 8192) {
          BOOST_LOG(error) << "Rejecting launch/resume request with invalid height ("sv << launch_session->height << ", expected 1-8192)"sv;
          validation_error = "Choose a video height between 1 and 8192 pixels.";
          return nullptr;
        }
      }
      if (x == 2) {
        launch_session->fps = atoi(segment.c_str());
        if (launch_session->fps <= 0 || launch_session->fps > 240) {
          BOOST_LOG(error) << "Rejecting launch/resume request with invalid fps ("sv << launch_session->fps << ", expected 1-240)"sv;
          validation_error = "Choose a frame rate between 1 and 240 fps.";
          return nullptr;
        }
      }
      x++;
    }
    if (x != 3) {
      validation_error = "Choose a complete video resolution and frame rate.";
      return nullptr;
    }
    if (auto it = args.find("desktopScale"s); it != args.end()) {
      const auto scale = streaming_options::desktop_scale(it->second);
      if (!scale) { validation_error = "Choose Automatic, 1x or 2x desktop scale."; return nullptr; }
      launch_session->desktop_scale = *scale;
#ifdef __APPLE__
      if (skylight_desktop_scale(launch_session->width, launch_session->height, *scale) < 0) {
        validation_error = "2x desktop scale requires an even video width and height. Choose an even resolution or Automatic scale.";
        return nullptr;
      }
#endif
    }
    if (auto it = args.find("adaptiveBitrate"s); it != args.end()) {
      const auto adaptive = streaming_options::adaptive_bitrate(it->second);
      if (!adaptive) { validation_error = "Adaptive bitrate must be on or off."; return nullptr; }
      launch_session->adaptive_bitrate = *adaptive;
    }
    launch_session->unique_id = (get_arg(args, "uniqueid", "unknown"));
    launch_session->appid = (int) util::from_view(get_arg(args, "appid", "unknown"));
    launch_session->enable_sops = util::from_view(get_arg(args, "sops", "0"));
    launch_session->surround_info = (int) util::from_view(get_arg(args, "surroundAudioInfo", "196610"));
    launch_session->surround_params = (get_arg(args, "surroundParams", ""));
    launch_session->continuous_audio = util::from_view(get_arg(args, "continuousAudio", "0"));
    launch_session->gcmap = (int) util::from_view(get_arg(args, "gcmap", "0"));
    launch_session->enable_hdr = util::from_view(get_arg(args, "hdrMode", "0"));

    // Optional per-session client cursor declaration (see launch_session_t::client_side_cursor
    // in rtsp.h for the full semantics). Presence vs. absence matters here, not just the value,
    // so this uses the args.find() idiom (matching the required-param checks in launch()/resume())
    // rather than get_arg()'s default-sentinel idiom -- a client that never sends this param
    // (stock/legacy Moonlight) must come out as nullopt, not as a false-equivalent "0".
    if (auto it = args.find("clientSideCursor"s); it != std::end(args)) {
      launch_session->client_side_cursor = util::from_view(it->second) != 0;
    }

    // Encrypted RTSP is enabled with client reported corever >= 1
    auto corever = util::from_view(get_arg(args, "corever", "0"));
    if (corever >= 1) {
      launch_session->rtsp_cipher = crypto::cipher::gcm_t {
        launch_session->gcm_key,
        false
      };
      launch_session->rtsp_iv_counter = 0;
    }
    launch_session->rtsp_url_scheme = launch_session->rtsp_cipher ? "rtspenc://"s : "rtsp://"s;

    // Generate the unique identifiers for this connection that we will send later during RTSP handshake
    unsigned char raw_payload[8];
    RAND_bytes(raw_payload, sizeof(raw_payload));
    launch_session->av_ping_payload = util::hex_vec(raw_payload);
    RAND_bytes((unsigned char *) &launch_session->control_connect_data, sizeof(launch_session->control_connect_data));

    launch_session->iv.resize(16);
    uint32_t prepend_iv = util::endian::big<uint32_t>((int) util::from_view(get_arg(args, "rikeyid")));
    auto prepend_iv_p = (uint8_t *) &prepend_iv;
    std::copy(prepend_iv_p, prepend_iv_p + sizeof(prepend_iv), std::begin(launch_session->iv));
    return launch_session;
  }

  std::shared_ptr<rtsp_stream::launch_session_t> make_launch_session(bool host_audio, const args_t &args) {
    std::string validation_error;
    return make_launch_session(host_audio, args, validation_error);
  }

  void remove_session(const pair_session_t &sess) {
    map_id_sess_created_at.erase(sess.client.uniqueID);
    map_id_sess.erase(sess.client.uniqueID);
  }

  void fail_pair(pair_session_t &sess, pt::ptree &tree, const std::string status_msg) {
    tree.put("root.paired", 0);
    tree.put("root.<xmlattr>.status_code", 400);
    tree.put("root.<xmlattr>.status_message", status_msg);

    // Record the result before removing the session that owns its ID.
    record_pair_outcome_locked(sess.client.uniqueID, false);

    remove_session(sess);  // Security measure, delete the session when something went wrong and force a re-pair
  }

  bool getservercert(pair_session_t &sess, pt::ptree &tree, const std::string &pin) {
    if (sess.last_phase != PAIR_PHASE::NONE) {
      fail_pair(sess, tree, "Out of order call to getservercert");
      return false;
    }
    sess.last_phase = PAIR_PHASE::GETSERVERCERT;

    // Fast pairing-outcome observation: this is the exact moment the owner-entered PIN is applied
    // to the session (AES key derivation just below uses it). Stamped once, only on a real PIN
    // submission (the ordering check above already rejected any out-of-order re-entry) -- feeds
    // `prune_stale_pairing_sessions_locked()`'s post-PIN handshake timeout. See
    // `pair_session_t::pin_submitted_at`'s doc comment.
    sess.pin_submitted_at = std::chrono::steady_clock::now();

    if (sess.async_insert_pin.salt.size() < 32) {
      fail_pair(sess, tree, "Salt too short");
      return false;
    }

    std::string_view salt_view {sess.async_insert_pin.salt.data(), 32};

    auto salt = util::from_hex<std::array<uint8_t, 16>>(salt_view, true);

    auto key = crypto::gen_aes_key(salt, pin);
    sess.cipher_key = std::make_unique<crypto::aes_t>(key);

    tree.put("root.paired", 1);
    tree.put("root.plaincert", util::hex_vec(conf_intern.servercert, true));
    tree.put("root.<xmlattr>.status_code", 200);
    return true;
  }

  void clientchallenge(pair_session_t &sess, pt::ptree &tree, const std::string &challenge) {
    if (sess.last_phase != PAIR_PHASE::GETSERVERCERT) {
      fail_pair(sess, tree, "Out of order call to clientchallenge");
      return;
    }
    sess.last_phase = PAIR_PHASE::CLIENTCHALLENGE;

    if (!sess.cipher_key) {
      fail_pair(sess, tree, "Cipher key not set");
      return;
    }
    crypto::cipher::ecb_t cipher(*sess.cipher_key, false);

    std::vector<uint8_t> decrypted;
    if (cipher.decrypt(challenge, decrypted) < 0) {
      fail_pair(sess, tree, "Failed to decrypt challenge");
      return;
    }

    auto x509 = crypto::x509(conf_intern.servercert);
    auto sign = crypto::signature(x509);
    auto serversecret = crypto::rand(16);

    decrypted.insert(std::end(decrypted), std::begin(sign), std::end(sign));
    decrypted.insert(std::end(decrypted), std::begin(serversecret), std::end(serversecret));

    auto hash = crypto::hash({(char *) decrypted.data(), decrypted.size()});
    auto serverchallenge = crypto::rand(16);

    std::string plaintext;
    plaintext.reserve(hash.size() + serverchallenge.size());

    plaintext.insert(std::end(plaintext), std::begin(hash), std::end(hash));
    plaintext.insert(std::end(plaintext), std::begin(serverchallenge), std::end(serverchallenge));

    std::vector<uint8_t> encrypted;
    cipher.encrypt(plaintext, encrypted);

    sess.serversecret = std::move(serversecret);
    sess.serverchallenge = std::move(serverchallenge);

    tree.put("root.paired", 1);
    tree.put("root.challengeresponse", util::hex_vec(encrypted, true));
    tree.put("root.<xmlattr>.status_code", 200);
  }

  void serverchallengeresp(pair_session_t &sess, pt::ptree &tree, const std::string &encrypted_response) {
    if (sess.last_phase != PAIR_PHASE::CLIENTCHALLENGE) {
      fail_pair(sess, tree, "Out of order call to serverchallengeresp");
      return;
    }
    sess.last_phase = PAIR_PHASE::SERVERCHALLENGERESP;

    if (!sess.cipher_key || sess.serversecret.empty()) {
      fail_pair(sess, tree, "Cipher key or serversecret not set");
      return;
    }

    std::vector<uint8_t> decrypted;
    crypto::cipher::ecb_t cipher(*sess.cipher_key, false);

    if (cipher.decrypt(encrypted_response, decrypted) < 0) {
      fail_pair(sess, tree, "Failed to decrypt challenge response");
      return;
    }

    sess.clienthash = std::move(decrypted);

    auto serversecret = sess.serversecret;
    auto sign = crypto::sign256(crypto::pkey(conf_intern.pkey), serversecret);

    serversecret.insert(std::end(serversecret), std::begin(sign), std::end(sign));

    tree.put("root.pairingsecret", util::hex_vec(serversecret, true));
    tree.put("root.paired", 1);
    tree.put("root.<xmlattr>.status_code", 200);
  }

  void clientpairingsecret(pair_session_t &sess, std::shared_ptr<safe::queue_t<crypto::x509_t>> &add_cert, pt::ptree &tree, const std::string &client_pairing_secret) {
    if (sess.last_phase != PAIR_PHASE::SERVERCHALLENGERESP) {
      fail_pair(sess, tree, "Out of order call to clientpairingsecret");
      return;
    }

#ifdef __APPLE__
    // Pairing-completion gate (docs/design/2026-07-19-daemon-lifecycle-coupling.md §2B.2, defense
    // in depth): refuse to COMPLETE pairing (add the client's cert, mark it authorized) while no
    // code-signature-validated SkylightMenu peer is attached. This is phase 4 of the handshake --
    // gating here, rather than earlier phases, still lets an already-armed pairing window's
    // getservercert/challenge exchange proceed (harmless without a completed cert), but a new
    // client can never actually become a trusted, persistently-paired device during a menu-less
    // window.
    if (!platf::macos::is_validated_menu_attached()) {
      fail_pair(sess, tree, "Host is not ready to pair (open Moonwalk Host on the Mac)");
      return;
    }
#endif

    sess.last_phase = PAIR_PHASE::CLIENTPAIRINGSECRET;

    auto &client = sess.client;

    if (client_pairing_secret.size() <= 16) {
      fail_pair(sess, tree, "Client pairing secret too short");
      return;
    }

    std::string_view secret {client_pairing_secret.data(), 16};
    std::string_view sign {client_pairing_secret.data() + secret.size(), client_pairing_secret.size() - secret.size()};

    auto x509 = crypto::x509(client.cert);
    if (!x509) {
      fail_pair(sess, tree, "Invalid client certificate");
      return;
    }
    auto x509_sign = crypto::signature(x509);

    std::string data;
    data.reserve(sess.serverchallenge.size() + x509_sign.size() + secret.size());

    data.insert(std::end(data), std::begin(sess.serverchallenge), std::end(sess.serverchallenge));
    data.insert(std::end(data), std::begin(x509_sign), std::end(x509_sign));
    data.insert(std::end(data), std::begin(secret), std::end(secret));

    auto hash = crypto::hash(data);

    // if hash not correct, probably MITM
    bool same_hash = hash.size() == sess.clienthash.size() && std::equal(hash.begin(), hash.end(), sess.clienthash.begin());
    auto verify = crypto::verify256(crypto::x509(client.cert), secret, sign);
    if (same_hash && verify) {
      if (!add_authorized_client(client.name, std::move(client.cert))) {
        fail_pair(sess, tree, "Could not save the paired device.");
        tree.put("root.<xmlattr>.status_code", 500);
        return;
      }
      tree.put("root.paired", 1);
      add_cert->raise(std::move(x509));

      // Fast pairing-outcome observation: a read-only OBSERVATION of the crypto verification
      // decision made just above (`same_hash && verify`) -- does not participate in or alter that
      // check at all. Recorded BEFORE remove_session() erases the session below, using `client`
      // (still a valid reference into `sess`, see the `auto &client = sess.client;` alias above).
      // Safe without additional locking -- see fail_pair()'s identical note (this function is the
      // other of the two callers `record_pair_outcome_locked()`'s doc comment refers to).
      record_pair_outcome_locked(client.uniqueID, true);
    } else {
      tree.put("root.paired", 0);

      // Fast pairing-outcome observation: the wrong-PIN / MITM-suspected case (the whole point of
      // this fix -- see this file's `take_pair_outcome()` doc comment). Same safety note as above.
      record_pair_outcome_locked(client.uniqueID, false);
    }

    remove_session(sess);
    tree.put("root.<xmlattr>.status_code", 200);
  }

  template<class T>
  struct tunnel;

  template<>
  struct tunnel<SunshineHTTPS> {
    static auto constexpr to_string = "HTTPS"sv;
  };

  template<>
  struct tunnel<SimpleWeb::HTTP> {
    static auto constexpr to_string = "NONE"sv;
  };

  template<class T>
  void print_req(std::shared_ptr<typename SimpleWeb::ServerBase<T>::Request> request) {
    // Headers and query values can contain credentials and file paths.
    BOOST_LOG(debug) << tunnel<T>::to_string << ' ' << request->method << ' ' << request->path;
  }

  template<class T>
  void not_found(std::shared_ptr<typename SimpleWeb::ServerBase<T>::Response> response, std::shared_ptr<typename SimpleWeb::ServerBase<T>::Request> request) {
    print_req<T>(request);

    pt::ptree tree;
    tree.put("root.<xmlattr>.status_code", 404);

    std::ostringstream data;

    pt::write_xml(data, tree);
    response->write(data.str());

    *response
      << "HTTP/1.1 404 NOT FOUND\r\n"
      << data.str();

    response->close_connection_after_response = true;
  }

  template<class T>
  void pair(std::shared_ptr<safe::queue_t<crypto::x509_t>> &add_cert, std::shared_ptr<typename SimpleWeb::ServerBase<T>::Response> response, std::shared_ptr<typename SimpleWeb::ServerBase<T>::Request> request) {
    // Serializes ALL of map_id_sess's touches across this function -- see map_id_sess_mutex's
    // declaration comment. Held for the entire function body, including the emplace(), the
    // find(), and the clientchallenge()/serverchallengeresp()/clientpairingsecret() calls below
    // (all of which dereference a reference into the map). CAVEAT: the PIN_STDIN debug branch a
    // few lines down does a blocking std::getline(std::cin, pin) while this lock is held -- that
    // stalls every other pairing/PIN thread until a human types into stdin. PIN_STDIN is a
    // dev/CLI-only flag not exercised by the packaged macOS app/menubar flow, so this is an
    // accepted minimal-diff tradeoff rather than a bug.
    std::lock_guard<std::mutex> lock(map_id_sess_mutex);

    print_req<T>(request);

    pt::ptree tree;

    auto fg = util::fail_guard([&]() {
      std::ostringstream data;

      pt::write_xml(data, tree);
      response->write(data.str());
      response->close_connection_after_response = true;
    });

    auto args = request->parse_query_string();
    if (args.find("uniqueid"s) == std::end(args)) {
      tree.put("root.<xmlattr>.status_code", 400);
      tree.put("root.<xmlattr>.status_message", "Missing uniqueid parameter");

      return;
    }

    auto uniqID {get_arg(args, "uniqueid")};

    args_t::const_iterator it;
    if (it = args.find("phrase"); it != std::end(args)) {
      if (it->second == "getservercert"sv) {
        // Drop any abandoned pending sessions before growing the map with a new one -- see
        // PAIRING_SESSION_TTL / prune_stale_pairing_sessions_locked()'s declaration comments.
        prune_stale_pairing_sessions_locked();

        // SECURITY (Layer C, S3 pairing-DoS/hijack fix): capture the attacker-unspoofable TCP
        // source address for this getservercert BEFORE any cap enforcement below -- see
        // pair_session_t::source_ip's doc comment (nvhttp.h) for why this can't be forged and
        // what it's used for (the per-IP cap here; the owner picker's labels in
        // list_pending_pair_sessions()).
        std::string source_ip = request->remote_endpoint().address().to_string();

        // LAN-only-by-default pairing origin gate (mirrors src/confighttp.cpp's authenticate(),
        // which gates the web UI the same way via origin_web_ui_allowed): only the UNAUTHENTICATED
        // phase-1 "getservercert" request that STARTS a new pairing session is gated here. Once a
        // session exists, clientchallenge/serverchallengeresp/clientpairingsecret continue an
        // already-allowed session and are deliberately NOT re-checked. Streaming, /serverinfo,
        // resume, and launch by already-paired clients never go through pair<T>() at all, so they
        // are entirely unaffected by this gate.
        auto pair_ip_type = net::from_address(source_ip);
        if (pair_ip_type > http::pair_origin_allowed) {
          BOOST_LOG(info) << "Pairing from ["sv << source_ip << "] ("sv << net::to_enum_string(pair_ip_type)
                           << ") denied: outside pair_origin_allowed="sv << net::to_enum_string(http::pair_origin_allowed);
          tree.put("root.paired", 0);
          tree.put("root.<xmlattr>.status_code", 403);
          tree.put("root.<xmlattr>.status_message", "Pairing from this network origin is not allowed");
          return;
        }

        // Per-source-IP cap: reject BEFORE emplace if this IP already has PER_IP_PENDING_CAP (or
        // more) pending sessions. Bounds how large a phantom army a single attacker IP can
        // maintain; a genuine owner pairing one device from one IP is unaffected. Per-IP, never
        // global -- see the design's kill-list on why a blanket rate limit is NOT used here (an
        // attacker could weaponize a global limit to deny the owner's own legit getservercert).
        if (count_sessions_from_ip_locked(source_ip) >= PER_IP_PENDING_CAP) {
          BOOST_LOG(warning) << "nvhttp::pair: rejected getservercert -- source "sv << source_ip
                              << " already has "sv << PER_IP_PENDING_CAP
                              << " or more pending pairing sessions"sv;
          // NOTE: deliberately NOT routed through fail_pair()/remove_session() here -- those
          // erase map_id_sess by `sess.client.uniqueID`, and the rejected request's uniqueid is
          // still attacker-controlled, unvalidated, client-supplied input (see the client-cert-
          // fetch comment above this whole branch). If it happened to collide with an unrelated
          // ALREADY-pending session's key (e.g. the genuine client's), routing through
          // remove_session would delete that unrelated session as a side effect of rejecting
          // THIS one -- a new foot-gun this cap must not introduce. Set the failure response
          // directly instead, touching no map state at all.
          tree.put("root.paired", 0);
          tree.put("root.<xmlattr>.status_code", 429);
          tree.put("root.<xmlattr>.status_message", "Too many pending pairing requests from this address");
          return;
        }

        // Global cap: if map_id_sess is already at capacity, make room by evicting the OLDEST
        // NON-eligible entry (never an eligible one -- see evict_oldest_non_eligible_locked()'s
        // doc comment, which is what keeps this from ever letting a flood evict the owner's own
        // armed-window session). If every current entry is eligible, refuse the new one instead.
        if (map_id_sess.size() >= MAP_ID_SESS_GLOBAL_CAP && !evict_oldest_non_eligible_locked()) {
          BOOST_LOG(warning) << "nvhttp::pair: rejected getservercert -- map_id_sess at capacity ("sv
                              << MAP_ID_SESS_GLOBAL_CAP << ") and every pending entry is currently eligible"sv;
          // Same rationale as the per-IP rejection above: no fail_pair()/remove_session() call,
          // for the same uniqueid-collision reason -- set the response directly.
          tree.put("root.paired", 0);
          tree.put("root.<xmlattr>.status_code", 429);
          tree.put("root.<xmlattr>.status_message", "Too many pending pairing requests");
          return;
        }

        pair_session_t sess;

        sess.client.uniqueID = std::move(uniqID);
        sess.client.cert = util::from_hex_vec(get_arg(args, "clientcert"), true);
        sess.source_ip = std::move(source_ip);

        // UNTRUSTED, attacker-controllable client-supplied label (see pair_session_t's doc
        // comment and sanitize_client_device_name() above) -- display-only default for the
        // owner's editable device-name field, never a trust/selection signal.
        sess.client_device_name = sanitize_client_device_name(get_arg(args, "devicename", ""));

        BOOST_LOG(debug) << "client cert length :: "sv << sess.client.cert.size();
        auto ptr = map_id_sess.emplace(sess.client.uniqueID, std::move(sess)).first;
        map_id_sess_created_at[ptr->first] = std::chrono::steady_clock::now();

        // Info-level on purpose (was previously only the debug-level cert-length line above,
        // which is off by default) -- this is the one artifact that lets the owner confirm a
        // getservercert actually reached and registered with the host, as opposed to it being
        // lost somewhere between the client and here. See list_pending_pair_sessions()'s eligible-
        // count log below for the second half of that diagnostic story.
        BOOST_LOG(info) << "nvhttp::pair: registered pending pairing session from ["sv << ptr->second.source_ip
                         << "] ("sv << map_id_sess.size() << " pending)"sv;

        ptr->second.async_insert_pin.salt = std::move(get_arg(args, "salt"));
        if (config::sunshine.flags[config::flag::PIN_STDIN]) {
          std::string pin;

          std::cout << "Please insert pin: "sv;
          std::getline(std::cin, pin);

          getservercert(ptr->second, tree, pin);
          return;
        } else {
#if defined SUNSHINE_TRAY && SUNSHINE_TRAY >= 1
          system_tray::update_tray_require_pin();
#endif
          ptr->second.async_insert_pin.response = std::move(response);

          fg.disable();
          return;
        }
      } else if (it->second == "pairchallenge"sv) {
        tree.put("root.paired", 1);
        tree.put("root.<xmlattr>.status_code", 200);
        return;
      }
    }

    auto sess_it = map_id_sess.find(uniqID);
    if (sess_it == std::end(map_id_sess)) {
      tree.put("root.<xmlattr>.status_code", 400);
      tree.put("root.<xmlattr>.status_message", "Invalid uniqueid");

      return;
    }

    if (it = args.find("clientchallenge"); it != std::end(args)) {
      auto challenge = util::from_hex_vec(it->second, true);
      clientchallenge(sess_it->second, tree, challenge);
    } else if (it = args.find("serverchallengeresp"); it != std::end(args)) {
      auto encrypted_response = util::from_hex_vec(it->second, true);
      serverchallengeresp(sess_it->second, tree, encrypted_response);
    } else if (it = args.find("clientpairingsecret"); it != std::end(args)) {
      auto pairingsecret = util::from_hex_vec(it->second, true);
      clientpairingsecret(sess_it->second, add_cert, tree, pairingsecret);
    } else {
      tree.put("root.<xmlattr>.status_code", 404);
      tree.put("root.<xmlattr>.status_message", "Invalid pairing request");
    }
  }

  void arm_pairing_window() {
    // Same map_id_sess_mutex as pair<T>()/pin() -- see its declaration comment. LEAF lock (never
    // acquires cert_state_mutex).
    std::lock_guard<std::mutex> lock(map_id_sess_mutex);
    arm_pairing_window_locked();
    BOOST_LOG(info) << "nvhttp: pairing window armed for "sv << PAIRING_WINDOW_DURATION.count() << "s"sv;
  }

  bool valid_pairing_pin(std::string_view pin) {
    return pin.size() == 4 && std::all_of(pin.begin(), pin.end(), [](char digit) {
      return digit >= '0' && digit <= '9';
    });
  }

  bool pin(std::string pin, std::string name, std::string target_uniqueid) {
    if (!valid_pairing_pin(pin)) {
      return false;
    }

    std::lock_guard<std::mutex> lock(map_id_sess_mutex);
    prune_stale_pairing_sessions_locked();

    const auto now = std::chrono::steady_clock::now();
    if (!window_active_locked(now)) {
      BOOST_LOG(warning) << "Pairing PIN refused because the pairing window is closed"sv;
      return false;
    }

    // The owner must select the requesting device, even when it is the only one listed.
    const auto it = map_id_sess.find(target_uniqueid);
    if (target_uniqueid.empty() || it == map_id_sess.end() || !session_eligible_locked(target_uniqueid, now)) {
      BOOST_LOG(warning) << "Pairing PIN refused because the selected request is unavailable"sv;
      return false;
    }

    auto &session = it->second;
    // A failed first phase erases the session. Keep its response alive so the client
    // receives the result. A repeated submission has no waiting response to answer.
    auto response = std::move(session.async_insert_pin.response);
    const bool has_http_response = response.has_left() && response.left();
    if (!has_http_response && !(response.has_right() && response.right())) {
      return false;
    }

    pt::ptree tree;
    const bool accepted = getservercert(session, tree, pin);
    if (accepted) {
      session.client.name = std::move(name);
    }

    std::ostringstream data;
    pt::write_xml(data, tree);
    if (has_http_response) {
      response.left()->write(data.str());
    } else {
      response.right()->write(data.str());
    }
    return accepted;
  }

  bool has_pending_pair_request() {
    // Same map_id_sess_mutex as pair<T>()/pin() -- see its declaration comment. LEAF lock (never
    // acquires cert_state_mutex), so this cannot introduce a new lock-ordering path.
    std::lock_guard<std::mutex> lock(map_id_sess_mutex);

    // Prune BEFORE reading .empty(), so a request that has already timed out (see
    // PAIRING_SESSION_TTL) never reports as pending -- matches the same prune-then-use ordering
    // pair<T>()'s "getservercert" phrase already uses.
    prune_stale_pairing_sessions_locked();

    return !map_id_sess.empty();
  }

  std::optional<bool> take_pair_outcome(const std::string &uniqueid) {
    // Different call context than fail_pair()/clientpairingsecret() (which write map_id_outcome
    // from the stack of pair<T>()) -- this is called from the XPC per-connection GCD queue, so it
    // must take map_id_sess_mutex itself, exactly like has_pending_pair_request()/list_pending_
    // pair_sessions() do for the same reason. LEAF lock (never acquires cert_state_mutex), so
    // this cannot introduce a new lock-ordering path.
    std::lock_guard<std::mutex> lock(map_id_sess_mutex);

    prune_stale_pairing_sessions_locked();

    auto it = map_id_outcome.find(uniqueid);
    if (it == map_id_outcome.end()) {
      // No terminal outcome recorded yet, an unknown uniqueid, or one already consumed by an
      // earlier call -- all three collapse to "keep waiting" for the caller, see this function's
      // doc comment in nvhttp.h.
      return std::nullopt;
    }

    bool outcome = it->second;

    // Single-consumption: this is a one-shot notification, not durable state -- erase on read so
    // a second poll never re-delivers the same outcome (or, worse, a stale one from a LATER,
    // unrelated pairing attempt that happens to reuse the same uniqueid).
    map_id_outcome.erase(it);
    map_id_outcome_created_at.erase(uniqueid);

    return outcome;
  }

  // ---------------------------------------------------------------------------------------------
  // Fix: best-effort reverse-hostname hint for the owner's pending-pairing picker. UNTRUSTED --
  // spoofable by anything that controls a PTR record for the source IP -- `source_ip` remains the
  // actual security-relevant identifier everywhere it's already used (the per-IP cap, the
  // mandatory-target check in pin()); this is purely a human-legible label so the owner doesn't
  // have to parse/click a bare IP. Guarded by its OWN mutex, deliberately never `map_id_sess_
  // mutex`: DNS I/O must never run while that lock is held (list_pending_pair_sessions() below
  // holds it for its own entire body), so a slow/hung PTR lookup can never stall pairing.
  // ---------------------------------------------------------------------------------------------

  // source_ip -> resolved hint (already ".local"-suffix-stripped, see strip_local_suffix() below).
  std::unordered_map<std::string, std::string> hostname_hint_cache;

  // Guards `hostname_hint_cache` and `hostname_lookup_inflight`.
  std::mutex hostname_hint_mutex;

  // source_ips with a reverse lookup already running on a detached background thread, so a burst
  // of polls for the SAME pending session (the XPC sheet's 2s timer, `pin.html`'s poll) doesn't
  // spawn a new thread per tick.
  std::unordered_set<std::string> hostname_lookup_inflight;

  /**
   * @brief Strip a trailing ".local"/".local." suffix, case-insensitively -- mirrors
   * `platf::get_host_name()`'s exact stripping logic (`src/platform/macos/misc.mm`) so both
   * surfaces treat the mDNS/Bonjour suffix the same way. Duplicated rather than shared because
   * `misc.mm` is a macOS-only Objective-C++ platform file and this file (`nvhttp.cpp`) is not.
   */
  std::string strip_local_suffix(std::string name) {
    // A reverse lookup can come back as an FQDN with a trailing root-label dot
    // ("studio-mac.local.") in addition to the plain "studio-mac.local" gethostname() form -- strip
    // that first so the ".local" match below (identical to misc.mm's) sees the same shape either
    // way.
    if (!name.empty() && name.back() == '.') {
      name.pop_back();
    }

    constexpr std::string_view suffix = ".local"sv;
    if (name.size() > suffix.size() &&
        std::equal(suffix.rbegin(), suffix.rend(), name.rbegin(), [](char a, char b) {
          return std::tolower(static_cast<unsigned char>(a)) == std::tolower(static_cast<unsigned char>(b));
        })) {
      name.erase(name.size() - suffix.size());
    }

    return name;
  }

  /**
   * @brief Blocking reverse-DNS lookup of `ip` via `getaddrinfo()`/`getnameinfo()`. Only ever
   * called on a detached background thread (see `hostname_hint_for_ip()`) -- never on a thread
   * serving a live request -- so a slow or hung resolver stalls nothing but its own throwaway
   * thread. Returns "" on any failure (invalid address, no PTR record, resolver error).
   */
  std::string reverse_dns_lookup(const std::string &ip) {
    addrinfo hints {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_flags = AI_NUMERICHOST;

    addrinfo *res = nullptr;
    if (getaddrinfo(ip.c_str(), nullptr, &hints, &res) != 0 || !res) {
      return {};
    }

    char host[NI_MAXHOST] {};
    int rc = getnameinfo(res->ai_addr, (socklen_t) res->ai_addrlen, host, sizeof(host), nullptr, 0, NI_NAMEREQD);
    freeaddrinfo(res);

    if (rc != 0) {
      return {};  // No PTR record, or the lookup otherwise failed -- an untrusted hint that just isn't there.
    }

    return strip_local_suffix(std::string(host));
  }

  /**
   * @brief Best-effort, NEVER-BLOCKING reverse-hostname hint for `ip`, for
   * `list_pending_pair_sessions()`'s `hostname_hint` field. The FIRST call for a given `ip` kicks
   * off `reverse_dns_lookup()` on a detached background thread (matching this codebase's existing
   * detach-and-forget pattern, e.g. `system_tray.cpp`'s tray thread) and returns "" immediately;
   * every call after that returns the cached result once the lookup lands (or "" if it resolved to
   * nothing usable). This function itself never performs I/O and never blocks its caller --
   * `list_pending_pair_sessions()` can call it while holding `map_id_sess_mutex` with no risk of
   * stalling pairing on DNS.
   * @note UNTRUSTED -- see this block's header comment.
   */
  std::string hostname_hint_for_ip(const std::string &ip) {
    {
      std::lock_guard<std::mutex> lock(hostname_hint_mutex);
      auto it = hostname_hint_cache.find(ip);
      if (it != hostname_hint_cache.end()) {
        return it->second;
      }
      if (hostname_lookup_inflight.count(ip)) {
        return {};  // Already resolving, not back yet -- avoid spawning a duplicate thread.
      }
      hostname_lookup_inflight.insert(ip);
    }

    std::thread([ip]() {
      std::string resolved = reverse_dns_lookup(ip);

      std::lock_guard<std::mutex> lock(hostname_hint_mutex);
      hostname_hint_cache[ip] = resolved;
      hostname_lookup_inflight.erase(ip);
    }).detach();

    return {};
  }

  nlohmann::json list_pending_pair_sessions() {
    // Same map_id_sess_mutex as pair<T>()/pin() -- see its declaration comment. LEAF lock (never
    // acquires cert_state_mutex).
    std::lock_guard<std::mutex> lock(map_id_sess_mutex);

    prune_stale_pairing_sessions_locked();

    auto now = std::chrono::steady_clock::now();

    // List requests that still need a PIN, in the order they arrived.
    std::vector<std::pair<std::string, std::chrono::steady_clock::time_point>> eligible;
    for (const auto &[id, session] : map_id_sess) {
      if (!session.pin_submitted_at && session_eligible_locked(id, now)) {
        eligible.emplace_back(id, map_id_sess_created_at.at(id));
      }
    }
    std::sort(eligible.begin(), eligible.end(), [](auto &a, auto &b) {
      return a.second < b.second;
    });

    // Info-level, and only when non-empty (a poll finding nothing is the normal steady state and
    // would otherwise spam the log every 2s) -- pairs with the registered-session log in pair<T>()
    // above so the owner's live test can confirm not just "the session arrived" but "the sheet's
    // next poll actually saw it as eligible".
    if (!eligible.empty()) {
      BOOST_LOG(info) << "nvhttp::list_pending_pair_sessions: "sv << eligible.size() << " eligible pending session(s)"sv;
    }

    nlohmann::json out = nlohmann::json::array();
    for (auto &[id, created_at] : eligible) {
      auto age_sec = std::chrono::duration_cast<std::chrono::seconds>(now - created_at).count();
      const std::string &source_ip = map_id_sess.at(id).source_ip;
      nlohmann::json entry;
      entry["uniqueid"] = id;
      entry["source_ip"] = source_ip;
      entry["age_sec"] = age_sec;
      // UNTRUSTED best-effort hint, "" until resolved/if unresolvable -- see hostname_hint_for_ip()
      // and this section's header comment. NEVER a substitute for source_ip: this is spoofable by
      // anything with a PTR record for that address.
      entry["hostname_hint"] = hostname_hint_for_ip(source_ip);
      // UNTRUSTED, attacker-controllable client-supplied label (see pair_session_t::
      // client_device_name's doc comment) -- display-only default for the owner's editable
      // device-name field, never a trust/selection signal, never a substitute for source_ip.
      entry["client_name"] = map_id_sess.at(id).client_device_name;
      out.push_back(std::move(entry));
    }
    return out;
  }

  template<class T>
  void serverinfo(std::shared_ptr<typename SimpleWeb::ServerBase<T>::Response> response, std::shared_ptr<typename SimpleWeb::ServerBase<T>::Request> request) {
    print_req<T>(request);

    int pair_status = 0;
    if constexpr (std::is_same_v<SunshineHTTPS, T>) {
      auto args = request->parse_query_string();
      auto clientID = args.find("uniqueid"s);

      if (clientID != std::end(args)) {
        pair_status = 1;
      }
    }

    auto local_endpoint = request->local_endpoint();

    pt::ptree tree;

    tree.put("root.<xmlattr>.status_code", 200);
    tree.put("root.hostname", config::nvhttp.sunshine_name);

    tree.put("root.appversion", VERSION);
    tree.put("root.GfeVersion", GFE_VERSION);
    tree.put("root.SkylightVersion", SKYLIGHT_VERSION);
    tree.put("root.SkylightSource", PROJECT_VERSION_COMMIT);
    // Additive, optional extension consumed by the Starlight client to show a
    // host-OS icon. Stock Moonlight clients look tags up by name and ignore
    // unknown ones, so this cannot affect protocol compatibility. Values the
    // client understands: macos | windows | linux.
    tree.put("root.HostOs", "macos");
#ifdef __APPLE__
    tree.put("root.AudioChannelCount", platf::macos::audio_channel_limit(config::audio.sink));
    tree.put("root.ClipboardImageSupported",1);
    tree.put("root.ClipboardImageMaxBytes",png_clipboard::max_bytes);
    tree.put("root.FileTransferSupported",1);
    tree.put("root.FileTransferChunkBytes",file_transfer::service::max_chunk_bytes);
#endif
    tree.put("root.uniqueid", http::unique_id);
    tree.put("root.HttpsPort", net::map_port(PORT_HTTPS));
    tree.put("root.ExternalPort", net::map_port(PORT_HTTP));
    tree.put("root.MaxLumaPixelsHEVC", video::active_hevc_mode > 1 ? "1869449984" : "0");

    // Only include the MAC address for requests sent from paired clients over HTTPS.
    // For HTTP requests, use a placeholder MAC address that Moonlight knows to ignore.
    if constexpr (std::is_same_v<SunshineHTTPS, T>) {
      tree.put("root.mac", platf::get_mac_address(net::addr_to_normalized_string(local_endpoint.address())));
    } else {
      tree.put("root.mac", "00:00:00:00:00:00");
    }

    // Moonlight clients track LAN IPv6 addresses separately from LocalIP which is expected to
    // always be an IPv4 address. If we return that same IPv6 address here, it will clobber the
    // stored LAN IPv4 address. To avoid this, we need to return an IPv4 address in this field
    // when we get a request over IPv6.
    //
    // HACK: We should return the IPv4 address of local interface here, but we don't currently
    // have that implemented. For now, we will emulate the behavior of GFE+GS-IPv6-Forwarder,
    // which returns 127.0.0.1 as LocalIP for IPv6 connections. Moonlight clients with IPv6
    // support know to ignore this bogus address.
    if (local_endpoint.address().is_v6() && !local_endpoint.address().to_v6().is_v4_mapped()) {
      tree.put("root.LocalIP", "127.0.0.1");
    } else {
      tree.put("root.LocalIP", net::addr_to_normalized_string(local_endpoint.address()));
    }

    uint32_t codec_mode_flags = SCM_H264;
    if (video::last_encoder_probe_supported_yuv444_for_codec[0]) {
      codec_mode_flags |= SCM_H264_HIGH8_444;
    }
    if (video::active_hevc_mode >= 2) {
      codec_mode_flags |= SCM_HEVC;
      if (video::last_encoder_probe_supported_yuv444_for_codec[1]) {
        codec_mode_flags |= SCM_HEVC_REXT8_444;
      }
    }
    if (video::active_hevc_mode >= 3) {
      codec_mode_flags |= SCM_HEVC_MAIN10;
      if (video::last_encoder_probe_supported_yuv444_for_codec[1]) {
        codec_mode_flags |= SCM_HEVC_REXT10_444;
      }
    }
    if (video::active_av1_mode >= 2) {
      codec_mode_flags |= SCM_AV1_MAIN8;
      if (video::last_encoder_probe_supported_yuv444_for_codec[2]) {
        codec_mode_flags |= SCM_AV1_HIGH8_444;
      }
    }
    if (video::active_av1_mode >= 3) {
      codec_mode_flags |= SCM_AV1_MAIN10;
      if (video::last_encoder_probe_supported_yuv444_for_codec[2]) {
        codec_mode_flags |= SCM_AV1_HIGH10_444;
      }
    }
    tree.put("root.ServerCodecModeSupport", codec_mode_flags);
#ifdef __APPLE__
    tree.put("root.DesktopScaleSupported", 1);
    tree.put("root.AdaptiveBitrateSupported", 1);
    tree.put("root.AutomaticBitrateTransport", 1);
#endif

    if (!config::nvhttp.external_ip.empty()) {
      tree.put("root.ExternalIP", config::nvhttp.external_ip);
    }

    auto current_appid = proc::proc.running();
    tree.put("root.PairStatus", pair_status);
    tree.put("root.currentgame", current_appid);
    tree.put("root.state", current_appid > 0 ? "SUNSHINE_SERVER_BUSY" : "SUNSHINE_SERVER_FREE");
    // Optional extensions: retain stock currentgame/state semantics for Moonlight,
    // while distinguishing a paused resumable target from an actual viewer.
    tree.put("root.ActiveStreams", rtsp_stream::active_session_count());
    tree.put("root.QuitAppOnDisconnect", config::sunshine.quit_app_on_disconnect ? 1 : 0);
#ifdef __APPLE__
    if constexpr (std::is_same_v<SunshineHTTPS, T>) {
      tree.put("root.KeyboardEnabled", config::input.keyboard ? 1 : 0);
      tree.put("root.MouseEnabled", config::input.mouse ? 1 : 0);
      tree.put("root.AccessibilityGranted", platf::preflight_accessibility_access() ? 1 : 0);
    }
    const auto capture = platf::macos::screen_capture_health().snapshot();
    tree.put("root.CaptureGeneration", capture.generation);
    tree.put("root.CaptureState", platf::macos::capture_state_name(capture.state));
    tree.put("root.CaptureFrames", capture.frames);
    tree.put("root.CaptureCachedFrames", capture.cached_frames);
#endif

    std::ostringstream data;

    pt::write_xml(data, tree);
    response->write(data.str(), {{"Connection", "close"}});
    response->close_connection_after_response = true;
  }

  nlohmann::json get_all_clients() {
    std::lock_guard<std::mutex> lock(cert_state_mutex);
    nlohmann::json named_cert_nodes = nlohmann::json::array();
    client_t &client = client_root;
    for (auto &named_cert : client.named_devices) {
      nlohmann::json named_cert_node;
      named_cert_node["name"] = named_cert.name;
      named_cert_node["uuid"] = named_cert.uuid;
      named_cert_nodes.push_back(named_cert_node);
    }

    return named_cert_nodes;
  }

  void applist(resp_https_t response, req_https_t request) {
    print_req<SunshineHTTPS>(request);

    pt::ptree tree;

    auto g = util::fail_guard([&]() {
      std::ostringstream data;

      pt::write_xml(data, tree);
      response->write(data.str());
      response->close_connection_after_response = true;
    });

    auto &apps = tree.add_child("root", pt::ptree {});

    apps.put("<xmlattr>.status_code", 200);

    for (auto &proc : proc::proc.get_apps()) {
      pt::ptree app;

      app.put("IsHdrSupported"s, video::active_hevc_mode == 3 ? 1 : 0);
      app.put("AppTitle"s, proc.name);
      app.put("ID", proc.id);

      apps.push_back(std::make_pair("App", std::move(app)));
    }
  }

  void launch(bool &host_audio, resp_https_t response, req_https_t request) {
    print_req<SunshineHTTPS>(request);

    pt::ptree tree;
    bool revert_display_configuration {false};
    bool virtual_display_created {false};
    std::shared_ptr<rtsp_stream::launch_session_t> launch_session;
    auto g = util::fail_guard([&]() {
      std::ostringstream data;

      if (tree.empty()) {
        BOOST_LOG(error) << EMPTY_PROPERTY_TREE_ERROR_MSG;
      }

      pt::write_xml(data, tree);
      response->write(data.str());
      response->close_connection_after_response = true;

      if (revert_display_configuration) {
        // Destroy the VD this request created before reverting display settings -- mirrors
        // the ordering of the normal teardown path (streaming_will_stop() then revert).
        if (virtual_display_created) {
          launch_session->pending.expire();
        }
        display_device::revert_configuration();
      }
    });

    auto args = request->parse_query_string();
    if (
      args.find("rikey"s) == std::end(args) ||
      args.find("rikeyid"s) == std::end(args) ||
      args.find("localAudioPlayMode"s) == std::end(args) ||
      args.find("appid"s) == std::end(args)
    ) {
      tree.put("root.resume", 0);
      tree.put("root.<xmlattr>.status_code", 400);
      tree.put("root.<xmlattr>.status_message", "Missing a required launch parameter");

      return;
    }

    auto appid = util::from_view(get_arg(args, "appid"));

    if (rtsp_stream::has_pending_launch()) {
      tree.put("root.<xmlattr>.status_code", 503);
      tree.put("root.<xmlattr>.status_message", "Another connection is being prepared. Retry shortly.");
      tree.put("root.resume", 0);
      tree.put("root.gamesession", 0);
      return;
    }

    auto current_appid = proc::proc.running();
    if (current_appid > 0) {
      tree.put("root.resume", 0);
      tree.put("root.<xmlattr>.status_code", 400);
      tree.put("root.<xmlattr>.status_message", "An app is already running on this host");

      return;
    }

    host_audio = util::from_view(get_arg(args, "localAudioPlayMode"));
    std::string validation_error;
    launch_session = make_launch_session(host_audio, args, validation_error);
    if (!launch_session) {
      tree.put("root.resume", 0);
      tree.put("root.<xmlattr>.status_code", 400);
      tree.put("root.<xmlattr>.status_message", validation_error);

      return;
    }

    request->with_socket([&](auto &socket) {
      crypto::x509_t peer {SSL_get1_peer_certificate(socket.native_handle())};
      if (auto device = authenticated_device_for_certificate(peer.get())) {
        launch_session->authenticated_device_uuid = device->uuid;
        launch_session->authenticated_device_name = device->name;
      }
    });

    // Stateless per-session cursor-compositing decision (see launch_session_t::client_side_cursor
    // in rtsp.h). This writes the same live `::display_cursor` global that config init
    // (main.cpp) and the Ctrl+Alt+Shift+N runtime toggle (input.cpp) already write, and that the
    // capture path (video.cpp -> display.mm) already re-reads every frame -- no restart needed.
    // Absence of the param is deliberately reset to the configured default rather than left alone:
    // otherwise a previous session's client_side_cursor=1 (e.g. from Starlight) would silently
    // leak into a following legacy/stock-client session that never asked for cursor suppression.
    if (launch_session->client_side_cursor) {
      display_cursor = !*launch_session->client_side_cursor;
      BOOST_LOG(info) << "launch: clientSideCursor="sv << (*launch_session->client_side_cursor ? "1"sv : "0"sv)
                       << " -> display_cursor="sv << (display_cursor ? "shown"sv : "hidden"sv) << " (per-session client declaration)"sv;
    } else {
      display_cursor = config::video.capture_cursor;
      BOOST_LOG(info) << "launch: no clientSideCursor param -> display_cursor="sv << (display_cursor ? "shown"sv : "hidden"sv) << " (reset to configured capture_cursor default)"sv;
    }

    if (rtsp_stream::session_count() == 0) {
      // The display should be restored in case something fails as there are no other sessions.
      revert_display_configuration = true;

#ifdef __APPLE__
      // Screen Recording is a prerequisite for everything below (encoder probing + virtual
      // display creation touch the capture path). Checked fresh on every request rather than
      // relying on the cached flag from daemon startup (misc.mm's platf::init() gate), so a
      // grant made while the daemon is already running takes effect on the very next launch
      // without a restart. This check is deliberately read-only; the native setup button owns
      // prompting. Without this preflight, a missing grant surfaced only as a
      // BOOST_LOG(error) line in the daemon's own log and a black stream for the client, with
      // no diagnostic reaching Moonlight itself (rr-skylight.md).
      if (!platf::preflight_screen_capture_access()) {
        tree.put("root.<xmlattr>.status_code", 503);
        tree.put("root.<xmlattr>.status_message", "Screen Recording permission not granted on the host. Open System Settings -> Privacy & Security -> Screen Recording and enable Moonwalk Host.");
        tree.put("root.gamesession", 0);

        return;
      }
#endif

      // We want to prepare display only if there are no active sessions at
      // the moment. This should be done before probing encoders as it could
      // change the active displays.
      display_device::configure_display(config::video, *launch_session);

      // Probe encoders again before streaming to ensure our chosen
      // encoder matches the active GPU (which could have changed
      // due to hotplugging, driver crash, primary monitor change,
      // or any number of other factors).
      if (video::probe_encoders()) {
        tree.put("root.<xmlattr>.status_code", 503);
        tree.put("root.<xmlattr>.status_message", "Failed to initialize video capture/encoding. Is a display connected and turned on?");
        tree.put("root.gamesession", 0);

        return;
      }

      // Create virtual display after encoder probing succeeds (macOS).
      // Must happen after probe_encoders() because the virtual display
      // can't be captured during the encoder test phase.
      if (!display_device::create_virtual_display(config::video, *launch_session)) {
        tree.put("root.<xmlattr>.status_code", 503);
        tree.put("root.<xmlattr>.status_message", "Moonwalk Host couldn't prepare the remote desktop. Try connecting again. If it still fails, open Moonwalk Host on the Mac and use Save Diagnostics.");
        tree.put("root.gamesession", 0);
        return;
      }
      virtual_display_created = true;
#ifdef __APPLE__
      const auto generation = platf::macos::pending_display_generation();
      if (generation != 0) {
        launch_session->pending.arm([generation] { platf::macos::release_pending_display(generation); });
      }
#endif
    }

    auto encryption_mode = net::encryption_mode_for_address(request->remote_endpoint().address());
    if (!launch_session->rtsp_cipher && encryption_mode == config::ENCRYPTION_MODE_MANDATORY) {
      BOOST_LOG(error) << "Rejecting client that cannot comply with mandatory encryption requirement"sv;

      tree.put("root.<xmlattr>.status_code", 403);
      tree.put("root.<xmlattr>.status_message", "Encryption is mandatory for this host but unsupported by the client");
      tree.put("root.gamesession", 0);

      return;
    }

    if (appid > 0) {
      auto err = proc::proc.execute((int) appid, launch_session);
      if (err) {
        tree.put("root.<xmlattr>.status_code", err);
        tree.put("root.<xmlattr>.status_message", "Failed to start the specified application");
        tree.put("root.gamesession", 0);

        return;
      }
    }

    tree.put("root.<xmlattr>.status_code", 200);
    tree.put(
      "root.sessionUrl0",
      std::format(
        "{}{}:{}",
        launch_session->rtsp_url_scheme,
        net::addr_to_url_escaped_string(request->local_endpoint().address()),
        static_cast<int>(net::map_port(rtsp_stream::RTSP_SETUP_PORT))
      )
    );
    tree.put("root.gamesession", 1);

    if (!rtsp_stream::launch_session_raise(launch_session)) {
      tree.put("root.<xmlattr>.status_code", 503);
      tree.put("root.<xmlattr>.status_message", "Another connection is being prepared. Retry shortly.");
      tree.put("root.resume", 0);
      tree.put("root.gamesession", 0);
      return;
    }

    // Stream was started successfully, we will revert the config when the app or session terminates
    revert_display_configuration = false;
  }

  void resume(bool &host_audio, resp_https_t response, req_https_t request) {
    print_req<SunshineHTTPS>(request);

    pt::ptree tree;
    bool virtual_display_created {false};
    std::shared_ptr<rtsp_stream::launch_session_t> launch_session;
    auto g = util::fail_guard([&]() {
      std::ostringstream data;

      if (tree.empty()) {
        BOOST_LOG(error) << EMPTY_PROPERTY_TREE_ERROR_MSG;
      }

      pt::write_xml(data, tree);
      response->write(data.str());
      response->close_connection_after_response = true;

      if (virtual_display_created) {
        launch_session->pending.expire();
      }
    });

    if (rtsp_stream::has_pending_launch()) {
      tree.put("root.<xmlattr>.status_code", 503);
      tree.put("root.<xmlattr>.status_message", "Another connection is being prepared. Retry shortly.");
      tree.put("root.resume", 0);
      tree.put("root.gamesession", 0);
      return;
    }

    auto current_appid = proc::proc.running();
    if (current_appid == 0) {
      tree.put("root.resume", 0);
      tree.put("root.<xmlattr>.status_code", 503);
      tree.put("root.<xmlattr>.status_message", "No running app to resume");

      return;
    }

    auto args = request->parse_query_string();
    if (
      args.find("rikey"s) == std::end(args) ||
      args.find("rikeyid"s) == std::end(args)
    ) {
      tree.put("root.resume", 0);
      tree.put("root.<xmlattr>.status_code", 400);
      tree.put("root.<xmlattr>.status_message", "Missing a required resume parameter");

      return;
    }

    // Newer Moonlight clients send localAudioPlayMode on /resume too,
    // so we should use it if it's present in the args and there are
    // no active sessions we could be interfering with.
    const bool no_active_sessions {rtsp_stream::session_count() == 0};
    if (no_active_sessions && args.find("localAudioPlayMode"s) != std::end(args)) {
      host_audio = util::from_view(get_arg(args, "localAudioPlayMode"));
    }
    std::string validation_error;
    launch_session = make_launch_session(host_audio, args, validation_error);
    if (!launch_session) {
      tree.put("root.resume", 0);
      tree.put("root.<xmlattr>.status_code", 400);
      tree.put("root.<xmlattr>.status_message", validation_error);

      return;
    }

    request->with_socket([&](auto &socket) {
      crypto::x509_t peer {SSL_get1_peer_certificate(socket.native_handle())};
      if (auto device = authenticated_device_for_certificate(peer.get())) {
        launch_session->authenticated_device_uuid = device->uuid;
        launch_session->authenticated_device_name = device->name;
      }
    });

    // Stateless per-session cursor-compositing decision -- see the matching block in launch()
    // above for the full rationale (same rule applies identically on resume).
    if (launch_session->client_side_cursor) {
      display_cursor = !*launch_session->client_side_cursor;
      BOOST_LOG(info) << "resume: clientSideCursor="sv << (*launch_session->client_side_cursor ? "1"sv : "0"sv)
                       << " -> display_cursor="sv << (display_cursor ? "shown"sv : "hidden"sv) << " (per-session client declaration)"sv;
    } else {
      display_cursor = config::video.capture_cursor;
      BOOST_LOG(info) << "resume: no clientSideCursor param -> display_cursor="sv << (display_cursor ? "shown"sv : "hidden"sv) << " (reset to configured capture_cursor default)"sv;
    }

    if (no_active_sessions) {
#ifdef __APPLE__
      // See the matching preflight in launch() above for the full rationale.
      if (!platf::preflight_screen_capture_access()) {
        tree.put("root.resume", 0);
        tree.put("root.<xmlattr>.status_code", 503);
        tree.put("root.<xmlattr>.status_message", "Screen Recording permission not granted on the host. Open System Settings -> Privacy & Security -> Screen Recording and enable Moonwalk Host.");

        return;
      }
#endif

      // We want to prepare display only if there are no active sessions at
      // the moment. This should be done before probing encoders as it could
      // change the active displays.
      display_device::configure_display(config::video, *launch_session);

      // Probe encoders again before streaming to ensure our chosen
      // encoder matches the active GPU (which could have changed
      // due to hotplugging, driver crash, primary monitor change,
      // or any number of other factors).
      if (video::probe_encoders()) {
        tree.put("root.resume", 0);
        tree.put("root.<xmlattr>.status_code", 503);
        tree.put("root.<xmlattr>.status_message", "Failed to initialize video capture/encoding. Is a display connected and turned on?");

        return;
      }

      // Create virtual display after encoder probing succeeds (macOS)
      if (!display_device::create_virtual_display(config::video, *launch_session)) {
        tree.put("root.<xmlattr>.status_code", 503);
        tree.put("root.<xmlattr>.status_message", "Moonwalk Host couldn't prepare the remote desktop. Try connecting again. If it still fails, open Moonwalk Host on the Mac and use Save Diagnostics.");
        tree.put("root.resume", 0);
        return;
      }
      virtual_display_created = true;
#ifdef __APPLE__
      const auto generation = platf::macos::pending_display_generation();
      if (generation != 0) {
        launch_session->pending.arm([generation] { platf::macos::release_pending_display(generation); });
      }
#endif
    }

    auto encryption_mode = net::encryption_mode_for_address(request->remote_endpoint().address());
    if (!launch_session->rtsp_cipher && encryption_mode == config::ENCRYPTION_MODE_MANDATORY) {
      BOOST_LOG(error) << "Rejecting client that cannot comply with mandatory encryption requirement"sv;

      tree.put("root.<xmlattr>.status_code", 403);
      tree.put("root.<xmlattr>.status_message", "Encryption is mandatory for this host but unsupported by the client");
      tree.put("root.gamesession", 0);

      return;
    }

    tree.put("root.<xmlattr>.status_code", 200);
    tree.put(
      "root.sessionUrl0",
      std::format(
        "{}{}:{}",
        launch_session->rtsp_url_scheme,
        net::addr_to_url_escaped_string(request->local_endpoint().address()),
        static_cast<int>(net::map_port(rtsp_stream::RTSP_SETUP_PORT))
      )
    );
    tree.put("root.resume", 1);

    if (!rtsp_stream::launch_session_raise(launch_session)) {
      tree.put("root.<xmlattr>.status_code", 503);
      tree.put("root.<xmlattr>.status_message", "Another connection is being prepared. Retry shortly.");
      tree.put("root.resume", 0);
      tree.put("root.gamesession", 0);
      return;
    }

    // Stream was resumed successfully -- the guard always runs (it writes the response), so
    // the flag alone must gate the destroy above; disarm it here (after the raise, so a throw
    // from raise still leaves the flag armed and the VD gets torn down by the guard) so a
    // successful resume does not tear down the VD it just (re)confirmed.
    virtual_display_created = false;
  }

  void cancel(resp_https_t response, req_https_t request) {
    print_req<SunshineHTTPS>(request);

    pt::ptree tree;
    auto g = util::fail_guard([&]() {
      std::ostringstream data;

      pt::write_xml(data, tree);
      response->write(data.str());
      response->close_connection_after_response = true;
    });

    tree.put("root.cancel", 1);
    tree.put("root.<xmlattr>.status_code", 200);

    rtsp_stream::terminate_sessions();

    if (proc::proc.running() > 0) {
      // Same teardown gate as rtsp.cpp's quit_app_on_disconnect block (design:
      // docs/design/vd-lifecycle.md §2A, Stage 3) — `terminate_sessions()` above already runs
      // the same synchronous session::join() -> streaming_will_stop() path (blocking on VD
      // ACK+reap since S2), so this is expected to resolve immediately; kept as
      // defense-in-depth, always bounded, never hangs this request on VD teardown.
      if (platf::vd_teardown_wait(3s)) {
        BOOST_LOG(debug) << "VD teardown confirmed before app terminate"sv;
      } else {
        BOOST_LOG(warning) << "VD teardown not confirmed within 3s — proceeding (bounded)"sv;
      }
      proc::proc.terminate();
    }

    // The config needs to be reverted regardless of whether "proc::proc.terminate()" was called or not.
    display_device::revert_configuration();
  }

  void appasset(resp_https_t response, req_https_t request) {
    print_req<SunshineHTTPS>(request);

    auto args = request->parse_query_string();
    auto app_image = proc::proc.get_app_image((int) util::from_view(get_arg(args, "appid")));

    std::ifstream in(app_image, std::ios::binary);
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "image/png");
    response->write(SimpleWeb::StatusCode::success_ok, in, headers);
    response->close_connection_after_response = true;
  }

#ifdef __APPLE__
  // The cursor image is small, but its position stays client-side. Keep a
  // change-driven, certificate-authenticated request outstanding so shape
  // transitions do not wait for video while pointer movement stays instant.
  constexpr auto kCursorPollInterval = std::chrono::milliseconds(16);
  constexpr auto kCursorWaitBudget = std::chrono::seconds(5);

  void cursor_write_image(const resp_https_t &response, const platf::cursor_image_t &image) {
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "image/png");
    headers.emplace("X-Skylight-Cursor-State",
                    std::format("{:016x},{},{},{},{}", image.hash, image.hot_x, image.hot_y,
                                image.point_width, image.point_height));
    response->write(SimpleWeb::StatusCode::success_ok, image.png, headers);
    response->close_connection_after_response = true;
  }

  void cursor_poll_tick(resp_https_t response, std::uint64_t since,
                        std::chrono::steady_clock::time_point deadline,
                        std::shared_ptr<boost::asio::steady_timer> timer) {
    timer->expires_after(kCursorPollInterval);
    timer->async_wait([response = std::move(response), since, deadline, timer](const SimpleWeb::error_code &ec) {
      if (ec) {
        return;
      }
      if (rtsp_stream::session_count() <= 0) {
        response->write(SimpleWeb::StatusCode::server_error_service_unavailable);
        response->close_connection_after_response = true;
        return;
      }
      auto current = platf::capture_system_cursor(false);
      if (current && current->hash != since) {
        auto image = platf::capture_system_cursor(true);
        if (image) {
          cursor_write_image(response, *image);
          return;
        }
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        response->write(SimpleWeb::StatusCode::success_no_content);
        response->close_connection_after_response = true;
        return;
      }
      cursor_poll_tick(response, since, deadline, timer);
    });
  }

  void getCursor(std::shared_ptr<SimpleWeb::io_context> io_service,
                 resp_https_t response, req_https_t request) {
    // This route is HTTPS/mTLS only; never mirror it to the plain HTTP server.
    if (rtsp_stream::session_count() <= 0) {
      response->write(SimpleWeb::StatusCode::server_error_service_unavailable);
      response->close_connection_after_response = true;
      return;
    }

    auto args = request->parse_query_string();
    std::string token = get_arg(args, "since", "0");
    std::uint64_t since = 0;
    if (token.size() <= 16) {
      auto parsed = std::from_chars(token.data(), token.data() + token.size(), since, 16);
      if (parsed.ec != std::errc() || parsed.ptr != token.data() + token.size()) {
        since = 0;
      }
    }

    auto current = platf::capture_system_cursor(false);
    if (current && current->hash != since) {
      auto image = platf::capture_system_cursor(true);
      if (image) {
        cursor_write_image(response, *image);
        return;
      }
    }
    auto timer = std::make_shared<boost::asio::steady_timer>(*io_service);
    cursor_poll_tick(response, since,
                     std::chrono::steady_clock::now() + kCursorWaitBudget, timer);
  }
#endif

  /**
   * @brief Shared preconditions for both clipboard verbs: feature toggle + active-session gate.
   * @details Never logs clipboard content -- only writes the terse status responses below.
   *          `?type` must be exactly "text" (v1 is text/UTF-8 only, per design). On any failure,
   *          writes the appropriate error response and returns `false`; callers must not proceed.
   * @return `true` if both preconditions pass and `type=text` was requested.
   */
  bool clipboard_preconditions_ok(resp_https_t &response, req_https_t &request, const args_t &args) {
    if (!config::sunshine.clipboard_sync) {
      response->write(SimpleWeb::StatusCode::client_error_forbidden);
      response->close_connection_after_response = true;
      return false;
    }

    // Phase 1 gate (design doc §1.3): global "is anything streaming" check, not per-client. This
    // shrinks the exposure window to "while a stream is active" without needing per-request cert
    // identity plumbing that nvhttp doesn't have today.
    if (rtsp_stream::session_count() <= 0) {
      response->write(SimpleWeb::StatusCode::server_error_service_unavailable);
      response->close_connection_after_response = true;
      return false;
    }

    const auto requested_type=get_arg(args,"type","");
#ifdef __APPLE__
    const bool supported_type=requested_type=="text" || requested_type=="auto" || requested_type=="png";
#else
    const bool supported_type=requested_type=="text";
#endif
    if (!supported_type) {
      response->write(SimpleWeb::StatusCode::client_error_bad_request);
      response->close_connection_after_response = true;
      return false;
    }

    return true;
  }

  // Long-poll tuning (design doc "PART 1 -- Recommended transport + threading", §1.2). The tick
  // interval is a cheap integer re-check; the total budget sits far under the server's 300 s
  // `timeout_content` (server_http.hpp), so a held connection is never reaped mid-wait by that
  // unrelated watchdog.
  constexpr auto kClipboardPollInterval = std::chrono::milliseconds(200);
  constexpr auto kClipboardWaitBudget = std::chrono::seconds(25);

  /**
   * @brief Writes a 200 response carrying pasteboard text + the change count that produced it.
   * @details Never logs clipboard content -- only the byte count. Shared by the immediate-reply
   *          path and the long-poll advance path in `getClipboard`/`clipboard_long_poll_tick`, so
   *          there is exactly one place that shapes a "here is the content" response.
   */
  void clipboard_write_content(const resp_https_t &response, std::int64_t change_count, std::string content, bool image=false) {
    BOOST_LOG(debug) << "clipboard: served GET ("sv << content.size() << " bytes, change="sv << change_count << ")"sv;

    SimpleWeb::CaseInsensitiveMultimap headers;
    bool png=false;
#ifdef __APPLE__
    if(image) {
      auto captured=platf::get_clipboard_png();
      if(captured.too_large) {
        headers.emplace("Content-Type","text/plain");
        headers.emplace("X-Skylight-Clipboard-Change",std::to_string(change_count));
        response->write(static_cast<SimpleWeb::StatusCode>(413),"Clipboard image exceeds the 4 MiB / 4096 pixel limit",headers);
        response->close_connection_after_response=true;return;
      }
      if(!captured.png.empty()){content=std::move(captured.png);png=true;}
    }
#endif
    headers.emplace("Content-Type",png?"image/png":"text/plain; charset=utf-8");
    headers.emplace("X-Skylight-Clipboard-Change", std::to_string(change_count));
    response->write(SimpleWeb::StatusCode::success_ok, content, headers);
    response->close_connection_after_response = true;
  }

  /**
   * @brief Writes a 204 response for a long-poll that timed out with no clipboard change.
   * @details Never touches/logs clipboard content -- there is none to report.
   */
  void clipboard_write_no_change(const resp_https_t &response, std::int64_t change_count) {
    BOOST_LOG(debug) << "clipboard: long-poll budget elapsed, no change (change="sv << change_count << ")"sv;

    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("X-Skylight-Clipboard-Change", std::to_string(change_count));
    response->write(SimpleWeb::StatusCode::success_no_content, headers);
    response->close_connection_after_response = true;
  }

  /**
   * @brief Async long-poll tick: re-checks `NSPasteboard.changeCount` on a ~200 ms
   *        `asio::steady_timer`, without ever blocking the single nvhttp io_service thread (design
   *        doc §1.2 feasibility verdict). Recurses via a fresh `async_wait` until either the
   *        pasteboard advances past `since` or `deadline` elapses -- the io_service thread returns
   *        to the event loop between every tick, so no other route (pairing, launch, resume,
   *        serverinfo, ...) is ever starved while a clipboard poll is outstanding.
   * @details The captured `response` is Simple-Web-Server's deferred-response handle: the
   *          underlying `Response` flushes to the socket only when the last `shared_ptr` reference
   *          to it is released (custom deleter, `send_on_delete`, `server_http.hpp`). Holding a
   *          copy of it alive inside this timer's callback chain *is* the deferral; letting it (and
   *          `timer`) fall out of scope right after `clipboard_write_content`/
   *          `clipboard_write_no_change` is what allows the flush to happen exactly once. If the
   *          client has disconnected mid-wait, that eventual flush is a safe no-op --
   *          Simple-Web-Server's internal `handler_runner->continue_lock()` guards the write and
   *          silently declines it once the connection's `ScopeRunner` has been torn down; nothing
   *          here can crash on a dead socket. `timer` is re-armed in place every tick (never
   *          reallocated), so nothing leaks across the wait.
   */
  void clipboard_long_poll_tick(resp_https_t response, std::int64_t since, std::chrono::steady_clock::time_point deadline, std::shared_ptr<boost::asio::steady_timer> timer, bool image=false) {
    timer->expires_after(kClipboardPollInterval);
    timer->async_wait([response = std::move(response), since, deadline, timer, image](const SimpleWeb::error_code &ec) {
      if (ec) {
        // Timer cancelled (server shutting down, socket torn down, ...). Let `response` fall out
        // of scope here -- the resulting flush attempt is a safe no-op (see doc comment above).
        return;
      }

      std::int64_t current = platf::clipboard_change_count();
      if (current != since) {
        clipboard_write_content(response, current, platf::get_clipboard(),image);
        return;
      }

      if (std::chrono::steady_clock::now() >= deadline) {
        clipboard_write_no_change(response, current);
        return;
      }

      clipboard_long_poll_tick(response, since, deadline, timer,image);
    });
  }

  /**
   * @brief `GET /actions/clipboard?type=text&since=<changeCount>` -- returns the host pasteboard's
   *        current text, long-polling (async, non-blocking) when it has not changed since `since`.
   * @details HTTPS-only (registered on `https_server` alone, never `http_server` -- see `start()`);
   *          the mTLS pinned-cert handshake is the entire auth boundary for this route (§1.1 of the
   *          clipboard design). Body is raw UTF-8 text, no JSON/base64 envelope. Never logs
   *          clipboard content -- only the byte count.
   *
   *          Behavior (design doc §1.2): if the current `NSPasteboard.changeCount` differs from
   *          `since` -- or `since` is absent/0 and the pasteboard already holds non-empty text --
   *          responds immediately with 200 + text + `X-Skylight-Clipboard-Change`. Otherwise defers
   *          the response (`clipboard_long_poll_tick`) for up to ~25 s, polling the change count on
   *          an async `steady_timer` bound to the server's own io_service so the single nvhttp
   *          io_service thread is never blocked; on timeout with no change, responds 204.
   *
   *          All gates (`clipboard_preconditions_ok`: feature toggle, active-session, `type=text`)
   *          are applied before any of this -- a denied request never holds a connection open.
   *          `io_service` is captured at route-registration time from the (single-threaded)
   *          `https_server` this route is registered on.
   */
  void getClipboard(std::shared_ptr<SimpleWeb::io_context> io_service, resp_https_t response, req_https_t request) {
    print_req<SunshineHTTPS>(request);

    auto args = request->parse_query_string();
    if (!clipboard_preconditions_ok(response, request, args)) {
      return;
    }

    const bool image=get_arg(args,"type","")=="auto" || get_arg(args,"type","")=="png";
    std::int64_t since = util::from_view(get_arg(args, "since", "0"));
    std::int64_t current = platf::clipboard_change_count();

    if (current != since) {
      clipboard_write_content(response, current, platf::get_clipboard(),image);
      return;
    }

    if (since == 0) {
      // No baseline from the client (fresh session): a non-empty pasteboard is worth reporting
      // right away rather than making the very first request sit out a full long-poll cycle.
      std::string content = platf::get_clipboard();
      bool have_image=false;
#ifdef __APPLE__
      if(image) {const auto candidate=platf::get_clipboard_png();have_image=candidate.too_large || !candidate.png.empty();}
#endif
      if (!content.empty() || have_image) {
        clipboard_write_content(response, current, std::move(content),image);
        return;
      }
    }

    auto deadline = std::chrono::steady_clock::now() + kClipboardWaitBudget;
    auto timer = std::make_shared<boost::asio::steady_timer>(*io_service);
    clipboard_long_poll_tick(std::move(response), since, deadline, std::move(timer),image);
  }

  /**
   * @brief `POST /actions/clipboard?type=text` -- sets the host pasteboard from the request body.
   * @details HTTPS-only (see `getClipboard` doc comment above -- same auth boundary). Body size is
   *          already capped at the transport layer by `https_server.config.max_request_streambuf_size`
   *          (1 MiB, set in `start()`), so no additional size check is needed here. Never logs
   *          clipboard content -- only the byte count.
   */
  void setClipboard(resp_https_t response, req_https_t request) {
    print_req<SunshineHTTPS>(request);

    auto args = request->parse_query_string();
    if (!clipboard_preconditions_ok(response, request, args)) {
      return;
    }

    std::string content = request->content.string();

    BOOST_LOG(debug) << "clipboard: received POST ("sv << content.size() << " bytes)"sv;

    bool applied=false;
    const bool png=get_arg(args,"type","")=="png";
    if(content.size()>(png?png_clipboard::max_bytes:1024*1024)) {
      response->write(static_cast<SimpleWeb::StatusCode>(413),"Clipboard content exceeds the supported limit");
      response->close_connection_after_response=true;return;
    }
#ifdef __APPLE__
    if(png)applied=platf::set_clipboard_png(content);
    else
#endif
    applied=platf::set_clipboard(content);
    if (!applied) {
      response->write(SimpleWeb::StatusCode::server_error_internal_server_error);
      response->close_connection_after_response = true;
      return;
    }

    response->write(SimpleWeb::StatusCode::success_ok);
    response->close_connection_after_response = true;
  }

#ifdef __APPLE__
  void transferFiles(resp_https_t response,req_https_t request) {
    SimpleWeb::CaseInsensitiveMultimap error_headers;error_headers.emplace("Content-Type","text/plain; charset=utf-8");error_headers.emplace("Connection","close");
    auto query=request->parse_query_string();
    file_transfer::args_t args;for(const auto &entry:query)args.emplace(entry.first,entry.second);
    std::string owner;
    request->with_socket([&](auto &socket) {
      crypto::x509_t peer {SSL_get1_peer_certificate(socket.native_handle())};
      if(auto device=authenticated_device_for_certificate(peer.get()))owner=device->uuid;
    });
    const auto active=rtsp_stream::active_session_snapshot();
    if(owner.empty() || (args["op"]!="cancel" && (!active || active->device_uuid!=owner))) {
      response->write(SimpleWeb::StatusCode::client_error_forbidden,"File transfer requires this device's active stream",error_headers);response->close_connection_after_response=true;return;
    }
    const auto session_scope=active?std::to_string(active->session_id):std::string{};
    struct transfer_runtime {
      // Workers are destroyed/joined before their service and expiry owner.
      file_transfer::service files {std::getenv("HOME")?std::getenv("HOME"):""};
      std::atomic<unsigned> queued {0};
      boost::asio::thread_pool workers {2};
    };
    static transfer_runtime runtime;
    if(runtime.queued.fetch_add(1)>=8) {--runtime.queued;response->write(SimpleWeb::StatusCode::server_error_service_unavailable,"Transfers are busy; retry shortly",error_headers);response->close_connection_after_response=true;return;}
    auto body=request->content.string();
    boost::asio::post(runtime.workers,[response=std::move(response),args=std::move(args),body=std::move(body),owner=std::move(owner),session_scope,error_headers] {
      try {
        const auto current=rtsp_stream::active_session_snapshot();
        if(args.at("op")!="cancel" && (!current || current->device_uuid!=owner || std::to_string(current->session_id)!=session_scope)) {
          if(auto id=args.find("id");id!=args.end())runtime.files.request(owner,{{"op","cancel"},{"id",id->second}});
          response->write(SimpleWeb::StatusCode::client_error_forbidden,"Streaming session changed; start the transfer again",error_headers);
          response->close_connection_after_response=true;--runtime.queued;return;
        }
        auto result=runtime.files.request(owner,args,body,session_scope);
        SimpleWeb::CaseInsensitiveMultimap headers;headers.emplace("Content-Type",result.type);headers.emplace("Connection","close");
        response->write(static_cast<SimpleWeb::StatusCode>(result.status),result.body,headers);
      } catch(...) {
        response->write(SimpleWeb::StatusCode::server_error_internal_server_error,"File transfer failed; retry after checking the destination",error_headers);
      }
      response->close_connection_after_response=true;--runtime.queued;
    });
  }
#endif

  void setup(const std::string &pkey, const std::string &cert) {
    conf_intern.pkey = pkey;
    conf_intern.servercert = cert;
  }

  void start() {
    platf::set_thread_name("nvhttp");
    auto shutdown_event = mail::man->event<bool>(mail::shutdown);

    auto port_http = net::map_port(PORT_HTTP);
    auto port_https = net::map_port(PORT_HTTPS);
    auto address_family = net::af_from_enum_string(config::sunshine.address_family);

    bool clean_slate = config::sunshine.flags[config::flag::FRESH_STATE];

    if (!clean_slate) {
      // Uncontended at this point (called before the ssl/tcp threads are spawned below), but
      // load_state() assumes the lock is already held (see its declaration comment), so take it
      // here for consistency with every other call site.
      std::lock_guard<std::mutex> lock(cert_state_mutex);
      load_state();
    }

    auto pkey = file_handler::read_file(config::nvhttp.pkey.c_str());
    auto cert = file_handler::read_file(config::nvhttp.cert.c_str());
    setup(pkey, cert);

    auto add_cert = std::make_shared<safe::queue_t<crypto::x509_t>>(30);

    // resume doesn't always get the parameter "localAudioPlayMode"
    // launch will store it in host_audio
    bool host_audio {};

    https_server_t https_server {config::nvhttp.cert, config::nvhttp.pkey};
    http_server_t http_server;

    // Verify certificates after establishing connection
    https_server.verify = [add_cert](SSL *ssl) {
      crypto::x509_t x509 {
#if OPENSSL_VERSION_MAJOR >= 3
        SSL_get1_peer_certificate(ssl)
#else
        SSL_get_peer_certificate(ssl)
#endif
      };
      if (!x509) {
        BOOST_LOG(info) << "unknown -- denied"sv;
        return 0;
      }

      int verified = 0;

      auto fg = util::fail_guard([&]() {
        char subject_name[256];

        X509_NAME_oneline(X509_get_subject_name(x509.get()), subject_name, sizeof(subject_name));

        BOOST_LOG(debug) << subject_name << " -- "sv << (verified ? "verified"sv : "denied"sv);
      });

      const char *err_str;
      {
        // See cert_state_mutex's declaration comment. Scoped tightly around the
        // add()+verify() sequence only; no network I/O happens under the lock.
        std::lock_guard<std::mutex> lock(cert_state_mutex);

        while (add_cert->peek()) {
          auto cert = add_cert->pop();
          // A device may have been unpaired before its first TLS request.
          if (resolve_paired_device(cert.get(), client_root.named_devices)) {
            cert_chain.add(std::move(cert));
          }
        }

        err_str = cert_chain.verify(x509.get());
      }

      if (err_str) {
        BOOST_LOG(warning) << "SSL Verification error :: "sv << err_str;

        return verified;
      }

      verified = 1;

      return verified;
    };

    https_server.on_verify_failed = [](resp_https_t resp, req_https_t req) {
      pt::ptree tree;
      auto g = util::fail_guard([&]() {
        std::ostringstream data;

        pt::write_xml(data, tree);
        resp->write(data.str());
        resp->close_connection_after_response = true;
      });

      tree.put("root.<xmlattr>.status_code"s, 401);
      tree.put("root.<xmlattr>.query"s, req->path);
      tree.put("root.<xmlattr>.status_message"s, "The client is not authorized. Certificate verification failed."s);
    };

    https_server.default_resource["GET"] = not_found<SunshineHTTPS>;
    https_server.resource["^/serverinfo$"]["GET"] = serverinfo<SunshineHTTPS>;
    https_server.resource["^/pair$"]["GET"] = [&add_cert](auto resp, auto req) {
      pair<SunshineHTTPS>(add_cert, resp, req);
    };
    https_server.resource["^/applist$"]["GET"] = applist;
    https_server.resource["^/appasset$"]["GET"] = appasset;
    https_server.resource["^/launch$"]["GET"] = [&host_audio](auto resp, auto req) {
      launch(host_audio, resp, req);
    };
    https_server.resource["^/resume$"]["GET"] = [&host_audio](auto resp, auto req) {
      resume(host_audio, resp, req);
    };
    https_server.resource["^/cancel$"]["GET"] = cancel;
    // Native in-stream clipboard (see design doc). Registered on https_server ONLY -- the mTLS
    // pinned-cert handshake (verify lambda above) is the entire auth boundary; a mirror route on
    // http_server (the unauthenticated plain-HTTP listener, below) would defeat that boundary
    // entirely and MUST NOT be added.
    https_server.resource["^/actions/clipboard$"]["GET"] = [&https_server](auto resp, auto req) {
      getClipboard(https_server.io_service, resp, req);
    };
    https_server.resource["^/actions/clipboard$"]["POST"] = setClipboard;
#ifdef __APPLE__
    https_server.resource["^/actions/files$"]["GET"] = transferFiles;
    https_server.resource["^/actions/files$"]["POST"] = transferFiles;
#endif
#ifdef __APPLE__
    https_server.resource["^/actions/cursor$"]["GET"] = [&https_server](auto resp, auto req) {
      getCursor(https_server.io_service, resp, req);
    };
#endif

    https_server.config.reuse_address = true;
    https_server.config.address = net::get_bind_address(address_family);
    https_server.config.port = port_https;
    // Simple-Web-Server defaults max_request_streambuf_size to SIZE_MAX (no cap at all), and these
    // authenticated clipboard and file routes also accept bounded binary uploads.
    // Allow the 4 MiB PNG payload plus framing; file chunks remain limited to 1 MiB.
    https_server.config.max_request_streambuf_size = 8 * 1024 * 1024;

    http_server.default_resource["GET"] = not_found<SimpleWeb::HTTP>;
    http_server.resource["^/serverinfo$"]["GET"] = serverinfo<SimpleWeb::HTTP>;
    http_server.resource["^/pair$"]["GET"] = [&add_cert](auto resp, auto req) {
      pair<SimpleWeb::HTTP>(add_cert, resp, req);
    };

    http_server.config.reuse_address = true;
    http_server.config.address = net::get_bind_address(address_family);
    http_server.config.port = port_http;
    // The plain-HTTP listener only serves serverinfo/pair and keeps its smaller cap.
    http_server.config.max_request_streambuf_size = 1 * 1024 * 1024;

    auto accept_and_run = [&](auto *http_server) {
      const auto kind = http_server->config.port == port_https ? net::listener_kind::https : net::listener_kind::http;
      net::set_listener_ready(kind, false);
      auto stopped = util::fail_guard([&] { net::set_listener_ready(kind, false); });
      try {
        std::string name = "nvhttp::" + std::to_string(http_server->config.port);
        platf::set_thread_name(name);
        http_server->start([kind](unsigned short) { net::set_listener_ready(kind, true); });
      } catch (boost::system::system_error &err) {
        // It's possible the exception gets thrown after calling http_server->stop() from a different thread
        if (shutdown_event->peek()) {
          return;
        }

        BOOST_LOG(fatal) << "Couldn't start http server on ports ["sv << port_https << ", "sv << port_https << "]: "sv << err.what();
        shutdown_event->raise(true);
        return;
      }
    };
    std::thread ssl {accept_and_run, &https_server};
    std::thread tcp {accept_and_run, &http_server};

    // Wait for any event
    shutdown_event->view();

    https_server.stop();
    http_server.stop();

    ssl.join();
    tcp.join();
  }

  bool erase_all_clients() {
    std::lock_guard<std::mutex> lock(cert_state_mutex);
    if (!save_state({})) return false;
    adopt_client_state({});
    return true;
  }

  static std::optional<authenticated_device_t> resolve_paired_device(const X509 *certificate, const std::vector<named_cert_t> &devices) {
    if (!certificate) {
      return std::nullopt;
    }
    for (const auto &device : devices) {
      auto paired = crypto::x509(device.cert);
      if (paired && X509_cmp(certificate, paired.get()) == 0) {
        return authenticated_device_t {device.uuid, device.name};
      }
    }
    return std::nullopt;
  }

  std::optional<authenticated_device_t> authenticated_device_for_certificate(X509 *certificate) {
    std::lock_guard<std::mutex> lock(cert_state_mutex);
    return resolve_paired_device(certificate, client_root.named_devices);
  }

#ifdef SUNSHINE_TESTS
  std::optional<authenticated_device_t> resolve_device_fixture_for_tests(const std::string &peer, const std::string &paired) {
    const auto certificate = crypto::x509(peer);
    return resolve_paired_device(certificate.get(), {{"Same display name", "paired-device-uuid", paired}});
  }
#endif

  bool unpair_client(const std::string_view uuid) {
    std::lock_guard<std::mutex> lock(cert_state_mutex);
    auto next = client_root;
    auto &devices = next.named_devices;
    const auto removed = std::remove_if(devices.begin(), devices.end(), [uuid](const auto &device) {
      return device.uuid == uuid;
    });
    if (removed == devices.end()) return false;
    devices.erase(removed, devices.end());
    if (!save_state(next)) return false;
    adopt_client_state(std::move(next));
    return true;
  }
}  // namespace nvhttp
