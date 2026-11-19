/**
 * @file src/confighttp.cpp
 * @brief Definitions for the Web UI Config HTTP server.
 *
 * @todo Authentication, better handling of routes common to nvhttp, cleanup
 */
#define BOOST_BIND_GLOBAL_PLACEHOLDERS

// standard includes
#include <atomic>
#include <chrono>
#include <filesystem>
#include <format>
#include <fstream>
#include <mutex>
#include <set>
#include <unordered_map>

// lib includes
#include <boost/algorithm/string.hpp>
#include <boost/asio/ssl/context.hpp>
#include <boost/filesystem.hpp>
#include <nlohmann/json.hpp>
#include <Simple-Web-Server/crypto.hpp>
#include <Simple-Web-Server/server_https.hpp>

#ifdef _WIN32
  #include "platform/windows/misc.h"

  #include <vector>
  #include <Windows.h>
#endif

// local includes
#include "config.h"
#include "config_validate.h"
#include "confighttp.h"
#include "crypto.h"
#include "display_device.h"
#include "file_handler.h"
#include "globals.h"
#include "httpcommon.h"
#include "logging.h"
#include "network.h"
#include "nvhttp.h"
#include "platform/common.h"
#include "process.h"
#include "utility.h"
#include "uuid.h"

using namespace std::literals;

namespace confighttp {
  namespace fs = std::filesystem;

  namespace {
    const fs::path &web_directory() {
      static const auto directory = file_handler::assets_directory() / "web";
      return directory;
    }

    std::string read_web_file(std::string_view filename) {
      return file_handler::read_file((web_directory() / filename).string().c_str());
    }

    // Simple per-IP failed-login throttle. Not a full security control, just
    // enough friction to slow down unattended Basic-Auth guessing over the LAN.
    constexpr int LOGIN_MAX_FAILURES = 5;
    constexpr std::chrono::seconds LOGIN_COOLDOWN {30};

    // Hard cap on distinct addresses tracked at once, as a backstop for a burst of
    // failures from many addresses within a single lockout window (time-based pruning
    // alone can't bound that case since nothing in the burst is stale yet).
    constexpr std::size_t LOGIN_THROTTLE_MAP_CAP = 1024;

    struct login_throttle_entry_t {
      int failures = 0;
      std::chrono::steady_clock::time_point blocked_until {};
      // Updated on every failure (not just once the threshold is hit) so stale entries
      // can be pruned below, independent of whether this address ever reached the
      // failure threshold.
      std::chrono::steady_clock::time_point last_activity {};
    };

    std::mutex login_throttle_mutex;
    std::unordered_map<std::string, login_throttle_entry_t> login_throttle_map;

    /**
     * @brief Check whether an address is currently in a failed-login cooldown.
     * @param address The normalized remote address.
     * @return True if requests from this address should be rejected without checking credentials.
     */
    bool is_login_throttled(const std::string &address) {
      std::lock_guard lock(login_throttle_mutex);
      auto it = login_throttle_map.find(address);
      if (it == login_throttle_map.end() || it->second.failures < LOGIN_MAX_FAILURES) {
        return false;
      }

      if (std::chrono::steady_clock::now() >= it->second.blocked_until) {
        // Cooldown has expired; give this address a clean slate.
        it->second.failures = 0;
        return false;
      }

      return true;
    }

    /**
     * @brief Drop throttle-map entries that can no longer affect any decision, so the
     * map (keyed by distinct source address) can't grow without bound. An entry that is
     * currently enforcing an active lockout is never touched, so a live attacker still
     * within the cooldown window is throttled identically to before this function existed.
     * @note Caller must hold `login_throttle_mutex`.
     */
    void prune_stale_throttle_entries_locked() {
      auto now = std::chrono::steady_clock::now();

      for (auto it = login_throttle_map.begin(); it != login_throttle_map.end();) {
        bool actively_blocked = it->second.failures >= LOGIN_MAX_FAILURES && now < it->second.blocked_until;
        if (!actively_blocked && now - it->second.last_activity > LOGIN_COOLDOWN) {
          it = login_throttle_map.erase(it);
        } else {
          ++it;
        }
      }

      // Backstop: if a burst of distinct addresses within the window still leaves the
      // map oversized, trim non-actively-blocked entries until back under the cap.
      for (auto it = login_throttle_map.begin();
           it != login_throttle_map.end() && login_throttle_map.size() > LOGIN_THROTTLE_MAP_CAP;) {
        bool actively_blocked = it->second.failures >= LOGIN_MAX_FAILURES && now < it->second.blocked_until;
        if (!actively_blocked) {
          it = login_throttle_map.erase(it);
        } else {
          ++it;
        }
      }
    }

    /**
     * @brief Record a failed login attempt for an address, starting a cooldown once the threshold is hit.
     * @param address The normalized remote address.
     */
    void record_login_failure(const std::string &address) {
      std::lock_guard lock(login_throttle_mutex);
      prune_stale_throttle_entries_locked();
      auto &entry = login_throttle_map[address];
      auto now = std::chrono::steady_clock::now();
      entry.last_activity = now;
      entry.failures++;
      if (entry.failures >= LOGIN_MAX_FAILURES) {
        entry.blocked_until = now + LOGIN_COOLDOWN;
      }
    }

    /**
     * @brief Reset an address's failure count after a successful login.
     * @param address The normalized remote address.
     */
    void record_login_success(const std::string &address) {
      std::lock_guard lock(login_throttle_mutex);
      login_throttle_map.erase(address);
    }

    // Serialize browser changes to apps.json through the running list update.
    std::mutex apps_write_mutex;
  }  // namespace

  using https_server_t = SimpleWeb::Server<SimpleWeb::HTTPS>;

  using args_t = SimpleWeb::CaseInsensitiveMultimap;
  using resp_https_t = std::shared_ptr<typename SimpleWeb::ServerBase<SimpleWeb::HTTPS>::Response>;
  using req_https_t = std::shared_ptr<typename SimpleWeb::ServerBase<SimpleWeb::HTTPS>::Request>;

  enum class op_e {
    ADD,  ///< Add client
    REMOVE  ///< Remove client
  };

  /**
   * @brief Log the method and route without request credentials or parameters.
   * @param request The HTTP request object.
   */
  void print_req(const req_https_t &request) {
    BOOST_LOG(debug) << "Web settings "sv << request->method << ' ' << request->path;
  }

  /**
   * @brief Send a response.
   * @param response The HTTP response object.
   * @param output_tree The JSON tree to send.
   */
  void send_response(resp_https_t response, const nlohmann::json &output_tree, SimpleWeb::CaseInsensitiveMultimap headers = {}) {
    headers.emplace("Content-Type", "application/json");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    // error_handler_t::replace (not the default `strict`) is defense-in-depth: every value
    // reaching this SHARED helper should already be valid UTF-8 at its source (e.g.
    // nvhttp::sanitize_client_device_name for pending-pairing device names), but `strict` would
    // THROW -- uncaught here -- on the first value that isn't, crashing the daemon. `replace`
    // substitutes U+FFFD instead, so a single bad string degrades one field rather than the
    // whole response.
    response->write(output_tree.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace), headers);
  }

  /**
   * @brief Send a 401 Unauthorized response.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void send_unauthorized(resp_https_t response, req_https_t request) {
    auto address = net::addr_to_normalized_string(request->remote_endpoint().address());
    BOOST_LOG(info) << "Web UI: ["sv << address << "] -- not authorized"sv;

    constexpr SimpleWeb::StatusCode code = SimpleWeb::StatusCode::client_error_unauthorized;

    nlohmann::json tree;
    tree["status_code"] = code;
    tree["status"] = false;
    tree["error"] = "Unauthorized";

    const SimpleWeb::CaseInsensitiveMultimap headers {
      {"Content-Type", "application/json"},
      {"WWW-Authenticate", R"(Basic realm="Sunshine Gamestream Host", charset="UTF-8")"},
      {"X-Frame-Options", "DENY"},
      {"Content-Security-Policy", "frame-ancestors 'none';"}
    };

    response->write(code, tree.dump(), headers);
  }

  /**
   * @brief Send a redirect response.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @param path The path to redirect to.
   */
  void send_redirect(resp_https_t response, req_https_t request, const char *path) {
    auto address = net::addr_to_normalized_string(request->remote_endpoint().address());
    BOOST_LOG(info) << "Web UI: ["sv << address << "] -- not authorized"sv;
    const SimpleWeb::CaseInsensitiveMultimap headers {
      {"Location", path},
      {"X-Frame-Options", "DENY"},
      {"Content-Security-Policy", "frame-ancestors 'none';"}
    };
    response->write(SimpleWeb::StatusCode::redirection_temporary_redirect, headers);
  }

  /**
   * @brief Authenticate the user.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @return True if the user is authenticated, false otherwise.
   */
  bool authenticate(resp_https_t response, req_https_t request) {
    auto address = net::addr_to_normalized_string(request->remote_endpoint().address());
    auto ip_type = net::from_address(address);

    if (ip_type > http::origin_web_ui_allowed) {
      BOOST_LOG(info) << "Web UI: ["sv << address << "] -- denied"sv;
      response->write(SimpleWeb::StatusCode::client_error_forbidden);
      return false;
    }

    // If credentials are shown, redirect the user to a /welcome page
    if (config::sunshine.username.empty()) {
      send_redirect(response, request, "/welcome");
      return false;
    }

    // After repeated failed credential guesses from this address, refuse to even
    // check credentials for a short cooldown window instead of hashing/comparing.
    if (is_login_throttled(address)) {
      BOOST_LOG(info) << "Web UI: ["sv << address << "] -- too many failed login attempts, cooling down"sv;
      response->write(SimpleWeb::StatusCode::client_error_too_many_requests);
      return false;
    }

    auto fg = util::fail_guard([&]() {
      send_unauthorized(response, request);
    });

    auto auth = request->header.find("authorization");
    if (auth == request->header.end()) {
      return false;
    }

    auto &rawAuth = auth->second;
    auto authData = SimpleWeb::Crypto::Base64::decode(rawAuth.substr("Basic "sv.length()));

    auto index = (int) authData.find(':');
    if (index >= authData.size() - 1) {
      return false;
    }

    auto username = authData.substr(0, index);
    auto password = authData.substr(index + 1);
    auto hash = util::hex(crypto::hash(password + config::sunshine.salt)).to_string();

    if (!boost::iequals(username, config::sunshine.username) || hash != config::sunshine.password) {
      // Only count actual wrong-credential guesses, not the bare/absent-header
      // probe every browser sends before it has cached credentials.
      record_login_failure(address);
      return false;
    }

    record_login_success(address);
    fg.disable();
    return true;
  }

  /**
   * @brief Returns true if writing `key = serialized_value` as a config.cpp-parseable line would
   * silently inject a second directive on reload (an embedded '\n' or '\r' in either half).
   *
   * Type-agnostic, schema-independent last-chokepoint guard used by saveConfig()'s write loop.
   * config_validate::validate_known_option()'s newline guard only fires for schema type ==
   * string/path/enum; known options of type list/object/map (e.g. global_prep_cmd,
   * dd_mode_remapping, keybindings) fall through that guard's "pass through unchecked" tail, yet
   * are written here exactly like any string-typed value. This function is the one place that
   * sees the literal bytes about to be written, regardless of the posted value's declared or
   * actual schema type -- config::parse_config() (config.cpp) splits sunshine.conf strictly
   * line-by-line, so an unguarded newline in either half injects a second, unvalidated config
   * directive (e.g. a fake global_prep_cmd hook = arbitrary shell execution).
   */
  bool would_inject_config_line(const std::string &key, const std::string &serialized_value) {
    return key.find('\n') != std::string::npos || key.find('\r') != std::string::npos ||
           serialized_value.find('\n') != std::string::npos || serialized_value.find('\r') != std::string::npos;
  }

  /**
   * @brief Extract the `host[:port]` authority from a URL-shaped header value (Origin or
   * Referer), stripping the scheme prefix and, for Referer, the path/query/fragment.
   */
  std::string extract_authority(const std::string &url) {
    auto scheme_end = url.find("://"sv);
    std::string rest = scheme_end == std::string::npos ? url : url.substr(scheme_end + 3);
    auto authority_end = rest.find_first_of("/?#"sv);
    return authority_end == std::string::npos ? rest : rest.substr(0, authority_end);
  }

  /**
   * @brief Same-origin guard for state-changing /api/ routes -- a minimal CSRF mitigation.
   *
   * NOT a port of upstream Sunshine's full CSRF-token subsystem (~1550 LOC across 13 files,
   * f04f6a2b + follow-ups): judged not worth the size/merge-conflict cost for a LAN/single-user
   * deploy. Reading upstream's own `validate_csrf_token()` closely, its decision tree is: (1)
   * Origin present and matching -> allow; (2) no Origin but Referer present and matching ->
   * allow; (3) NEITHER header present -> allow anyway (their own reasoning: "this cannot be a
   * browser-initiated CSRF attack"); (4) Origin/Referer present but MISMATCHED -> only here does
   * upstream demand a CSRF token. A real cross-origin attacker's page always sends a mismatched
   * Origin in case (4) and can never obtain this server's token (browser same-origin policy
   * blocks reading a same-origin-only token-fetch response from a foreign page) -- so a plain
   * hard reject on case (4), with no token fallback at all, is equivalent-or-stronger than
   * upstream's own mechanism, without any of the token-generation/storage/route/web-UI-JS
   * plumbing. This server is HTTPS-only (see start()), so comparing just `host[:port]` -- not a
   * full scheme+host+port triple -- against the request's own Host header is sufficient: nothing
   * legitimately reaches these handlers over any scheme but https.
   *
   * Split into a pure, header-agnostic `_impl` and a thin Simple-Web-Server-facing wrapper so the
   * actual decision logic is unit-testable without constructing a live Request/Response (which
   * Simple-Web-Server does not make easy to mock) -- see tests/unit/test_confighttp.cpp.
   *
   * @param origin Pointer to the Origin header value, or nullptr if absent.
   * @param referer Pointer to the Referer header value, or nullptr if absent.
   * @param host Pointer to the Host header value, or nullptr if absent.
   * @return true if the request should proceed (no Origin/Referer, or one that matches Host).
   */
  bool is_same_origin_impl(const std::string *origin, const std::string *referer, const std::string *host) {
    const std::string *candidate = nullptr;
    if (origin && !origin->empty()) {
      candidate = origin;
    } else if (referer && !referer->empty()) {
      candidate = referer;
    } else {
      // Neither header present: not a browser-initiated cross-origin fetch/XHR (which always
      // attaches Origin) or navigation (which always attaches Referer barring an explicit
      // referrer-policy opt-out an attacker's page can't force on OUR responses). Native/curl/
      // CLI clients never send either. Allow, matching upstream's own case (3).
      return true;
    }

    if (!host) {
      // No Host to compare against -- fail closed rather than silently allow.
      return false;
    }

    return extract_authority(*candidate) == *host;
  }

  bool is_same_origin(const req_https_t &request) {
    auto origin_it = request->header.find("origin");
    auto referer_it = request->header.find("referer");
    auto host_it = request->header.find("host");

    const std::string *origin = origin_it != request->header.end() ? &origin_it->second : nullptr;
    const std::string *referer = referer_it != request->header.end() ? &referer_it->second : nullptr;
    const std::string *host = host_it != request->header.end() ? &host_it->second : nullptr;

    return is_same_origin_impl(origin, referer, host);
  }

  /**
   * @brief Reject a state-changing request whose Origin/Referer is present but mismatched.
   * @return true if the caller should proceed; on false, a 403 has already been written.
   */
  bool check_same_origin(resp_https_t response, req_https_t request) {
    if (is_same_origin(request)) {
      return true;
    }
    BOOST_LOG(warning) << "Web UI: rejected request with mismatched Origin/Referer (possible CSRF)"sv;
    response->write(SimpleWeb::StatusCode::client_error_forbidden);
    return false;
  }

  /**
   * @brief Send a 404 Not Found response.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @param error_message The error message to include in the response.
   */
  void not_found(resp_https_t response, [[maybe_unused]] req_https_t request, const std::string &error_message = "Not Found") {
    constexpr SimpleWeb::StatusCode code = SimpleWeb::StatusCode::client_error_not_found;

    nlohmann::json tree;
    tree["status_code"] = code;
    tree["error"] = error_message;

    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "application/json");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");

    response->write(code, tree.dump(), headers);
  }

  /**
   * @brief Send a 400 Bad Request response.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @param error_message The error message to include in the response.
   */
  void bad_request(resp_https_t response, [[maybe_unused]] req_https_t request, const std::string &error_message = "Bad Request") {
    constexpr SimpleWeb::StatusCode code = SimpleWeb::StatusCode::client_error_bad_request;

    nlohmann::json tree;
    tree["status_code"] = code;
    tree["status"] = false;
    tree["error"] = error_message;

    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "application/json");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");

    response->write(code, tree.dump(), headers);
  }

  /**
   * @brief Validate the request content type and send bad request when mismatch.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @param contentType The expected content type
   */
  bool check_content_type(resp_https_t response, req_https_t request, const std::string_view &contentType) {
    auto requestContentType = request->header.find("content-type");
    if (requestContentType == request->header.end()) {
      bad_request(response, request, "Content type not provided");
      return false;
    }
    // Extract the media type part before any parameters (e.g., charset)
    std::string actualContentType = requestContentType->second;
    size_t semicolonPos = actualContentType.find(';');
    if (semicolonPos != std::string::npos) {
      actualContentType = actualContentType.substr(0, semicolonPos);
    }

    // Trim whitespace and convert to lowercase for case-insensitive comparison
    boost::algorithm::trim(actualContentType);
    boost::algorithm::to_lower(actualContentType);

    std::string expectedContentType(contentType);
    boost::algorithm::to_lower(expectedContentType);

    if (actualContentType != expectedContentType) {
      bad_request(response, request, "Content type mismatch");
      return false;
    }
    return true;
  }

  /**
   * @brief Get the parsed `config_schema.json`, loading and caching it on first use.
   *
   * The schema ships beside the browser settings. A missing or unreadable schema is logged
   * and cached as `std::nullopt`, preserving the browser's settings fallback.
   * @return The parsed schema, or `std::nullopt` if it could not be loaded.
   */
  const std::optional<nlohmann::json> &get_config_schema() {
    static const std::optional<nlohmann::json> schema = [] {
      const auto schema_path = web_directory() / "config_schema.json";
      auto loaded = config_validate::load_schema(schema_path.string());
      if (!loaded) {
        BOOST_LOG(error) << "confighttp: could not load "sv << schema_path
                          << " -- saveConfig will skip schema validation and configSchema will 404"sv;
      }
      return loaded;
    }();
    return schema;
  }

  /**
   * @brief Send a 400 Bad Request response listing every input-validation violation.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @param result The validation result (expected `result.ok == false`).
   */
  void send_validation_error(resp_https_t response, [[maybe_unused]] req_https_t request, const config_validate::result_t &result) {
    constexpr SimpleWeb::StatusCode code = SimpleWeb::StatusCode::client_error_bad_request;

    nlohmann::json tree = config_validate::violations_to_json(result);
    tree["status_code"] = code;
    tree["status"] = false;
    tree["error"] = "Input validation failed";

    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "application/json");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");

    response->write(code, tree.dump(), headers);
  }

  /**
   * @brief Validates the application index and sends error response if invalid.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @param apps The application list from the request's current file snapshot.
   * @param index The application index/id.
   */
  bool check_app_index(resp_https_t response, req_https_t request, const nlohmann::json &apps, int index) {
    if (index < 0 || index >= static_cast<int>(apps.size())) {
      std::string error;
      if (const int max_index = static_cast<int>(apps.size()) - 1; max_index < 0) {
        error = "No applications found";
      } else {
        error = std::format("'index' {} out of range, max index is {}", index, max_index);
      }
      bad_request(std::move(response), std::move(request), error);
      return false;
    }
    return true;
  }

  std::string apps_etag(const std::string &contents) {
    return std::format("\"{}\"", util::hex(crypto::hash(contents)).to_string());
  }

  bool check_apps_etag(const resp_https_t &response, const req_https_t &request, const std::string &contents) {
    const auto condition = request->header.find("If-Match");
    if (condition == request->header.end() || condition->second == "*" || condition->second == apps_etag(contents)) {
      return true;
    }
    response->write(SimpleWeb::StatusCode::client_error_precondition_failed);
    return false;
  }

  /**
   * @brief Get the index page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @todo combine these functions into a single function that accepts the page, i.e "index", "pin", "apps"
   */
  void getIndexPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    std::string content = read_web_file("index.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the PIN page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getPinPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    // SECURITY (S3 pairing-DoS/hijack fix): arm the owner eligibility window HERE, behind the
    // `authenticate()` gate above -- this is the one and only web-path trigger for
    // `nvhttp::arm_pairing_window()`. Loading this page IS the operator-gated "I'm about to pair
    // a device" signal for the web flow, mirroring the XPC menu app's `beginPairingWindowWithReply:`
    // for the native flow. See nvhttp.h's `arm_pairing_window()`/`pin()` doc comments for exactly
    // what this makes eligible and why an unauthenticated caller can never reach this.
    nvhttp::arm_pairing_window();

    std::string content = read_web_file("pin.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the apps page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getAppsPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    std::string content = read_web_file("apps.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    headers.emplace("Access-Control-Allow-Origin", "https://images.igdb.com/");
    response->write(content, headers);
  }

  /**
   * @brief Get the configuration page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getConfigPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    std::string content = read_web_file("config.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the password page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getPasswordPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    std::string content = read_web_file("password.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the welcome page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getWelcomePage(resp_https_t response, req_https_t request) {
    print_req(request);
    if (!config::sunshine.username.empty()) {
      send_redirect(response, request, "/");
      return;
    }
    std::string content = read_web_file("welcome.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the troubleshooting page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getTroubleshootingPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    std::string content = read_web_file("troubleshooting.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the favicon image.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @todo combine function with getSunshineLogoImage and possibly getNodeModules
   * @todo use mime_types map
   */
  void getFaviconImage(resp_https_t response, req_https_t request) {
    print_req(request);

    std::ifstream in(web_directory() / "images/sunshine.ico", std::ios::binary);
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "image/x-icon");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(SimpleWeb::StatusCode::success_ok, in, headers);
  }

  /**
   * @brief Get the Sunshine logo image.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @todo combine function with getFaviconImage and possibly getNodeModules
   * @todo use mime_types map
   */
  void getSunshineLogoImage(resp_https_t response, req_https_t request) {
    print_req(request);

    std::ifstream in(web_directory() / "images/logo-sunshine-45.png", std::ios::binary);
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "image/png");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(SimpleWeb::StatusCode::success_ok, in, headers);
  }

  /**
   * @brief Check if a path is a child of another path.
   * @param base The base path.
   * @param query The path to check.
   * @return True if the path is a child of the base path, false otherwise.
   */
  bool isChildPath(const fs::path &base, const fs::path &query) {
    std::error_code error;
    const auto relative = fs::relative(query, base, error);
    return !error && !relative.empty() && !relative.is_absolute() && *relative.begin() != "..";
  }

  /**
   * @brief Get an asset from the node_modules directory.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getNodeModules(resp_https_t response, req_https_t request) {
    print_req(request);
    const auto &webDirPath = web_directory();
    const auto nodeModulesPath = webDirPath / "assets";

    // .relative_path is needed to shed any leading slash that might exist in the request path
    std::error_code error;
    const auto filePath = fs::weakly_canonical(webDirPath / fs::path(request->path).relative_path(), error);

    // Don't do anything if file does not exist or is outside the assets directory
    if (error || !isChildPath(nodeModulesPath, filePath)) {
      BOOST_LOG(warning) << "Browser requested an asset outside the packaged asset directory";
      bad_request(response, request);
      return;
    }
    if (!fs::is_regular_file(filePath, error)) {
      not_found(response, request);
      return;
    }

    const auto extension = filePath.extension().string();
    const auto mimeType = extension.empty() ? mime_types.end() : mime_types.find(extension.substr(1));
    // check if the extension is in the map at the x position
    if (mimeType == mime_types.end()) {
      bad_request(response, request);
      return;
    }

    // if it is, set the content type to the mime type
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", mimeType->second);
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    std::ifstream in(filePath.string(), std::ios::binary);
    response->write(SimpleWeb::StatusCode::success_ok, in, headers);
  }

  /**
   * @brief Get the list of available applications.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/apps| GET| null}
   */
  void getApps(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    try {
      std::string content = file_handler::read_file(config::stream.file_apps.c_str());
      nlohmann::json file_tree = nlohmann::json::parse(content);

      // Legacy versions of Sunshine used strings for boolean and integers, let's convert them
      // List of keys to convert to boolean
      std::vector<std::string> boolean_keys = {
        "exclude-global-prep-cmd",
        "elevated",
        "auto-detach",
        "wait-all"
      };

      // List of keys to convert to integers
      std::vector<std::string> integer_keys = {
        "exit-timeout"
      };

      // Walk fileTree and convert true/false strings to boolean or integer values
      for (auto &app : file_tree["apps"]) {
        for (const auto &key : boolean_keys) {
          if (app.contains(key) && app[key].is_string()) {
            app[key] = app[key] == "true";
          }
        }
        for (const auto &key : integer_keys) {
          if (app.contains(key) && app[key].is_string()) {
            app[key] = std::stoi(app[key].get<std::string>());
          }
        }
        if (app.contains("prep-cmd")) {
          for (auto &prep : app["prep-cmd"]) {
            if (prep.contains("elevated") && prep["elevated"].is_string()) {
              prep["elevated"] = prep["elevated"] == "true";
            }
          }
        }
      }

      send_response(response, file_tree, {{"ETag", apps_etag(content)}, {"Cache-Control", "no-store"}});
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "GetApps: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Validate a posted saveApp() payload before it is merged into apps.json.
   *
   * Pure and HTTP-independent so it can be unit tested directly (see
   * tests/unit/test_confighttp.cpp) without constructing a live Request/Response. Deliberately
   * narrow, matching the rest of this file's "right-size, don't redesign" approach: presence/type
   * of the one field that is actually required (`name`), a type-agnostic newline guard reusing
   * would_inject_config_line() on every string that ultimately reaches apps.json or a
   * launch/prep-cmd (the same injection class already closed on the sunshine.conf write path),
   * and a generous upper bound on string/array sizes so a client can't balloon apps.json. Does not
   * otherwise validate the apps.json schema (booleans, exit-timeout range, legacy string-encoded
   * booleans, etc. are left to the existing behavior in saveApp()/getApps()).
   *
   * @param input_tree The parsed JSON body posted to POST /api/apps.
   * @param error Set to a human-readable rejection reason when this returns false.
   * @return True if the payload may proceed to saveApp()'s existing merge/write logic.
   */
  bool validate_app_payload(const nlohmann::json &input_tree, std::string &error) {
    constexpr size_t MAX_APP_STRING_LEN = 65536;
    constexpr size_t MAX_APP_LIST_SIZE = 512;

    if (!input_tree.is_object()) {
      error = "Request body must be a JSON object";
      return false;
    }

    if (!input_tree.contains("name") || !input_tree["name"].is_string() || input_tree["name"].get<std::string>().empty()) {
      error = "'name' is required and must be a non-empty string";
      return false;
    }

    auto check_string_field = [&](const std::string &field, const std::string &value) {
      if (value.size() > MAX_APP_STRING_LEN) {
        error = std::format("'{}' exceeds maximum length of {} characters", field, MAX_APP_STRING_LEN);
        return false;
      }
      if (would_inject_config_line(field, value)) {
        error = std::format("'{}' contains an embedded newline", field);
        return false;
      }
      return true;
    };

    for (const std::string &field : {"name", "output", "cmd", "image-path"}) {
      if (input_tree.contains(field) && input_tree[field].is_string() && !check_string_field(field, input_tree[field].get<std::string>())) {
        return false;
      }
    }

    if (input_tree.contains("prep-cmd")) {
      if (!input_tree["prep-cmd"].is_array()) {
        error = "'prep-cmd' must be an array";
        return false;
      }
      if (input_tree["prep-cmd"].size() > MAX_APP_LIST_SIZE) {
        error = "'prep-cmd' has too many entries";
        return false;
      }
      for (const auto &entry : input_tree["prep-cmd"]) {
        if (!entry.is_object()) {
          error = "'prep-cmd' entries must be objects";
          return false;
        }
        for (const std::string &field : {"do", "undo"}) {
          if (entry.contains(field) && entry[field].is_string() && !check_string_field("prep-cmd." + field, entry[field].get<std::string>())) {
            return false;
          }
        }
      }
    }

    if (input_tree.contains("detached")) {
      if (!input_tree["detached"].is_array()) {
        error = "'detached' must be an array";
        return false;
      }
      if (input_tree["detached"].size() > MAX_APP_LIST_SIZE) {
        error = "'detached' has too many entries";
        return false;
      }
      for (const auto &entry : input_tree["detached"]) {
        if (!entry.is_string()) {
          error = "'detached' entries must be strings";
          return false;
        }
        if (!check_string_field("detached", entry.get<std::string>())) {
          return false;
        }
      }
    }

    return true;
  }

  /**
   * @brief Save an application. To save a new application the index must be `-1`. To update an existing application, you must provide the current index of the application.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * The body for the post request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *   "name": "Application Name",
   *   "output": "Log Output Path",
   *   "cmd": "Command to run the application",
   *   "index": -1,
   *   "exclude-global-prep-cmd": false,
   *   "elevated": false,
   *   "auto-detach": true,
   *   "wait-all": true,
   *   "exit-timeout": 5,
   *   "prep-cmd": [
   *     {
   *       "do": "Command to prepare",
   *       "undo": "Command to undo preparation",
   *       "elevated": false
   *     }
   *   ],
   *   "detached": [
   *     "Detached command"
   *   ],
   *   "image-path": "Full path to the application image. Must be a png file."
   * }
   * @endcode
   *
   * @api_examples{/api/apps| POST| {"name":"Hello, World!","index":-1}}
   */
  void saveApp(resp_https_t response, req_https_t request) {
    if (!check_content_type(response, request, "application/json")) {
      return;
    }
    if (!authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    print_req(request);

    std::stringstream ss;
    ss << request->content.rdbuf();
    try {
      nlohmann::json output_tree;
      nlohmann::json input_tree = nlohmann::json::parse(ss);

      if (std::string validation_error; !validate_app_payload(input_tree, validation_error)) {
        BOOST_LOG(warning) << "SaveApp: rejected -- "sv << validation_error;
        bad_request(response, request, validation_error);
        return;
      }

      {
        std::lock_guard<std::mutex> apps_lock(apps_write_mutex);

        const auto contents = file_handler::read_file(config::stream.file_apps.c_str());
        if (!check_apps_etag(response, request, contents)) {
          return;
        }
        auto file_tree = nlohmann::json::parse(contents);

        if (input_tree["prep-cmd"].empty()) {
          input_tree.erase("prep-cmd");
        }

        if (input_tree["detached"].empty()) {
          input_tree.erase("detached");
        }

        auto &apps_node = file_tree["apps"];
        int index = input_tree["index"].get<int>();  // this will intentionally cause exception if the provided value is the wrong type

        input_tree.erase("index");

        if (index == -1) {
          apps_node.push_back(input_tree);
        } else {
          if (!check_app_index(response, request, apps_node, index)) {
            return;
          }
          apps_node[index] = std::move(input_tree);
        }

        // Sort the apps array by name
        std::sort(apps_node.begin(), apps_node.end(), [](const nlohmann::json &a, const nlohmann::json &b) {
          return a["name"].get<std::string>() < b["name"].get<std::string>();
        });

        if (!file_handler::write_file_atomic(config::stream.file_apps.c_str(), file_tree.dump(4))) {
          bad_request(response, request, "failed to write application settings");
          return;
        }
        proc::refresh(config::stream.file_apps);
      }

      output_tree["status"] = true;
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "SaveApp: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Close the currently running application.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/apps/close| POST| null}
   */
  void closeApp(resp_https_t response, req_https_t request) {
    if (!check_content_type(response, request, "application/json")) {
      return;
    }
    if (!authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    print_req(request);

    proc::proc.terminate();

    nlohmann::json output_tree;
    output_tree["status"] = true;
    send_response(response, output_tree);
  }

  /**
   * @brief Delete an application.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/apps/9999| DELETE| null}
   */
  void deleteApp(resp_https_t response, req_https_t request) {
    // Skip check_content_type() for this endpoint since the request body is not used.

    if (!authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    print_req(request);

    try {
      nlohmann::json output_tree;
      const int index = std::stoi(request->path_match[1]);

      {
        std::lock_guard<std::mutex> apps_lock(apps_write_mutex);

        const auto contents = file_handler::read_file(config::stream.file_apps.c_str());
        if (!check_apps_etag(response, request, contents)) {
          return;
        }
        auto file_tree = nlohmann::json::parse(contents);
        auto &apps = file_tree["apps"];
        if (!check_app_index(response, request, apps, index)) {
          return;
        }
        apps.erase(index);

        if (!file_handler::write_file_atomic(config::stream.file_apps.c_str(), file_tree.dump(4))) {
          bad_request(response, request, "failed to write application settings");
          return;
        }
        proc::refresh(config::stream.file_apps);
      }

      output_tree["status"] = true;
      output_tree["result"] = std::format("application {} deleted", index);
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "DeleteApp: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Get the list of paired clients.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/clients/list| GET| null}
   */
  void getClients(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    const nlohmann::json named_certs = nvhttp::get_all_clients();

    nlohmann::json output_tree;
    output_tree["named_certs"] = named_certs;
    output_tree["status"] = true;
    send_response(response, output_tree);
  }

  /**
   * @brief Layer B (S3 pairing-DoS/hijack fix, hardened): list currently-ELIGIBLE pending
   * pairing sessions, for `pin.html`'s picker to let the owner explicitly confirm one by source
   * IP -- required even when there is only one entry, since `nvhttp::pin()` refuses an empty
   * target unconditionally (see that function's doc comment for why "the lone eligible session"
   * is not a safe auto-select).
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * Authenticated the same as every other `/api` GET here. Thin wrapper over
   * `nvhttp::list_pending_pair_sessions()` (src/nvhttp.cpp) -- no pairing state is read or
   * reasoned about here; see that function's doc comment for exactly what "eligible" means and
   * why a non-eligible phantom session can never appear in this list (and therefore can never be
   * picked from it either). `savePin` (below) is what actually applies a PIN to a chosen
   * `uniqueid` from this list.
   *
   * @api_examples{/api/pending-pairings| GET| null}
   */
  void getPendingPairings(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    nlohmann::json output_tree;
    output_tree["pending"] = nvhttp::list_pending_pair_sessions();
    output_tree["status"] = true;
    send_response(response, output_tree);
  }

  /**
   * @brief Validate a posted unpair() payload before nvhttp::unpair_client() is invoked.
   *
   * Pure and HTTP-independent (see tests/unit/test_confighttp.cpp). `uuid` must be present, a
   * JSON string, non-empty, plausibly sized, and free of embedded newlines -- the last check
   * reuses would_inject_config_line() defense-in-depth, since the paired-client store is
   * persisted to disk and this is the one place that sees the literal value before that happens.
   *
   * @param input_tree The parsed JSON body posted to POST /api/unpair.
   * @param error Set to a human-readable rejection reason when this returns false.
   * @return True if `uuid` may be handed to nvhttp::unpair_client().
   */
  bool validate_unpair_payload(const nlohmann::json &input_tree, std::string &error) {
    constexpr size_t MAX_UUID_LEN = 256;

    if (!input_tree.is_object() || !input_tree.contains("uuid") || !input_tree["uuid"].is_string()) {
      error = "'uuid' is required and must be a string";
      return false;
    }

    const std::string uuid = input_tree["uuid"].get<std::string>();
    if (uuid.empty()) {
      error = "'uuid' must not be empty";
      return false;
    }
    if (uuid.size() > MAX_UUID_LEN) {
      error = "'uuid' exceeds maximum length";
      return false;
    }
    if (would_inject_config_line("uuid", uuid)) {
      error = "'uuid' contains an embedded newline";
      return false;
    }

    return true;
  }

  /**
   * @brief Unpair a client.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * The body for the post request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *  "uuid": "<uuid>"
   * }
   * @endcode
   *
   * @api_examples{/api/unpair| POST| {"uuid":"1234"}}
   */
  void unpair(resp_https_t response, req_https_t request) {
    if (!check_content_type(response, request, "application/json")) {
      return;
    }
    if (!authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    print_req(request);

    std::stringstream ss;
    ss << request->content.rdbuf();

    try {
      nlohmann::json output_tree;
      const nlohmann::json input_tree = nlohmann::json::parse(ss);

      if (std::string validation_error; !validate_unpair_payload(input_tree, validation_error)) {
        BOOST_LOG(warning) << "Unpair: rejected -- "sv << validation_error;
        bad_request(response, request, validation_error);
        return;
      }

      const std::string uuid = input_tree.value("uuid", "");
      output_tree["status"] = nvhttp::unpair_client(uuid);
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "Unpair: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Unpair all clients.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/clients/unpair-all| POST| null}
   */
  void unpairAll(resp_https_t response, req_https_t request) {
    if (!check_content_type(response, request, "application/json")) {
      return;
    }
    if (!authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    print_req(request);

    const bool saved = nvhttp::erase_all_clients();
    if (saved) proc::proc.terminate();
    nlohmann::json output_tree;
    output_tree["status"] = saved;
    send_response(response, output_tree);
  }

  /**
   * @brief Get the configuration settings.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/config| GET| null}
   */
  void getConfig(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    nlohmann::json output_tree;
    auto vars = config::parse_config(file_handler::read_file(config::sunshine.config_file.c_str()));
    for (auto &[name, value] : vars) {
      output_tree[name] = std::move(value);
    }
    output_tree["status"] = true;
    output_tree["platform"] = SUNSHINE_PLATFORM;
    output_tree["version"] = PROJECT_VERSION;
    output_tree["host_version"] = SKYLIGHT_VERSION;
    output_tree["source_revision"] = PROJECT_VERSION_COMMIT;

    send_response(response, output_tree);
  }

  /**
   * @brief Get the locale setting. This endpoint does not require authentication.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/configLocale| GET| null}
   */
  void getLocale(resp_https_t response, req_https_t request) {
    // we need to return the locale whether authenticated or not

    print_req(request);

    nlohmann::json output_tree;
    output_tree["status"] = true;
    output_tree["locale"] = config::sunshine.locale;
    send_response(response, output_tree);
  }

  /**
   * @brief Get the config option schema (name/type/default/range/enum/tab/platform metadata),
   *        verbatim from `config_schema.json`. Consumed by the web UI and the Swift menubar app.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/configSchema| GET| null}
   */
  void getConfigSchema(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    const auto &schema = get_config_schema();
    if (!schema) {
      bad_request(response, request, "config_schema.json is unavailable on this host");
      return;
    }

    send_response(response, *schema);
  }

  /**
   * @brief Save the configuration settings.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * The body for the post request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *   "key": "value"
   * }
   * @endcode
   *
   * @attention{It is recommended to ONLY save the config settings that differ from the default behavior.}
   *
   * Known keys are validated against `config_schema.json` (type/range/enum) before anything is
   * written -- a bad known value is rejected with HTTP 400 naming every offending key, not just
   * the first. Unknown keys (e.g. from a hand-edited or upstream-newer conf) are logged as a
   * warning and written through unchanged. The settings endpoint remains available when the
   * shared schema cannot be loaded.
   *
   * @api_examples{/api/config| POST| {"key":"value"}}
   */
  void saveConfig(resp_https_t response, req_https_t request) {
    if (!check_content_type(response, request, "application/json")) {
      return;
    }
    if (!authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    print_req(request);

    std::stringstream ss;
    ss << request->content.rdbuf();
    try {
      nlohmann::json input_tree = nlohmann::json::parse(ss);
      if (input_tree.is_object()) {
        for (const auto *key : {"status", "platform", "version", "host_version", "source_revision"}) {
          input_tree.erase(key);
        }
      }

      const auto &schema = get_config_schema();
      if (schema) {
        auto validation = config_validate::validate(*schema, input_tree);
        for (const auto &unknown_key : validation.unknown_keys) {
          BOOST_LOG(warning) << "SaveConfig: unknown config key '"sv << unknown_key << "' -- writing through unvalidated"sv;
        }
        if (!validation.ok) {
          BOOST_LOG(warning) << "SaveConfig: rejected "sv << validation.violations.size() << " invalid value(s)"sv;
          send_validation_error(response, request, validation);
          return;
        }
      } else {
        BOOST_LOG(warning) << "SaveConfig: config_schema.json unavailable -- writing without validation"sv;
      }

      std::stringstream config_stream;
      nlohmann::json output_tree;

      // CONCURRENCY: serialize this read-modify-write of sunshine.conf against xpc_control.mm's
      // SetConfValue() (menubar app), which performs its own unsynchronized read-modify-write of
      // the same file. Without this, a menubar setter racing this Save is a last-writer-wins lost
      // update. Scope held tight to just the config-file build+write below -- request parsing and
      // schema validation above already happened without the lock, and nothing here calls back
      // into anything that re-acquires config::config_write_mutex() (see deadlock note there).
      {
        std::lock_guard<std::mutex> config_write_lock(config::config_write_mutex());

        for (const auto &[k, v] : input_tree.items()) {
          if (v.is_null() || (v.is_string() && v.get<std::string>().empty())) {
            continue;
          }

          // v.dump() will dump valid json, which we do not want for strings in the config right now
          // we should migrate the config file to straight json and get rid of all this nonsense
          const std::string serialized = v.is_string() ? v.get<std::string>() : v.dump();

          // SECURITY (defense in depth, type-agnostic write-site guard -- see
          // would_inject_config_line()'s doc comment for why this can't rely on
          // config_validate's type-enumerated check alone).
          if (would_inject_config_line(k, serialized)) {
            BOOST_LOG(warning) << "SaveConfig: rejected key '"sv << k << "' -- key or value contains an embedded newline (injection attempt)"sv;
            bad_request(response, request, "key or value contains an embedded newline");
            return;
          }

          config_stream << k << " = " << serialized << std::endl;
        }
        // Crash-atomic: write_file() truncates in place, so a crash/power-loss mid-write would
        // leave sunshine.conf truncated/corrupt on next start (resetting the host to defaults).
        // write_file_atomic() writes to a sibling temp file and renames over the target, matching
        // xpc_control.mm's SetConfValue() (the menubar app's writer for the same file).
        if (!file_handler::write_file_atomic(config::sunshine.config_file.c_str(), config_stream.str())) {
          BOOST_LOG(warning) << "SaveConfig: failed to atomically write "sv << config::sunshine.config_file;
          bad_request(response, request, "failed to write config file");
          return;
        }
      }

      output_tree["status"] = true;
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "SaveConfig: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Get an application's image.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @note{The index in the url path is the application index.}
   *
   * @api_examples{/api/covers/9999 | GET| null}
   */
  void getCover(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    try {
      const int index = std::stoi(request->path_match[1]);
      std::string file = file_handler::read_file(config::stream.file_apps.c_str());
      nlohmann::json file_tree = nlohmann::json::parse(file);
      if (!check_app_index(response, request, file_tree["apps"], index)) {
        return;
      }
      auto &apps = file_tree["apps"];

      auto &app = apps[index];

      // Get the image path from the app configuration
      std::string app_image_path;
      if (app.contains("image-path") && !app["image-path"].is_null()) {
        app_image_path = app["image-path"];
      }

      // Use validate_app_image_path to resolve and validate the path
      // This handles extension validation, PNG signature validation, and path resolution
      std::string validated_path = proc::validate_app_image_path(app_image_path);

      // Check if we got the default image path (means validation failed or no image configured)
      if (validated_path == proc::default_app_image_path()) {
        BOOST_LOG(debug) << "Application at index " << index << " does not have a valid cover image";
        not_found(response, request, "Cover image not found");
        return;
      }

      // Open and stream the validated file
      std::ifstream in(validated_path, std::ios::binary);
      if (!in) {
        BOOST_LOG(warning) << "Unable to read cover image file: " << validated_path;
        bad_request(response, request, "Unable to read cover image file");
        return;
      }

      SimpleWeb::CaseInsensitiveMultimap headers;
      headers.emplace("Content-Type", "image/png");
      headers.emplace("X-Frame-Options", "DENY");
      headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");

      response->write(SimpleWeb::StatusCode::success_ok, in, headers);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "GetCover: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Upload a cover image.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * The body for the post request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *   "key": "igdb_<game_id>",
   *   "url": "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/<slug>.png"
   * }
   * @endcode
   *
   * @api_examples{/api/covers/upload| POST| {"key":"igdb_1234","url":"https://images.igdb.com/igdb/image/upload/t_cover_big_2x/abc123.png"}}
   */
  void uploadCover(resp_https_t response, req_https_t request) {
    if (!check_content_type(response, request, "application/json")) {
      return;
    }
    if (!authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    std::stringstream ss;
    ss << request->content.rdbuf();
    try {
      nlohmann::json output_tree;
      nlohmann::json input_tree = nlohmann::json::parse(ss);

      std::string key = input_tree.value("key", "");
      if (key.empty()) {
        bad_request(response, request, "Cover key is required");
        return;
      }
      std::string url = input_tree.value("url", "");

      const std::string coverdir = platf::appdata().string() + "/covers/";
      file_handler::make_directory(coverdir);

      std::basic_string path = coverdir + http::url_escape(key) + ".png";
      if (!url.empty()) {
        if (http::url_get_host(url) != "images.igdb.com") {
          bad_request(response, request, "Only images.igdb.com is allowed");
          return;
        }
        if (!http::download_file(url, path)) {
          bad_request(response, request, "Failed to download cover");
          return;
        }
      } else {
        auto data = SimpleWeb::Crypto::Base64::decode(input_tree.value("data", ""));

        std::ofstream imgfile(path);
        imgfile.write(data.data(), static_cast<int>(data.size()));
      }
      output_tree["status"] = true;
      output_tree["path"] = path;
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "UploadCover: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Get the logs from the log file.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/logs| GET| null}
   */
  void getLogs(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    std::string content = file_handler::read_file(config::sunshine.log_file.c_str());
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/plain");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(SimpleWeb::StatusCode::success_ok, content, headers);
  }

  /**
   * @brief Validate the type and size of savePassword()'s string fields.
   *
   * Pure and HTTP-independent (see tests/unit/test_confighttp.cpp). savePassword() already
   * enforces the fields that matter for correctness -- current-credential verification and
   * new/confirm password matching (see savePassword() below) -- so this only adds the missing
   * bound: any of the five fields, if present, must be a JSON string no longer than
   * MAX_PASSWORD_FIELD_LEN, so a client can't force a hash/compare/credentials-file-write over an
   * arbitrarily large payload. Presence/emptiness is intentionally left to savePassword()'s
   * existing logic, which already rejects an empty resulting username or password.
   *
   * @param input_tree The parsed JSON body posted to POST /api/password.
   * @param error Set to a human-readable rejection reason when this returns false.
   * @return True if every present field is a string within bounds.
   */
  bool validate_password_payload_lengths(const nlohmann::json &input_tree, std::string &error) {
    constexpr size_t MAX_PASSWORD_FIELD_LEN = 1024;

    if (!input_tree.is_object()) {
      error = "Request body must be a JSON object";
      return false;
    }

    for (const std::string &field : {"currentUsername", "currentPassword", "newUsername", "newPassword", "confirmNewPassword"}) {
      if (!input_tree.contains(field)) {
        continue;
      }
      if (!input_tree[field].is_string()) {
        error = std::format("'{}' must be a string", field);
        return false;
      }
      if (input_tree[field].get<std::string>().size() > MAX_PASSWORD_FIELD_LEN) {
        error = std::format("'{}' exceeds maximum length of {} characters", field, MAX_PASSWORD_FIELD_LEN);
        return false;
      }
    }

    return true;
  }

  /**
   * @brief Update existing credentials.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * The body for the post request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *   "currentUsername": "Current Username",
   *   "currentPassword": "Current Password",
   *   "newUsername": "New Username",
   *   "newPassword": "New Password",
   *   "confirmNewPassword": "Confirm New Password"
   * }
   * @endcode
   *
   * @api_examples{/api/password| POST| {"currentUsername":"admin","currentPassword":"admin","newUsername":"admin","newPassword":"admin","confirmNewPassword":"admin"}}
   */
  void savePassword(resp_https_t response, req_https_t request) {
    if (!check_content_type(response, request, "application/json")) {
      return;
    }
    if (!config::sunshine.username.empty() && !authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    print_req(request);

    std::vector<std::string> errors = {};
    std::stringstream ss;
    std::stringstream config_stream;
    ss << request->content.rdbuf();
    try {
      nlohmann::json output_tree;
      nlohmann::json input_tree = nlohmann::json::parse(ss);

      if (std::string validation_error; !validate_password_payload_lengths(input_tree, validation_error)) {
        BOOST_LOG(warning) << "SavePassword: rejected -- "sv << validation_error;
        bad_request(response, request, validation_error);
        return;
      }

      std::string username = input_tree.value("currentUsername", "");
      std::string newUsername = input_tree.value("newUsername", "");
      std::string password = input_tree.value("currentPassword", "");
      std::string newPassword = input_tree.value("newPassword", "");
      std::string confirmPassword = input_tree.value("confirmNewPassword", "");
      if (newUsername.empty()) {
        newUsername = username;
      }
      if (newUsername.empty()) {
        errors.emplace_back("Invalid Username");
      } else {
        auto hash = util::hex(crypto::hash(password + config::sunshine.salt)).to_string();
        if (config::sunshine.username.empty() || (boost::iequals(username, config::sunshine.username) && hash == config::sunshine.password)) {
          if (newPassword.empty() || newPassword != confirmPassword) {
            errors.emplace_back("Password Mismatch");
          } else {
            if (http::save_user_creds(config::sunshine.credentials_file, newUsername, newPassword) ||
                http::reload_user_creds(config::sunshine.credentials_file)) {
              errors.emplace_back("Could not save Moonwalk Host credentials.");
            } else {
              output_tree["status"] = true;
            }
          }
        } else {
          errors.emplace_back("Invalid Current Credentials");
        }
      }

      if (!errors.empty()) {
        // join the errors array
        std::string error = std::accumulate(errors.begin(), errors.end(), std::string(), [](const std::string &a, const std::string &b) {
          return a.empty() ? b : a + ", " + b;
        });
        bad_request(response, request, error);
        return;
      }

      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "SavePassword: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Send a pin code to the host. The pin is generated from the Moonlight client during the pairing process.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * The body for the post request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *   "pin": "<pin>",
   *   "name": "Friendly Client Name",
   *   "uniqueid": "Selected pending request ID"
   * }
   * @endcode
   *
   * @api_examples{/api/pin| POST| {"pin":"1234","name":"My PC","uniqueid":"request-id"}}
   */
  void savePin(resp_https_t response, req_https_t request) {
    if (!check_content_type(response, request, "application/json")) {
      return;
    }
    if (!authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    print_req(request);

    std::stringstream ss;
    ss << request->content.rdbuf();
    try {
      nlohmann::json output_tree;
      nlohmann::json input_tree = nlohmann::json::parse(ss);
      const std::string name = input_tree.value("name", "");
      const std::string pin = input_tree.value("pin", "");
      const std::string target_uniqueid = input_tree.value("uniqueid", "");
      if (!nvhttp::valid_pairing_pin(pin)) {
        bad_request(response, request, "Enter exactly four digits for the PIN");
        return;
      }

      output_tree["status"] = nvhttp::pin(pin, name, target_uniqueid);
      send_response(response, output_tree);
    } catch (const std::exception &) {
      BOOST_LOG(warning) << "Browser pairing request could not be processed"sv;
      bad_request(response, request, "Could not process the pairing request");
    }
  }

  /**
   * @brief Reset the display device persistence.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/reset-display-device-persistence| POST| null}
   */
  void resetDisplayDevicePersistence(resp_https_t response, req_https_t request) {
    if (!check_content_type(response, request, "application/json")) {
      return;
    }
    if (!authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    print_req(request);

    nlohmann::json output_tree;
    output_tree["status"] = display_device::reset_persistence();
    send_response(response, output_tree);
  }

  /**
   * @brief Acknowledge the request before restarting the host.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/restart| POST| null}
   */
  void restart(resp_https_t response, req_https_t request) {
    if (!check_content_type(response, request, "application/json")) {
      return;
    }
    if (!authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    print_req(request);

    response->close_connection_after_response = true;
    send_response(response, {{"status", true}});
    response->send([](const auto &error) {
      static std::atomic_bool restarting {false};
      if (!error && !restarting.exchange(true)) {
        platf::restart();
      }
    });
  }

  /**
   * @brief Get ViGEmBus driver version and installation status.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/vigembus/status| GET| null}
   */
  void getViGEmBusStatus(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    nlohmann::json output_tree;

#ifdef _WIN32
    std::string version_str;
    bool installed = false;
    bool version_compatible = false;

    // Check if ViGEmBus driver exists
    std::filesystem::path driver_path = std::filesystem::path(std::getenv("SystemRoot") ? std::getenv("SystemRoot") : "C:\\Windows") / "System32" / "drivers" / "ViGEmBus.sys";

    if (std::filesystem::exists(driver_path)) {
      installed = platf::getFileVersionInfo(driver_path, version_str);
      if (installed) {
        // Parse version string to check compatibility (>= 1.17.0.0)
        std::vector<std::string> version_parts;
        std::stringstream ss(version_str);
        std::string part;
        while (std::getline(ss, part, '.')) {
          version_parts.push_back(part);
        }

        if (version_parts.size() >= 2) {
          int major = std::stoi(version_parts[0]);
          int minor = std::stoi(version_parts[1]);
          version_compatible = (major > 1) || (major == 1 && minor >= 17);
        }
      }
    }

    output_tree["installed"] = installed;
    output_tree["version"] = version_str;
    output_tree["version_compatible"] = version_compatible;
    output_tree["packaged_version"] = VIGEMBUS_PACKAGED_VERSION;
#else
    output_tree["error"] = "ViGEmBus is only available on Windows";
    output_tree["installed"] = false;
    output_tree["version"] = "";
    output_tree["version_compatible"] = false;
    output_tree["packaged_version"] = "";
#endif

    send_response(response, output_tree);
  }

  /**
   * @brief Install ViGEmBus driver with elevated permissions.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/vigembus/install| POST| null}
   */
  void installViGEmBus(resp_https_t response, req_https_t request) {
    if (!check_content_type(response, request, "application/json")) {
      return;
    }
    if (!authenticate(response, request)) {
      return;
    }
    if (!check_same_origin(response, request)) {
      return;
    }

    print_req(request);

    nlohmann::json output_tree;

#ifdef _WIN32
    // Get the path to the vigembus installer
    const std::filesystem::path installer_path = platf::appdata().parent_path() / "scripts" / "vigembus_installer.exe";

    if (!std::filesystem::exists(installer_path)) {
      output_tree["status"] = false;
      output_tree["error"] = "ViGEmBus installer not found";
      send_response(response, output_tree);
      return;
    }

    // Run the installer with elevated permissions
    std::error_code ec;
    boost::filesystem::path working_dir = boost::filesystem::path(installer_path.string()).parent_path();
    boost::process::v1::environment env = boost::this_process::environment();

    // Run with elevated permissions, non-interactive
    const std::string install_cmd = std::format("{} /quiet", installer_path.string());
    auto child = platf::run_command(true, false, install_cmd, working_dir, env, nullptr, ec, nullptr);

    if (ec) {
      output_tree["status"] = false;
      output_tree["error"] = "Failed to start installer: " + ec.message();
      send_response(response, output_tree);
      return;
    }

    // Wait for the installer to complete
    child.wait(ec);

    if (ec) {
      output_tree["status"] = false;
      output_tree["error"] = "Installer failed: " + ec.message();
    } else {
      int exit_code = child.exit_code();
      output_tree["status"] = (exit_code == 0);
      output_tree["exit_code"] = exit_code;
      if (exit_code != 0) {
        output_tree["error"] = std::format("Installer exited with code {}", exit_code);
      }
    }
#else
    output_tree["status"] = false;
    output_tree["error"] = "ViGEmBus installation is only available on Windows";
#endif

    send_response(response, output_tree);
  }

  void start() {
    platf::set_thread_name("confighttp");
    auto shutdown_event = mail::man->event<bool>(mail::shutdown);

    auto port_https = net::map_port(PORT_HTTPS);
    auto address_family = net::af_from_enum_string(config::sunshine.address_family);

    https_server_t server {config::nvhttp.cert, config::nvhttp.pkey};
    server.default_resource["DELETE"] = [](resp_https_t response, req_https_t request) {
      bad_request(response, request);
    };
    server.default_resource["PATCH"] = [](resp_https_t response, req_https_t request) {
      bad_request(response, request);
    };
    server.default_resource["POST"] = [](resp_https_t response, req_https_t request) {
      bad_request(response, request);
    };
    server.default_resource["PUT"] = [](resp_https_t response, req_https_t request) {
      bad_request(response, request);
    };
    server.default_resource["GET"] = [](resp_https_t response, req_https_t request) {
      not_found(response, request);
    };
    server.resource["^/$"]["GET"] = getIndexPage;
    server.resource["^/pin/?$"]["GET"] = getPinPage;
    server.resource["^/apps/?$"]["GET"] = getAppsPage;
    server.resource["^/config/?$"]["GET"] = getConfigPage;
    server.resource["^/password/?$"]["GET"] = getPasswordPage;
    server.resource["^/welcome/?$"]["GET"] = getWelcomePage;
    server.resource["^/troubleshooting/?$"]["GET"] = getTroubleshootingPage;
    server.resource["^/api/pin$"]["POST"] = savePin;
    server.resource["^/api/apps$"]["GET"] = getApps;
    server.resource["^/api/logs$"]["GET"] = getLogs;
    server.resource["^/api/apps$"]["POST"] = saveApp;
    server.resource["^/api/config$"]["GET"] = getConfig;
    server.resource["^/api/config$"]["POST"] = saveConfig;
    server.resource["^/api/configSchema$"]["GET"] = getConfigSchema;
    server.resource["^/api/configLocale$"]["GET"] = getLocale;
    server.resource["^/api/restart$"]["POST"] = restart;
    server.resource["^/api/reset-display-device-persistence$"]["POST"] = resetDisplayDevicePersistence;
    server.resource["^/api/vigembus/status$"]["GET"] = getViGEmBusStatus;
    server.resource["^/api/vigembus/install$"]["POST"] = installViGEmBus;
    server.resource["^/api/password$"]["POST"] = savePassword;
    server.resource["^/api/apps/([0-9]+)$"]["DELETE"] = deleteApp;
    server.resource["^/api/clients/unpair-all$"]["POST"] = unpairAll;
    server.resource["^/api/clients/list$"]["GET"] = getClients;
    server.resource["^/api/pending-pairings$"]["GET"] = getPendingPairings;
    server.resource["^/api/clients/unpair$"]["POST"] = unpair;
    server.resource["^/api/apps/close$"]["POST"] = closeApp;
    server.resource["^/api/covers/upload$"]["POST"] = uploadCover;
    server.resource["^/api/covers/([0-9]+)$"]["GET"] = getCover;
    server.resource["^/images/sunshine.ico$"]["GET"] = getFaviconImage;
    server.resource["^/images/logo-sunshine-45.png$"]["GET"] = getSunshineLogoImage;
    server.resource["^/assets\\/.+$"]["GET"] = getNodeModules;
    server.config.reuse_address = true;
    server.config.address = net::get_bind_address(address_family);
    server.config.port = port_https;
    // Simple-Web-Server defaults max_request_streambuf_size to SIZE_MAX (no cap at all), so a
    // pre-auth client could stream an unbounded body and exhaust memory before authenticate()
    // ever runs. Cap it instead. The largest legitimate body this server accepts is uploadCover's
    // base64-encoded cover image (base64 costs ~4/3 the raw bytes, plus a thin JSON wrapper); a
    // multi-MB source PNG/JPEG comfortably fits well under this, so 8 MiB is a sane ceiling that
    // doesn't clip real cover uploads while still bounding the DoS surface.
    server.config.max_request_streambuf_size = 8 * 1024 * 1024;

    auto accept_and_run = [&](auto *server) {
      try {
        platf::set_thread_name("confighttp::tcp");
        server->start([](unsigned short port) {
          BOOST_LOG(info) << "Configuration UI available at [https://localhost:"sv << port << "]";
        });
      } catch (boost::system::system_error &err) {
        // It's possible the exception gets thrown after calling server->stop() from a different thread
        if (shutdown_event->peek()) {
          return;
        }

        BOOST_LOG(fatal) << "Couldn't start Configuration HTTPS server on port ["sv << port_https << "]: "sv << err.what();
        shutdown_event->raise(true);
        return;
      }
    };
    std::thread tcp {accept_and_run, &server};

    // Wait for any event
    shutdown_event->view();

    server.stop();

    tcp.join();
  }
}  // namespace confighttp
