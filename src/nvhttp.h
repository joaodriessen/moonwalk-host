/**
 * @file src/nvhttp.h
 * @brief Declarations for the nvhttp (GameStream) server.
 */
// macros
#pragma once

// standard includes
#include <optional>
#include <string>
#include <string_view>

// lib includes
#include <boost/property_tree/ptree.hpp>
#include <nlohmann/json.hpp>
#include <Simple-Web-Server/server_https.hpp>

// local includes
#include "crypto.h"
#include "thread_safe.h"

/**
 * @brief Contains all the functions and variables related to the nvhttp (GameStream) server.
 */
namespace nvhttp {

  /**
   * @brief The protocol version.
   * @details The version of the GameStream protocol we are mocking.
   * @note The negative 4th number indicates to Moonlight that this is Sunshine.
   */
  constexpr auto VERSION = "7.1.431.-1";

  /**
   * @brief The GFE version we are replicating.
   */
  constexpr auto GFE_VERSION = "3.23.0.74";

  /**
   * @brief The HTTP port, as a difference from the config port.
   */
  constexpr auto PORT_HTTP = 0;

  /**
   * @brief The HTTPS port, as a difference from the config port.
   */
  constexpr auto PORT_HTTPS = -5;

  /**
   * @brief Start the nvhttp server.
   * @examples
   * nvhttp::start();
   * @examples_end
   */
  void start();

  /**
   * @brief Setup the nvhttp server.
   * @param pkey
   * @param cert
   */
  void setup(const std::string &pkey, const std::string &cert);

  struct authenticated_device_t {
    std::string uuid;
    std::string name;
  };
  // Match the actual transport peer certificate against the currently paired devices.
  // The claimed GameStream uniqueid is intentionally not an input.
  std::optional<authenticated_device_t> authenticated_device_for_certificate(X509 *certificate);
#ifdef SUNSHINE_TESTS
  std::optional<authenticated_device_t> resolve_device_fixture_for_tests(const std::string &peer, const std::string &paired);
#endif

  class SunshineHTTPS: public SimpleWeb::HTTPS {
  public:
    SunshineHTTPS(boost::asio::io_context &io_context, boost::asio::ssl::context &ctx):
        SimpleWeb::HTTPS(io_context, ctx) {
    }

    virtual ~SunshineHTTPS() {
      // Set Asio's user nonblocking flag (native mode alone is insufficient):
      // attempt close_notify without waiting for the peer on the HTTPS I/O thread.
      SimpleWeb::error_code ec;
      lowest_layer().non_blocking(true, ec);
      if (!ec) shutdown(ec); // Base RAII closes the socket on any failure.
    }
  };

  enum class PAIR_PHASE {
    NONE,  ///< Sunshine is not in a pairing phase
    GETSERVERCERT,  ///< Sunshine is in the get server certificate phase
    CLIENTCHALLENGE,  ///< Sunshine is in the client challenge phase
    SERVERCHALLENGERESP,  ///< Sunshine is in the server challenge response phase
    CLIENTPAIRINGSECRET  ///< Sunshine is in the client pairing secret phase
  };

  struct pair_session_t {
    struct {
      std::string uniqueID = {};
      std::string cert = {};
      std::string name = {};
    } client;

    /**
     * @brief The TCP source address this session's `getservercert` phase was received from,
     * as `request->remote_endpoint().address().to_string()` (see the getservercert branch of
     * `pair<T>()` in nvhttp.cpp). Attacker-unspoofable for a completed TCP exchange -- the peer
     * had to receive the response on this address, so it cannot be forged the way the
     * client-supplied `uniqueid`/`name`/cert fields can. Used for the per-source-IP pending-
     * session cap (Layer C) and as the human-legible label in `list_pending_pair_sessions()`'s
     * owner-facing picker (Layer B) -- NEVER as an auto-selection key by itself.
     */
    std::string source_ip = {};

    /**
     * @brief Best-effort, UNTRUSTED label from the client's `devicename` pairing query param
     * (captured in the getservercert branch of `pair<T>()` in nvhttp.cpp, via
     * `sanitize_client_device_name()` -- length-capped and control-character-stripped, since
     * this is attacker-controllable input like `client.uniqueID`/`client.cert`, NOT
     * unspoofable like `source_ip`). Surfaced in `list_pending_pair_sessions()`'s JSON under
     * `"client_name"`, alongside (never in place of) `source_ip` and `hostname_hint`. Exists
     * ONLY to pre-fill the owner's editable device-name field in the pairing UI -- it must
     * never be used as a trust signal or as part of the picker's identity labeling.
     */
    std::string client_device_name = {};

    /**
     * @brief Set once, the moment the owner-entered PIN is applied to this session (stamped in
     * `getservercert()`, the exact point `pin()` drives -- see nvhttp.cpp). Unset for a bare
     * phase-1 arrival that hasn't yet had a PIN submitted against it (the PIN_STDIN debug path
     * also stamps it, since it too calls `getservercert()`). Used by
     * `prune_stale_pairing_sessions_locked()`'s post-PIN handshake timeout (`HANDSHAKE_TIMEOUT`):
     * a session that still has a `pin_submitted_at` stamp and is still present in `map_id_sess`
     * more than `HANDSHAKE_TIMEOUT` after that stamp has, by definition, stalled -- a successful
     * pairing removes its own session at phase 4 (`clientpairingsecret()`) well before that. Only
     * sessions with a PIN actually applied by the owner can produce this outcome; unauthenticated
     * `getservercert` phantoms never get a PIN applied and keep expiring silently at
     * `PAIRING_SESSION_TTL` exactly as before.
     */
    std::optional<std::chrono::steady_clock::time_point> pin_submitted_at = {};

    std::unique_ptr<crypto::aes_t> cipher_key = {};
    std::vector<uint8_t> clienthash = {};

    std::string serversecret = {};
    std::string serverchallenge = {};

    struct {
      util::Either<
        std::shared_ptr<typename SimpleWeb::ServerBase<SimpleWeb::HTTP>::Response>,
        std::shared_ptr<typename SimpleWeb::ServerBase<SunshineHTTPS>::Response>>
        response;
      std::string salt = {};
    } async_insert_pin;

    /**
     * @brief used as a security measure to prevent out of order calls
     */
    PAIR_PHASE last_phase = PAIR_PHASE::NONE;
  };

  /**
   * @brief removes the temporary pairing session
   * @param sess
   */
  void remove_session(const pair_session_t &sess);

  /**
   * @brief Pair, phase 1
   *
   * Moonlight will send a salt and client certificate, we'll also need the user provided pin.
   *
   * PIN and SALT will be used to derive a shared AES key that needs to be stored
   * in order to be used to decrypt_symmetric in the next phases.
   *
   * Returns true once it has prepared the public certificate response.
   * A failure removes the session through fail_pair().
   */
  bool getservercert(pair_session_t &sess, boost::property_tree::ptree &tree, const std::string &pin);

  /**
   * @brief Pair, phase 2
   *
   * Using the AES key that we generated in phase 1 we have to decrypt the client challenge,
   *
   * We generate a SHA256 hash with the following:
   *  - Decrypted challenge
   *  - Server certificate signature
   *  - Server secret: a randomly generated secret
   *
   * The hash + server_challenge will then be AES encrypted and sent as the `challengeresponse` in the returned XML
   */
  void clientchallenge(pair_session_t &sess, boost::property_tree::ptree &tree, const std::string &challenge);

  /**
   * @brief Pair, phase 3
   *
   * Moonlight will send back a `serverchallengeresp`: an AES encrypted client hash,
   * we have to send back the `pairingsecret`:
   * using our private key we have to sign the certificate_signature + server_secret (generated in phase 2)
   */
  void serverchallengeresp(pair_session_t &sess, boost::property_tree::ptree &tree, const std::string &encrypted_response);

  /**
   * @brief Pair, phase 4 (final)
   *
   * We now have to use everything we exchanged before in order to verify and finally pair the clients
   *
   * We'll check the client_hash obtained at phase 3, it should contain the following:
   *   - The original server_challenge
   *   - The signature of the X509 client_cert
   *   - The unencrypted client_pairing_secret
   * We'll check that SHA256(server_challenge + client_public_cert_signature + client_secret) == client_hash
   *
   * Then using the client certificate public key we should be able to verify that
   * the client secret has been signed by Moonlight
   */
  void clientpairingsecret(pair_session_t &sess, std::shared_ptr<safe::queue_t<crypto::x509_t>> &add_cert, boost::property_tree::ptree &tree, const std::string &client_pairing_secret);

  /**
   * @brief Arm the owner-initiated pairing eligibility window (S3 pairing-DoS/hijack fix).
   *
   * Call this ONLY from an operator-gated surface -- today: `confighttp.cpp`'s `getPinPage`
   * (behind `authenticate()`) and the XPC `beginPairingWindowWithReply:` path (same-machine,
   * code-signature-pinned). It is deliberately NOT reachable from the unauthenticated `/pair`
   * listener, so an attacker cannot arm it themselves.
   *
   * Sets the window's open time to now. A pairing session (created by `pair<T>()`'s
   * `getservercert` phrase) is *eligible* for `pin()` to target while the window is active
   * (`now <= open_time + PAIRING_WINDOW_DURATION`) and the session's own creation time falls in
   * `[open_time - PAIRING_WINDOW_LOOKBACK, open_time + PAIRING_WINDOW_DURATION]`. The lookback
   * covers the common ordering where the genuine client fires `getservercert` (and shows its PIN)
   * a moment before the owner opens the host's pairing UI. See `pin()`'s implementation comment
   * for the full eligibility + targeting logic this window feeds.
   * @examples
   * nvhttp::arm_pairing_window();
   * @examples_end
   */
  void arm_pairing_window();

  /// The pairing protocol uses a PIN of exactly four ASCII digits.
  bool valid_pairing_pin(std::string_view pin);

  /**
   * @brief Send the PIN response to the device the owner selected.
   * @param pin The four digits shown on the client.
   * @param name The display name the owner chose for the device.
   * @param target_uniqueid The pending request selected by the owner in the active pairing window.
   * @return True when the PIN entered the first phase of the handshake. To check whether pairing
   * finished, use take_pair_outcome() or check the list of paired devices.
   */
  bool pin(std::string pin, std::string name, std::string target_uniqueid);

  /**
   * @brief List eligible pending requests that still need the owner's PIN.
   *
   * Read-only. Prunes stale sessions first (same `PAIRING_SESSION_TTL` as `has_pending_pair_
   * request()`), then filters to sessions eligible under the CURRENT armed window (see
   * `arm_pairing_window()` / `pin()`'s eligibility rule) -- a non-eligible phantom session never
   * appears here, so it can never be picked either. Each entry carries `source_ip`
   * (attacker-unspoofable for a completed TCP `getservercert`, see `pair_session_t::source_ip`),
   * which is the ONLY signal the owner picker in `PairingSheet.swift` / `pin.html` uses to
   * disambiguate -- there is no "newest"/"first" ordering implied or exposed here. Callers MUST
   * use this to have the owner explicitly confirm a `uniqueid` before calling `pin()` -- even
   * when this returns exactly one entry, `pin()` will refuse an empty `target_uniqueid`
   * unconditionally (see its doc comment); there is no size-based auto-select anywhere.
   * @return JSON array of `{"uniqueid": string, "source_ip": string, "age_sec": number,
   * "hostname_hint": string, "client_name": string}`, oldest first for display purposes only (NOT
   * a targeting hint -- selection is always by the owner's explicit choice of `uniqueid`/
   * `source_ip`). `hostname_hint` is a best-effort, UNTRUSTED reverse-DNS label for `source_ip`
   * (empty string when unresolved or unavailable) -- spoofable by anything with a PTR record for
   * that address, so it is shown ONLY as a human-legible secondary hint next to `source_ip`, never
   * as a substitute selection key. See `hostname_hint_for_ip()`'s implementation comment for the
   * never-blocking async/cache design that keeps a slow reverse lookup from ever stalling this
   * call. `client_name` is the UNTRUSTED, attacker-controllable, sanitized `devicename` the
   * pairing client itself sent (see `pair_session_t::client_device_name`) -- empty string when
   * absent. It exists ONLY to pre-fill the owner's editable device-name field; like
   * `hostname_hint`, it must never be used as a trust signal or part of the picker's identity
   * labeling.
   * @examples
   * nlohmann::json pending = nvhttp::list_pending_pair_sessions();
   * @examples_end
   */
  nlohmann::json list_pending_pair_sessions();

  /**
   * @brief Whether a pairing request is currently awaiting a PIN.
   *
   * Replaces `system_tray::update_tray_require_pin()` as an independent "someone wants to pair"
   * signal (that call becomes an automatic no-op once the daemon's own tray icon goes headless --
   * see docs/design/menubar-app.md workstream A/D). Prunes expired pending sessions first (the
   * same `PAIRING_SESSION_TTL` / `prune_stale_pairing_sessions_locked()` used by `pair<T>()`), so
   * a timed-out request never reads back as pending.
   * @return `true` iff at least one pairing session is pending after pruning.
   * @examples
   * bool pending = nvhttp::has_pending_pair_request();
   * @examples_end
   */
  bool has_pending_pair_request();

  /**
   * @brief Fast pairing outcome (owner-test-motivated fix): a read-only OBSERVATION of the
   * terminal pairing decision phase 4 has ALREADY made for `uniqueid`, if any -- does NOT touch
   * the crypto verification logic at all (`clientpairingsecret()`'s `same_hash && verify` check,
   * `nvhttp.cpp`). `fail_pair()` and `clientpairingsecret()`'s two branches record the outcome the
   * instant they run, before the pairing session is erased; this call lets a caller (the XPC
   * pairing sheet) learn that outcome immediately instead of waiting out a full poll-for-growth
   * timeout on a wrong PIN.
   *
   * SINGLE-CONSUMPTION: a hit ERASES the recorded outcome -- this is a one-shot notification, not
   * durable state. Calling this twice for the same completed attempt returns the real outcome
   * once and `std::nullopt` on every call after.
   *
   * @param uniqueid The pairing session's `uniqueid`, as submitted by the caller to `pin()`.
   * @return `true`/`false` for a known, just-recorded outcome; `std::nullopt` if nothing terminal
   * has happened yet, `uniqueid` is unknown, or the outcome was already consumed by an earlier
   * call -- all three cases mean the same thing to the caller: keep waiting (or fall back to the
   * paired-clients-list ground truth, same as before this fix existed).
   * @examples
   * std::optional<bool> outcome = nvhttp::take_pair_outcome(uniqueid);
   * @examples_end
   */
  std::optional<bool> take_pair_outcome(const std::string &uniqueid);

  /**
   * @brief Remove single client.
   * @param uuid The UUID of the client to remove.
   * @examples
   * nvhttp::unpair_client("4D7BB2DD-5704-A405-B41C-891A022932E1");
   * @examples_end
   */
  bool unpair_client(std::string_view uuid);

  /**
   * @brief Get all paired clients.
   * @return The list of all paired clients.
   * @examples
   * nlohmann::json clients = nvhttp::get_all_clients();
   * @examples_end
   */
  nlohmann::json get_all_clients();

  /**
   * @brief Remove all paired clients.
   * @return Whether the new list was saved.
   * @examples
   * nvhttp::erase_all_clients();
   * @examples_end
   */
  bool erase_all_clients();
}  // namespace nvhttp
