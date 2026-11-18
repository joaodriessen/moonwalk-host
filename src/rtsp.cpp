/**
 * @file src/rtsp.cpp
 * @brief Definitions for RTSP streaming.
 */
#define BOOST_BIND_GLOBAL_PLACEHOLDERS

extern "C" {
#include <moonlight-common-c/src/Limelight-internal.h>
#include <moonlight-common-c/src/Rtsp.h>
}

// standard includes
#include <array>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <format>
#include <set>
#include <thread>
#include <unordered_map>
#include <utility>

// lib includes
#include <boost/asio.hpp>
#include <boost/bind.hpp>

// local includes
#include "config.h"
#include "globals.h"
#include "input.h"
#include "logging.h"
#include "network.h"
#include "process.h"
#include "protocol_parsing.h"
#include "rtsp.h"
#include "listener_readiness.h"
#include "stream.h"
#include "sync.h"
#include "video.h"

#ifdef __APPLE__
  // Session-acceptance gate (docs/design/2026-07-19-daemon-lifecycle-coupling.md §2B.2) -- same
  // guarded-include pattern used elsewhere for macOS-only platform headers (e.g. nvhttp.cpp's
  // platform/macos/misc.h include).
  #include "platform/macos/xpc_control.h"
#endif

namespace asio = boost::asio;

using asio::ip::tcp;
using asio::ip::udp;

using namespace std::literals;

#ifdef __APPLE__
  #include "platform/macos/audio_capture_policy.h"
#endif

#include "pending_launch_queue.h"

namespace rtsp_stream {
  // Recovery seatbelt constants (P1, docs/design/2026-07-12-black-screen-permanent-fix.md, Mode 3).
  // See should_retry_bind() (declared in rtsp.h) for why EADDRINUSE is retried at all.
  constexpr int RTSP_BIND_MAX_ATTEMPTS = 5;
  constexpr auto RTSP_BIND_RETRY_DELAY = 500ms;

  // Reserved for a genuine, unrecoverable RTSP startup failure (all bind retries exhausted). Must
  // be non-zero so launchd's KeepAlive={SuccessfulExit:false} relaunches Sunshine instead of
  // leaving it silently dead. Exit 0 stays reserved for intentional shutdown (SIGINT/SIGTERM/
  // tray-quit), which already pass 0 via their own lifetime::exit_sunshine(0, ...) calls.
  constexpr int RTSP_BIND_FAILURE_EXIT_CODE = 1;

  bool should_retry_bind(const boost::system::error_code &ec, int attempt, int max_attempts) {
    return ec == boost::asio::error::address_in_use && attempt < max_attempts;
  }

  void free_msg(PRTSP_MESSAGE msg) {
    freeMessage(msg);

    delete msg;
  }

#pragma pack(push, 1)

  struct encrypted_rtsp_header_t {
    // We set the MSB in encrypted RTSP messages to allow format-agnostic
    // parsing code to be able to tell encrypted from plaintext messages.
    static constexpr std::uint32_t ENCRYPTED_MESSAGE_TYPE_BIT = 0x80000000;

    uint8_t *payload() {
      return (uint8_t *) (this + 1);
    }

    std::uint32_t payload_length() {
      return util::endian::big<std::uint32_t>(typeAndLength) & ~ENCRYPTED_MESSAGE_TYPE_BIT;
    }

    bool is_encrypted() {
      return !!(util::endian::big<std::uint32_t>(typeAndLength) & ENCRYPTED_MESSAGE_TYPE_BIT);
    }

    // This field is the length of the payload + ENCRYPTED_MESSAGE_TYPE_BIT in big-endian
    std::uint32_t typeAndLength;

    // This field is the number used to initialize the bottom 4 bytes of the AES IV in big-endian
    std::uint32_t sequenceNumber;

    // This field is the AES GCM authentication tag
    std::uint8_t tag[16];
  };

#pragma pack(pop)

  class rtsp_server_t;

  using msg_t = util::safe_ptr<RTSP_MESSAGE, free_msg>;
  using cmd_func_t = std::function<void(rtsp_server_t *server, tcp::socket &, launch_session_t &, msg_t &&)>;

  void print_msg(PRTSP_MESSAGE msg);
  void cmd_not_found(tcp::socket &sock, launch_session_t &, msg_t &&req);
  void respond(tcp::socket &sock, launch_session_t &session, POPTION_ITEM options, int statuscode, const char *status_msg, int seqn, const std::string_view &payload);

  class socket_t: public std::enable_shared_from_this<socket_t> {
  public:
    socket_t(boost::asio::io_context &io_context, std::function<void(tcp::socket &sock, launch_session_t &, msg_t &&)> &&handle_data_fn):
        handle_data_fn {std::move(handle_data_fn)},
        sock {io_context} {
    }

    /**
     * @brief Queue an asynchronous read to begin the next message.
     */
    void read() {
      if (begin == std::end(msg_buf) || (session->rtsp_cipher && begin + sizeof(encrypted_rtsp_header_t) >= std::end(msg_buf))) {
        BOOST_LOG(error) << "RTSP: read(): Exceeded maximum rtsp packet size: "sv << msg_buf.size();

        respond(sock, *session, nullptr, 400, "BAD REQUEST", 0, {});

        boost::system::error_code ec;
        sock.close(ec);

        return;
      }

      if (session->rtsp_cipher) {
        // For encrypted RTSP, we will read the the entire header first
        boost::asio::async_read(sock, boost::asio::buffer(begin, sizeof(encrypted_rtsp_header_t)), boost::bind(&socket_t::handle_read_encrypted_header, shared_from_this(), boost::asio::placeholders::error, boost::asio::placeholders::bytes_transferred));
      } else {
        sock.async_read_some(
          boost::asio::buffer(begin, (std::size_t) (std::end(msg_buf) - begin)),
          boost::bind(
            &socket_t::handle_read_plaintext,
            shared_from_this(),
            boost::asio::placeholders::error,
            boost::asio::placeholders::bytes_transferred
          )
        );
      }
    }

    /**
     * @brief Handle the initial read of the header of an encrypted message.
     * @param socket The socket the message was received on.
     * @param ec The error code of the read operation.
     * @param bytes The number of bytes read.
     */
    static void handle_read_encrypted_header(std::shared_ptr<socket_t> &socket, const boost::system::error_code &ec, std::size_t bytes) {
      BOOST_LOG(debug) << "handle_read_encrypted_header(): Handle read of size: "sv << bytes << " bytes"sv;

      auto sock_close = util::fail_guard([&socket]() {
        boost::system::error_code ec;
        socket->sock.close(ec);

        if (ec) {
          BOOST_LOG(error) << "RTSP: handle_read_encrypted_header(): Couldn't close tcp socket: "sv << ec.message();
        }
      });

      if (ec || bytes < sizeof(encrypted_rtsp_header_t)) {
        BOOST_LOG(error) << "RTSP: handle_read_encrypted_header(): Couldn't read from tcp socket: "sv << ec.message();

        respond(socket->sock, *socket->session, nullptr, 400, "BAD REQUEST", 0, {});
        return;
      }

      auto header = (encrypted_rtsp_header_t *) socket->begin;
      if (!header->is_encrypted()) {
        BOOST_LOG(error) << "RTSP: handle_read_encrypted_header(): Rejecting unencrypted RTSP message"sv;

        respond(socket->sock, *socket->session, nullptr, 400, "BAD REQUEST", 0, {});
        return;
      }

      auto payload_length = header->payload_length();

      // Check if we have enough space to read this message
      if (socket->begin + sizeof(*header) + payload_length >= std::end(socket->msg_buf)) {
        BOOST_LOG(error) << "RTSP: handle_read_encrypted_header(): Exceeded maximum rtsp packet size: "sv << socket->msg_buf.size();

        respond(socket->sock, *socket->session, nullptr, 400, "BAD REQUEST", 0, {});
        return;
      }

      sock_close.disable();

      // Read the remainder of the header and full encrypted payload
      boost::asio::async_read(socket->sock, boost::asio::buffer(socket->begin + bytes, payload_length), boost::bind(&socket_t::handle_read_encrypted_message, socket->shared_from_this(), boost::asio::placeholders::error, boost::asio::placeholders::bytes_transferred));
    }

    /**
     * @brief Handle the final read of the content of an encrypted message.
     * @param socket The socket the message was received on.
     * @param ec The error code of the read operation.
     * @param bytes The number of bytes read.
     */
    static void handle_read_encrypted_message(std::shared_ptr<socket_t> &socket, const boost::system::error_code &ec, std::size_t bytes) {
      BOOST_LOG(debug) << "handle_read_encrypted(): Handle read of size: "sv << bytes << " bytes"sv;

      auto sock_close = util::fail_guard([&socket]() {
        boost::system::error_code ec;
        socket->sock.close(ec);

        if (ec) {
          BOOST_LOG(error) << "RTSP: handle_read_encrypted_message(): Couldn't close tcp socket: "sv << ec.message();
        }
      });

      auto header = (encrypted_rtsp_header_t *) socket->begin;
      auto payload_length = header->payload_length();
      auto seq = util::endian::big<std::uint32_t>(header->sequenceNumber);

      if (ec || bytes < payload_length) {
        BOOST_LOG(error) << "RTSP: handle_read_encrypted(): Couldn't read from tcp socket: "sv << ec.message();

        respond(socket->sock, *socket->session, nullptr, 400, "BAD REQUEST", 0, {});
        return;
      }

      // We use the deterministic IV construction algorithm specified in NIST SP 800-38D
      // Section 8.2.1. The sequence number is our "invocation" field and the 'RC' in the
      // high bytes is the "fixed" field. Because each client provides their own unique
      // key, our values in the fixed field need only uniquely identify each independent
      // use of the client's key with AES-GCM in our code.
      //
      // The sequence number is 32 bits long which allows for 2^32 RTSP messages to be
      // received from each client before the IV repeats.
      crypto::aes_t iv(12);
      std::copy_n((uint8_t *) &seq, sizeof(seq), std::begin(iv));
      iv[10] = 'C';  // Client originated
      iv[11] = 'R';  // RTSP

      std::vector<uint8_t> plaintext;
      if (socket->session->rtsp_cipher->decrypt(std::string_view {(const char *) header->tag, sizeof(header->tag) + bytes}, plaintext, &iv)) {
        BOOST_LOG(error) << "Failed to verify RTSP message tag"sv;

        respond(socket->sock, *socket->session, nullptr, 400, "BAD REQUEST", 0, {});
        return;
      }

      msg_t req {new msg_t::element_type {}};
      if (auto status = parseRtspMessage(req.get(), (char *) plaintext.data(), (int) plaintext.size())) {
        BOOST_LOG(error) << "Malformed RTSP message: ["sv << status << ']';

        respond(socket->sock, *socket->session, nullptr, 400, "BAD REQUEST", 0, {});
        return;
      }

      sock_close.disable();

      print_msg(req.get());

      socket->handle_data(std::move(req));
    }

    /**
     * @brief Queue an asynchronous read of the payload portion of a plaintext message.
     */
    void read_plaintext_payload() {
      if (begin == std::end(msg_buf)) {
        BOOST_LOG(error) << "RTSP: read_plaintext_payload(): Exceeded maximum rtsp packet size: "sv << msg_buf.size();

        respond(sock, *session, nullptr, 400, "BAD REQUEST", 0, {});

        boost::system::error_code ec;
        sock.close(ec);

        return;
      }

      sock.async_read_some(
        boost::asio::buffer(begin, (std::size_t) (std::end(msg_buf) - begin)),
        boost::bind(
          &socket_t::handle_plaintext_payload,
          shared_from_this(),
          boost::asio::placeholders::error,
          boost::asio::placeholders::bytes_transferred
        )
      );
    }

    /**
     * @brief Handle the read of the payload portion of a plaintext message.
     * @param socket The socket the message was received on.
     * @param ec The error code of the read operation.
     * @param bytes The number of bytes read.
     */
    static void handle_plaintext_payload(std::shared_ptr<socket_t> &socket, const boost::system::error_code &ec, std::size_t bytes) {
      BOOST_LOG(debug) << "handle_plaintext_payload(): Handle read of size: "sv << bytes << " bytes"sv;

      auto sock_close = util::fail_guard([&socket]() {
        boost::system::error_code ec;
        socket->sock.close(ec);

        if (ec) {
          BOOST_LOG(error) << "RTSP: handle_plaintext_payload(): Couldn't close tcp socket: "sv << ec.message();
        }
      });

      if (ec) {
        BOOST_LOG(error) << "RTSP: handle_plaintext_payload(): Couldn't read from tcp socket: "sv << ec.message();

        return;
      }

      auto end = socket->begin + bytes;
      msg_t req {new msg_t::element_type {}};
      if (auto status = parseRtspMessage(req.get(), socket->msg_buf.data(), (int) (end - socket->msg_buf.data()))) {
        BOOST_LOG(error) << "Malformed RTSP message: ["sv << status << ']';

        respond(socket->sock, *socket->session, nullptr, 400, "BAD REQUEST", 0, {});
        return;
      }

      sock_close.disable();

      auto fg = util::fail_guard([&socket]() {
        socket->read_plaintext_payload();
      });

      auto content_length = 0;
      for (auto option = req->options; option != nullptr; option = option->next) {
        if ("Content-length"sv == option->option) {
          BOOST_LOG(debug) << "Found Content-Length: "sv << option->content << " bytes"sv;

          // If content_length > bytes read, then we need to store current data read,
          // to be appended by the next read.
          std::string_view content {option->content};
          auto begin = std::find_if(std::begin(content), std::end(content), [](auto ch) {
            return (bool) std::isdigit(ch);
          });

          content_length = (int) util::from_chars(begin, std::end(content));
          break;
        }
      }

      if (end - socket->crlf >= content_length) {
        if (end - socket->crlf > content_length) {
          BOOST_LOG(warning) << "(end - socket->crlf) > content_length -- "sv << (std::size_t) (end - socket->crlf) << " > "sv << content_length;
        }

        fg.disable();
        print_msg(req.get());

        socket->handle_data(std::move(req));
      }

      socket->begin = end;
    }

    /**
     * @brief Handle the read of the header portion of a plaintext message.
     * @param socket The socket the message was received on.
     * @param ec The error code of the read operation.
     * @param bytes The number of bytes read.
     */
    static void handle_read_plaintext(std::shared_ptr<socket_t> &socket, const boost::system::error_code &ec, std::size_t bytes) {
      BOOST_LOG(debug) << "handle_read_plaintext(): Handle read of size: "sv << bytes << " bytes"sv;

      if (ec) {
        BOOST_LOG(error) << "RTSP: handle_read_plaintext(): Couldn't read from tcp socket: "sv << ec.message();

        boost::system::error_code ec;
        socket->sock.close(ec);

        if (ec) {
          BOOST_LOG(error) << "RTSP: handle_read_plaintext(): Couldn't close tcp socket: "sv << ec.message();
        }

        return;
      }

      auto fg = util::fail_guard([&socket]() {
        socket->read();
      });

      auto end = socket->begin + bytes;
      auto header_end = plaintext_header_end(
        std::string_view {socket->msg_buf.data(), (std::size_t) (end - socket->msg_buf.data())},
        (std::size_t) (socket->begin - socket->msg_buf.data())
      );
      if (header_end == std::string_view::npos) {
        socket->begin = end;

        return;
      }

      // Emulate read completion for payload data
      socket->begin = socket->msg_buf.data() + header_end;
      socket->crlf = socket->begin;
      auto buf_size = end - socket->begin;

      fg.disable();
      handle_plaintext_payload(socket, ec, buf_size);
    }

    void handle_data(msg_t &&req) {
      handle_data_fn(sock, *session, std::move(req));
    }

    std::function<void(tcp::socket &sock, launch_session_t &, msg_t &&)> handle_data_fn;

    tcp::socket sock;

    std::array<char, 2048> msg_buf;

    char *crlf;
    char *begin = msg_buf.data();

    std::shared_ptr<launch_session_t> session;
  };

  class rtsp_server_t {
  public:
    ~rtsp_server_t() {
      clear();
    }

    int bind(net::af_e af, std::uint16_t port, boost::system::error_code &ec) {
      acceptor.open(af == net::IPV4 ? tcp::v4() : tcp::v6(), ec);
      if (ec) {
        return -1;
      }

      acceptor.set_option(boost::asio::socket_base::reuse_address {true});

      auto bind_addr_str = net::get_bind_address(af);
      const auto bind_addr = boost::asio::ip::make_address(bind_addr_str, ec);
      if (ec) {
        BOOST_LOG(error) << "Invalid bind address: "sv << bind_addr_str << " - " << ec.message();
        return -1;
      }

      // Recovery seatbelt (P1, docs/design/2026-07-12-black-screen-permanent-fix.md, Mode 3): ride
      // out a still-draining socket left by a just-crashed prior instance. launchd relaunches us
      // within ~ThrottleInterval of a crash, and the old listener's socket is not always fully
      // reclaimed by the kernel yet -- EADDRINUSE here is very often transient, not a real conflict.
      // reuse_address is already set above; this retries the bind() call itself.
      for (int attempt = 1;; ++attempt) {
        acceptor.bind(tcp::endpoint(bind_addr, port), ec);
        if (!ec) {
          break;
        }

        if (!should_retry_bind(ec, attempt, RTSP_BIND_MAX_ATTEMPTS)) {
          return -1;
        }

        BOOST_LOG(warning) << "RTSP setup port ["sv << port << "] bind failed (attempt "sv << attempt
                            << "/"sv << RTSP_BIND_MAX_ATTEMPTS << "): "sv << ec.message()
                            << " -- retrying (likely a still-draining socket from a just-relaunched instance)"sv;
        std::this_thread::sleep_for(RTSP_BIND_RETRY_DELAY);
      }

      acceptor.listen(4096, ec);
      if (ec) {
        return -1;
      }

      next_socket = std::make_shared<socket_t>(io_context, [this](tcp::socket &sock, launch_session_t &session, msg_t &&msg) {
        handle_msg(sock, session, std::move(msg));
      });

      acceptor.async_accept(next_socket->sock, [this](const auto &ec) {
        handle_accept(ec);
      });

      return 0;
    }

    void handle_msg(tcp::socket &sock, launch_session_t &session, msg_t &&req) {
      auto func = _map_cmd_cb.find(req->message.request.command);
      if (func != std::end(_map_cmd_cb)) {
        func->second(this, sock, session, std::move(req));
      } else {
        cmd_not_found(sock, session, std::move(req));
      }

      boost::system::error_code ec;
      sock.shutdown(boost::asio::socket_base::shutdown_type::shutdown_both, ec);
    }

    void handle_accept(const boost::system::error_code &ec) {
      if (ec) {
        BOOST_LOG(error) << "Couldn't accept incoming connections: "sv << ec.message();

        // Stop server
        clear();
        return;
      }

      auto socket = std::move(next_socket);

      auto launch_session {pending_launches.current()};
      if (launch_session) {
        // Associate the current RTSP session with this socket and start reading
        socket->session = launch_session;
        socket->read();
      } else {
        // This can happen due to normal things like port scanning, so let's not make these visible by default
        BOOST_LOG(debug) << "No pending session for incoming RTSP connection"sv;

        // If there is no session pending, close the connection immediately
        boost::system::error_code ec;
        socket->sock.close(ec);
      }

      // Queue another asynchronous accept for the next incoming connection
      next_socket = std::make_shared<socket_t>(io_context, [this](tcp::socket &sock, launch_session_t &session, msg_t &&msg) {
        handle_msg(sock, session, std::move(msg));
      });
      acceptor.async_accept(next_socket->sock, [this](const auto &ec) {
        handle_accept(ec);
      });
    }

    void map(const std::string_view &type, cmd_func_t cb) {
      _map_cmd_cb.emplace(type, std::move(cb));
    }

    /**
     * @brief Launch a new streaming session.
     * @note If the client does not begin streaming within the ping_timeout,
     *       the session will be discarded.
     * @param launch_session Streaming session information.
     */
    bool session_raise(std::shared_ptr<launch_session_t> launch_session) {
      return pending_launches.raise(std::move(launch_session), config::stream.ping_timeout);
    }

    bool has_pending_launch() { return static_cast<bool>(pending_launches.current()); }
    void discard_pending_launch() { pending_launches.discard(); }
    void session_clear(uint32_t id) { pending_launches.clear(id); }

    /**
     * @brief Get the number of active sessions.
     * @return Count of active sessions.
     */
    int session_count() {
      auto lg = _session_slots.lock();
      return (int) _session_slots->size();
    }

    int active_session_count() {
      auto lg = _session_slots.lock();
      return std::count_if(_session_slots->begin(), _session_slots->end(), [](const auto &entry) {
        return stream::session::state(*entry) == stream::session::state_e::RUNNING;
      });
    }

    /**
     * @brief Snapshot the first active session's negotiated video params, under the same lock
     * `session_count()` uses. See `rtsp_stream::active_session_snapshot()`'s doc comment
     * (rtsp.h) for the full contract; single-session is the documented invariant here (see
     * `launch_session_t`'s doc comment), so "first slot" is "the" session in practice.
     */
    std::optional<session_snapshot_t> active_session_snapshot() {
      auto lg = _session_slots.lock();
      if (_session_slots->empty()) {
        return std::nullopt;
      }

      // Dereference the shared_ptr to a stream::session_t& and hand it to the opaque
      // stream::session:: accessor -- exactly the same pattern clear() uses just below for
      // state()/stop()/join() -- so this TU never needs stream::session_t to be a complete type.
      auto current = std::find_if(_session_slots->begin(), _session_slots->end(), [](const auto &entry) {
        return stream::session::state(*entry) == stream::session::state_e::RUNNING;
      });
      if (current == _session_slots->end()) return std::nullopt;
      auto snap = stream::session::snapshot(**current);

      session_snapshot_t out;
      out.width = snap.width;
      out.height = snap.height;
      out.fps = snap.fps;
      out.bitrate_kbps = snap.bitrate_kbps;
      out.session_seconds = snap.session_seconds;
      out.session_id = snap.session_id;
      out.device_uuid = snap.device_uuid;
      out.device_name = snap.device_name;
      return out;
    }
    bool terminate_session(uint32_t expected_session_id, std::string_view expected_device_uuid) {
      if (expected_device_uuid.empty()) return false;
      auto lock = _session_slots.lock();
      for (auto &entry : *_session_slots) {
        const auto current = stream::session::snapshot(*entry);
        if (current.session_id == expected_session_id && current.device_uuid == expected_device_uuid &&
            stream::session::state(*entry) == stream::session::state_e::RUNNING) {
          stream::session::stop(*entry);
          return true;
        }
      }
      return false;
    }

    /**
     * @brief Clear launch sessions.
     * @param all If true, clear all sessions. Otherwise, only clear timed out and stopped sessions.
     * @examples
     * clear(false);
     * @examples_end
     */
    void clear(bool all = true) {
      auto lg = _session_slots.lock();

      for (auto i = _session_slots->begin(); i != _session_slots->end();) {
        auto &slot = *(*i);
        if (all || stream::session::state(slot) == stream::session::state_e::STOPPING) {
          stream::session::stop(slot);
          stream::session::join(slot);

          i = _session_slots->erase(i);
        } else {
          i++;
        }
      }
    }

    /**
     * @brief Removes the provided session from the set of sessions.
     * @param session The session to remove.
     */
    void remove(const std::shared_ptr<stream::session_t> &session) {
      auto lg = _session_slots.lock();
      _session_slots->erase(session);
    }

    /**
     * @brief Inserts the provided session into the set of sessions.
     * @param session The session to insert.
     */
    void insert(const std::shared_ptr<stream::session_t> &session) {
      auto lg = _session_slots.lock();
      _session_slots->emplace(session);
      BOOST_LOG(info) << "New streaming session started [active sessions: "sv << _session_slots->size() << ']';
    }

    /**
     * @brief Runs an iteration of the RTSP server loop
     */
    void iterate() {
      // If we have a session, we will return to the server loop every
      // 500ms to allow session cleanup to happen.
      if (session_count() > 0) {
        io_context.run_one_for(500ms);
      } else {
        io_context.run_one();
      }
    }

    /**
     * @brief Stop the RTSP server.
     */
    void stop() {
      acceptor.close();
      io_context.stop();
      discard_pending_launch();
      clear();
    }

  private:
    std::unordered_map<std::string_view, cmd_func_t> _map_cmd_cb;

    sync_util::sync_t<std::set<std::shared_ptr<stream::session_t>>> _session_slots;

    boost::asio::io_context io_context;
    tcp::acceptor acceptor {io_context};
    pending_launch_queue_t<launch_session_t> pending_launches {io_context};

    std::shared_ptr<socket_t> next_socket;
  };

  rtsp_server_t server {};

  bool launch_session_raise(std::shared_ptr<launch_session_t> launch_session) {
    return server.session_raise(std::move(launch_session));
  }

  bool has_pending_launch() { return server.has_pending_launch(); }

  void launch_session_clear(uint32_t launch_session_id) {
    server.session_clear(launch_session_id);
  }

  int session_count() {
    // Ensure session_count is up-to-date
    server.clear(false);

    return server.session_count();
  }

  std::optional<session_snapshot_t> active_session_snapshot() {
    return server.active_session_snapshot();
  }

  int active_session_count() { return server.active_session_count(); }

#ifdef SUNSHINE_TESTS
  void test_insert_session(const std::shared_ptr<stream::session_t> &session) { server.insert(session); }
  void test_remove_session(const std::shared_ptr<stream::session_t> &session) { server.remove(session); }
#endif
  bool terminate_session(uint32_t expected_session_id, std::string_view expected_device_uuid) {
    return server.terminate_session(expected_session_id, expected_device_uuid);
  }

  void terminate_sessions() {
    server.discard_pending_launch();
    server.clear(true);
  }

  int send(tcp::socket &sock, const std::string_view &sv) {
    std::size_t bytes_send = 0;

    while (bytes_send != sv.size()) {
      boost::system::error_code ec;
      bytes_send += sock.send(boost::asio::buffer(sv.substr(bytes_send)), 0, ec);

      if (ec) {
        BOOST_LOG(error) << "RTSP: Couldn't send data over tcp socket: "sv << ec.message();
        return -1;
      }
    }

    return 0;
  }

  void respond(tcp::socket &sock, launch_session_t &session, msg_t &resp) {
    auto payload = std::make_pair(resp->payload, resp->payloadLength);

    // Restore response message for proper destruction
    auto lg = util::fail_guard([&]() {
      resp->payload = payload.first;
      resp->payloadLength = payload.second;
    });

    resp->payload = nullptr;
    resp->payloadLength = 0;

    int serialized_len;
    util::c_ptr<char> raw_resp {serializeRtspMessage(resp.get(), &serialized_len)};
    BOOST_LOG(debug)
      << "---Begin Response---"sv << std::endl
      << std::string_view {raw_resp.get(), (std::size_t) serialized_len} << std::endl
      << std::string_view {payload.first, (std::size_t) payload.second} << std::endl
      << "---End Response---"sv << std::endl;

    // Encrypt the RTSP message if encryption is enabled
    if (session.rtsp_cipher) {
      // We use the deterministic IV construction algorithm specified in NIST SP 800-38D
      // Section 8.2.1. The sequence number is our "invocation" field and the 'RH' in the
      // high bytes is the "fixed" field. Because each client provides their own unique
      // key, our values in the fixed field need only uniquely identify each independent
      // use of the client's key with AES-GCM in our code.
      //
      // The sequence number is 32 bits long which allows for 2^32 RTSP messages to be
      // sent to each client before the IV repeats.
      crypto::aes_t iv(12);
      session.rtsp_iv_counter++;
      std::copy_n((uint8_t *) &session.rtsp_iv_counter, sizeof(session.rtsp_iv_counter), std::begin(iv));
      iv[10] = 'H';  // Host originated
      iv[11] = 'R';  // RTSP

      // Allocate the message with an empty header and reserved space for the payload
      auto payload_length = serialized_len + payload.second;
      std::vector<uint8_t> message(sizeof(encrypted_rtsp_header_t));
      message.reserve(message.size() + payload_length);

      // Copy the complete plaintext into the message
      std::copy_n(raw_resp.get(), serialized_len, std::back_inserter(message));
      std::copy_n(payload.first, payload.second, std::back_inserter(message));

      // Initialize the message header
      auto header = (encrypted_rtsp_header_t *) message.data();
      header->typeAndLength = util::endian::big<std::uint32_t>(encrypted_rtsp_header_t::ENCRYPTED_MESSAGE_TYPE_BIT + payload_length);
      header->sequenceNumber = util::endian::big<std::uint32_t>(session.rtsp_iv_counter);

      // Encrypt the RTSP message in place
      session.rtsp_cipher->encrypt(std::string_view {(const char *) header->payload(), (std::size_t) payload_length}, header->tag, &iv);

      // Send the full encrypted message
      send(sock, std::string_view {(char *) message.data(), message.size()});
    } else {
      std::string_view tmp_resp {raw_resp.get(), (size_t) serialized_len};

      // Send the plaintext RTSP message header
      if (send(sock, tmp_resp)) {
        return;
      }

      // Send the plaintext RTSP message payload (if present)
      send(sock, std::string_view {payload.first, (std::size_t) payload.second});
    }
  }

  void respond(tcp::socket &sock, launch_session_t &session, POPTION_ITEM options, int statuscode, const char *status_msg, int seqn, const std::string_view &payload) {
    msg_t resp {new msg_t::element_type};
    createRtspResponse(resp.get(), nullptr, 0, const_cast<char *>("RTSP/1.0"), statuscode, const_cast<char *>(status_msg), seqn, options, const_cast<char *>(payload.data()), (int) payload.size());

    respond(sock, session, resp);
  }

  void cmd_not_found(tcp::socket &sock, launch_session_t &session, msg_t &&req) {
    respond(sock, session, nullptr, 404, "NOT FOUND", req->sequenceNumber, {});
  }

  void cmd_option(rtsp_server_t *server, tcp::socket &sock, launch_session_t &session, msg_t &&req) {
    OPTION_ITEM option {};

    // I know these string literals will not be modified
    option.option = const_cast<char *>("CSeq");

    auto seqn_str = std::to_string(req->sequenceNumber);
    option.content = const_cast<char *>(seqn_str.c_str());

    respond(sock, session, &option, 200, "OK", req->sequenceNumber, {});
  }

  std::string audio_stream_parameters(int channel_limit, std::string_view surround_params) {
    std::stringstream ss;
    if (!surround_params.empty() && channel_limit > 2) {
      // If we have our own surround parameters, advertise them twice first
      ss << "a=fmtp:97 surround-params="sv << surround_params << std::endl;
      ss << "a=fmtp:97 surround-params="sv << surround_params << std::endl;
    }

    for (int x = 0; x < audio::MAX_STREAM_CONFIG; ++x) {
      auto &stream_config = audio::stream_configs[x];
      if (stream_config.channelCount > channel_limit) {
        continue;
      }
      std::uint8_t mapping[platf::speaker::MAX_SPEAKERS];

      auto mapping_p = stream_config.mapping;

      /**
       * GFE advertises incorrect mapping for normal quality configurations,
       * as a result, Moonlight rotates all channels from index '3' to the right
       * To work around this, rotate channels to the left from index '3'
       */
      if (x == audio::SURROUND51 || x == audio::SURROUND71) {
        std::copy_n(mapping_p, stream_config.channelCount, mapping);
        std::rotate(mapping + 3, mapping + 4, mapping + audio::MAX_STREAM_CONFIG);

        mapping_p = mapping;
      }

      ss << "a=fmtp:97 surround-params="sv << stream_config.channelCount << stream_config.streams << stream_config.coupledStreams;

      std::for_each_n(mapping_p, stream_config.channelCount, [&ss](std::uint8_t digit) {
        ss << (char) (digit + '0');
      });

      ss << std::endl;
    }

    return ss.str();
  }

  void cmd_describe(rtsp_server_t *server, tcp::socket &sock, launch_session_t &session, msg_t &&req) {
    OPTION_ITEM option {};

    // I know these string literals will not be modified
    option.option = const_cast<char *>("CSeq");

    auto seqn_str = std::to_string(req->sequenceNumber);
    option.content = const_cast<char *>(seqn_str.c_str());

    std::stringstream ss;

    // Tell the client about our supported features
    ss << "a=x-ss-general.featureFlags:" << (uint32_t) platf::get_capabilities() << std::endl;

    // Always request new control stream encryption if the client supports it
    uint32_t encryption_flags_supported = SS_ENC_CONTROL_V2 | SS_ENC_AUDIO;
    uint32_t encryption_flags_requested = SS_ENC_CONTROL_V2;

    // Determine the encryption desired for this remote endpoint
    auto encryption_mode = net::encryption_mode_for_address(sock.remote_endpoint().address());
    if (encryption_mode != config::ENCRYPTION_MODE_NEVER) {
      // Advertise support for video encryption if it's not disabled
      encryption_flags_supported |= SS_ENC_VIDEO;

      // If it's mandatory, also request it to enable use if the client
      // didn't explicitly opt in, but it otherwise has support.
      if (encryption_mode == config::ENCRYPTION_MODE_MANDATORY) {
        encryption_flags_requested |= SS_ENC_VIDEO | SS_ENC_AUDIO;
      }
    }

    // Report supported and required encryption flags
    ss << "a=x-ss-general.encryptionSupported:" << encryption_flags_supported << std::endl;
    ss << "a=x-ss-general.encryptionRequested:" << encryption_flags_requested << std::endl;

    if (video::last_encoder_probe_supported_ref_frames_invalidation) {
      ss << "a=x-nv-video[0].refPicInvalidation:1"sv << std::endl;
    }

    if (video::active_hevc_mode != 1) {
      ss << "sprop-parameter-sets=AAAAAU"sv << std::endl;
    }

    if (video::active_av1_mode != 1) {
      ss << "a=rtpmap:98 AV1/90000"sv << std::endl;
    }

    const auto channel_limit =
#ifdef __APPLE__
      platf::macos::audio_channel_limit(config::audio.sink);
#else
      8;
#endif
    ss << audio_stream_parameters(channel_limit, session.surround_params);

    respond(sock, session, &option, 200, "OK", req->sequenceNumber, ss.str());
  }

  void cmd_setup(rtsp_server_t *server, tcp::socket &sock, launch_session_t &session, msg_t &&req) {
    OPTION_ITEM options[4] {};

    auto &seqn = options[0];
    auto &session_option = options[1];
    auto &port_option = options[2];
    auto &payload_option = options[3];

    seqn.option = const_cast<char *>("CSeq");

    auto seqn_str = std::to_string(req->sequenceNumber);
    seqn.content = const_cast<char *>(seqn_str.c_str());

    std::string_view target {req->message.request.target};
    auto eq_it = std::find(std::begin(target), std::end(target), '=');
    if (eq_it == std::end(target)) {
      cmd_not_found(sock, session, std::move(req));

      return;
    }
    auto begin = eq_it + 1;
    auto end = std::find(begin, std::end(target), '/');
    std::string_view type {begin, (size_t) std::distance(begin, end)};

    std::uint16_t port;
    if (type == "audio"sv) {
      port = net::map_port(stream::AUDIO_STREAM_PORT);
    } else if (type == "video"sv) {
      port = net::map_port(stream::VIDEO_STREAM_PORT);
    } else if (type == "control"sv) {
      port = net::map_port(stream::CONTROL_PORT);
    } else {
      cmd_not_found(sock, session, std::move(req));

      return;
    }

    seqn.next = &session_option;

    session_option.option = const_cast<char *>("Session");
    session_option.content = const_cast<char *>("DEADBEEFCAFE;timeout = 90");

    session_option.next = &port_option;

    // Moonlight merely requires 'server_port=<port>'
    auto port_value = std::format("server_port={}", static_cast<int>(port));

    port_option.option = const_cast<char *>("Transport");
    port_option.content = port_value.data();

    // Send identifiers that will be echoed in the other connections
    auto connect_data = std::to_string(session.control_connect_data);
    if (type == "control"sv) {
      payload_option.option = const_cast<char *>("X-SS-Connect-Data");
      payload_option.content = connect_data.data();
    } else {
      payload_option.option = const_cast<char *>("X-SS-Ping-Payload");
      payload_option.content = session.av_ping_payload.data();
    }

    port_option.next = &payload_option;

    respond(sock, session, &seqn, 200, "OK", req->sequenceNumber, {});
  }

  void cmd_announce(rtsp_server_t *server, tcp::socket &sock, launch_session_t &session, msg_t &&req) {
    OPTION_ITEM option {};

    // I know these string literals will not be modified
    option.option = const_cast<char *>("CSeq");

    auto seqn_str = std::to_string(req->sequenceNumber);
    option.content = const_cast<char *>(seqn_str.c_str());

    // A launch_session_t may only be consumed by a single ANNOUNCE. Multiple RTSP TCP
    // connections can race in while the launch session is pending (before the ENet
    // control connection attaches and pops it via session_clear()), so guard against
    // a second ANNOUNCE spawning a duplicate streaming session from the same launch.
    if (session.consumed.exchange(true)) {
      BOOST_LOG(warning) << "Rejecting duplicate ANNOUNCE for an already-consumed RTSP launch session"sv;

      respond(sock, session, &option, 403, "Forbidden", req->sequenceNumber, {});
      return;
    }

    auto failed_launch = util::fail_guard([&] { session.pending.expire(); });

#ifdef __APPLE__
    // Session-acceptance gate (§2B.2, defense in depth): refuse to actually launch a stream
    // session while no code-signature-validated SkylightMenu peer is attached. Covers the
    // sub-second window between menu detach (the NOTE_EXIT fast path / presence-window
    // self-check firing) and full process teardown -- the primary capture gate (main.cpp) only
    // protects daemon STARTUP, not an already-running daemon whose menu just detached.
    if (!platf::macos::is_validated_menu_attached()) {
      BOOST_LOG(warning) << "Rejecting RTSP ANNOUNCE -- no validated SkylightMenu peer attached"sv;

      respond(sock, session, &option, 503, "Service Unavailable", req->sequenceNumber, {});
      return;
    }
#endif

    std::string_view payload {req->payload, (size_t) req->payloadLength};

    std::vector<std::string_view> lines;

    auto whitespace = [](char ch) {
      return ch == '\n' || ch == '\r';
    };

    {
      auto pos = std::begin(payload);
      auto begin = pos;
      while (pos != std::end(payload)) {
        if (whitespace(*pos++)) {
          lines.emplace_back(begin, pos - begin - 1);

          while (pos != std::end(payload) && whitespace(*pos)) {
            ++pos;
          }
          begin = pos;
        }
      }
    }

    std::string_view client;
    std::unordered_map<std::string_view, std::string_view> args;

    for (auto line : lines) {
      auto type = line.substr(0, 2);
      if (type == "s="sv) {
        client = line.substr(2);
      } else if (type == "a=") {
        auto pos = line.find(':');

        auto name = line.substr(2, pos - 2);
        auto val = line.substr(pos + 1);

        if (!val.empty() && val[val.size() - 1] == ' ') {
          val = val.substr(0, val.size() - 1);
        }
        args.emplace(name, val);
      }
    }

    // Initialize any omitted parameters to defaults
    args.try_emplace("x-nv-video[0].encoderCscMode"sv, "0"sv);
    args.try_emplace("x-nv-vqos[0].bitStreamFormat"sv, "0"sv);
    args.try_emplace("x-nv-video[0].dynamicRangeMode"sv, "0"sv);
    args.try_emplace("x-nv-aqos.packetDuration"sv, "5"sv);
    args.try_emplace("x-nv-general.useReliableUdp"sv, "1"sv);
    args.try_emplace("x-nv-vqos[0].fec.minRequiredFecPackets"sv, "0"sv);
    args.try_emplace("x-nv-general.featureFlags"sv, "135"sv);
    args.try_emplace("x-ml-general.featureFlags"sv, "0"sv);
    args.try_emplace("x-nv-vqos[0].qosTrafficType"sv, "5"sv);
    args.try_emplace("x-nv-aqos.qosTrafficType"sv, "4"sv);
    args.try_emplace("x-ml-video.configuredBitrateKbps"sv, "0"sv);
    args.try_emplace("x-ss-general.encryptionEnabled"sv, "0"sv);
    args.try_emplace("x-ss-video[0].chromaSamplingType"sv, "0"sv);
    args.try_emplace("x-ss-video[0].intraRefresh"sv, "0"sv);
    args.try_emplace("x-nv-video[0].clientRefreshRateX100"sv, "0"sv);

    stream::config_t config;

    std::int64_t configuredBitrateKbps;
    config.audio.flags[audio::config_t::HOST_AUDIO] = session.host_audio;
    try {
      config.audio.channels = (int) util::from_view(args.at("x-nv-audio.surround.numChannels"sv));
      config.audio.mask = (int) util::from_view(args.at("x-nv-audio.surround.channelMask"sv));
#ifdef __APPLE__
      if (!platf::macos::audio_channels_supported(config::audio.sink, config.audio.channels)) {
        BOOST_LOG(warning) << "Requested audio channel layout is unavailable for the selected Mac source; native system audio requires stereo"sv;
        respond(sock, session, &option, 400, "Selected Mac audio source requires stereo", req->sequenceNumber, {});
        return;
      }
#endif
      config.audio.packetDuration = (int) util::from_view(args.at("x-nv-aqos.packetDuration"sv));
      if (config.audio.packetDuration < 1 || config.audio.packetDuration > 1000) {
        respond(sock, session, &option, 400, "BAD REQUEST", req->sequenceNumber, {});
        return;
      }

      config.audio.flags[audio::config_t::HIGH_QUALITY] =
        util::from_view(args.at("x-nv-audio.surround.AudioQuality"sv));

      config.controlProtocolType = (int) util::from_view(args.at("x-nv-general.useReliableUdp"sv));
      config.packetsize = (int) util::from_view(args.at("x-nv-video[0].packetSize"sv));
      if (config.packetsize < 64 || config.packetsize > 65535) {
        respond(sock, session, &option, 400, "BAD REQUEST", req->sequenceNumber, {});
        return;
      }
      config.minRequiredFecPackets = (int) util::from_view(args.at("x-nv-vqos[0].fec.minRequiredFecPackets"sv));
      config.mlFeatureFlags = (int) util::from_view(args.at("x-ml-general.featureFlags"sv));
      config.audioQosType = (int) util::from_view(args.at("x-nv-aqos.qosTrafficType"sv));
      config.videoQosType = (int) util::from_view(args.at("x-nv-vqos[0].qosTrafficType"sv));
      config.encryptionFlagsEnabled = (uint32_t) util::from_view(args.at("x-ss-general.encryptionEnabled"sv));

      // Legacy clients use nvFeatureFlags to indicate support for audio encryption
      if (util::from_view(args.at("x-nv-general.featureFlags"sv)) & 0x20) {
        config.encryptionFlagsEnabled |= SS_ENC_AUDIO;
      }

      config.monitor.height = (int) util::from_view(args.at("x-nv-video[0].clientViewportHt"sv));
      config.monitor.width = (int) util::from_view(args.at("x-nv-video[0].clientViewportWd"sv));
      if (config.monitor.width < 1 || config.monitor.width > 65535 || config.monitor.height < 1 || config.monitor.height > 65535) {
        respond(sock, session, &option, 400, "BAD REQUEST", req->sequenceNumber, {});
        return;
      }
      config.monitor.framerate = (int) util::from_view(args.at("x-nv-video[0].maxFPS"sv));
      if (config.monitor.framerate < 1 || config.monitor.framerate > 1000) {
        respond(sock, session, &option, 400, "BAD REQUEST", req->sequenceNumber, {});
        return;
      }
      config.monitor.framerateX100 = (int) util::from_view(args.at("x-nv-video[0].clientRefreshRateX100"sv));
      // Validate framerateX100 against framerate. Some clients (e.g. Moonlight Android) send the
      // client display's refresh rate as clientRefreshRateX100, which may differ from the requested
      // streaming framerate. Discard framerateX100 if the derived fps is not within 1% of framerate.
      if (config.monitor.framerateX100 > 0) {
        double fps_strict = config.monitor.framerateX100 / 100.0;
        double ratio = fps_strict / config.monitor.framerate;
        if (ratio < 0.99 || ratio > 1.01) {
          config.monitor.framerateX100 = 0;
        }
      }
      config.monitor.bitrate = (int) util::from_view(args.at("x-nv-vqos[0].bw.maximumBitrateKbps"sv));
      config.monitor.slicesPerFrame = (int) util::from_view(args.at("x-nv-video[0].videoEncoderSlicesPerFrame"sv));
      config.monitor.numRefFrames = (int) util::from_view(args.at("x-nv-video[0].maxNumReferenceFrames"sv));
      config.monitor.encoderCscMode = (int) util::from_view(args.at("x-nv-video[0].encoderCscMode"sv));
      config.monitor.videoFormat = (int) util::from_view(args.at("x-nv-vqos[0].bitStreamFormat"sv));
      config.monitor.dynamicRange = (int) util::from_view(args.at("x-nv-video[0].dynamicRangeMode"sv));
      config.monitor.chromaSamplingType = (int) util::from_view(args.at("x-ss-video[0].chromaSamplingType"sv));
      config.monitor.enableIntraRefresh = (int) util::from_view(args.at("x-ss-video[0].intraRefresh"sv));

      configuredBitrateKbps = util::from_view(args.at("x-ml-video.configuredBitrateKbps"sv));
    } catch (std::out_of_range &) {
      respond(sock, session, &option, 400, "BAD REQUEST", req->sequenceNumber, {});
      return;
    }

    // When using stereo audio, the audio quality is (strangely) indicated by whether the Host field
    // in the RTSP message matches a local interface's IP address. Fortunately, Moonlight always sends
    // 0.0.0.0 when it wants low quality, so it is easy to check without enumerating interfaces.
    if (config.audio.channels == 2) {
      for (auto option = req->options; option != nullptr; option = option->next) {
        if ("Host"sv == option->option) {
          std::string_view content {option->content};
          BOOST_LOG(debug) << "Found Host: "sv << content;
          config.audio.flags[audio::config_t::HIGH_QUALITY] = (content.find("0.0.0.0"sv) == std::string::npos);
        }
      }
    } else if (session.surround_params.length() > 3) {
      // Channels
      std::uint8_t c = session.surround_params[0] - '0';
      // Streams
      std::uint8_t n = session.surround_params[1] - '0';
      // Coupled streams
      std::uint8_t m = session.surround_params[2] - '0';
      auto valid = false;
      if ((c == 6 || c == 8) && c == config.audio.channels && n + m == c && session.surround_params.length() == c + 3) {
        config.audio.customStreamParams.channelCount = c;
        config.audio.customStreamParams.streams = n;
        config.audio.customStreamParams.coupledStreams = m;
        valid = true;
        for (std::uint8_t i = 0; i < c; i++) {
          config.audio.customStreamParams.mapping[i] = session.surround_params[i + 3] - '0';
          if (config.audio.customStreamParams.mapping[i] >= c) {
            valid = false;
            break;
          }
        }
      }
      config.audio.flags[audio::config_t::CUSTOM_SURROUND_PARAMS] = valid;
    }
    if (session.continuous_audio) {
      BOOST_LOG(info) << "Client requested continuous audio"sv;
      config.audio.flags[audio::config_t::CONTINUOUS_AUDIO] = true;
    }

    // If the client sent a configured bitrate, we will choose the actual bitrate ourselves
    // by using FEC percentage and audio quality settings. If the calculated bitrate ends up
    // too low, we'll allow it to exceed the limits rather than reducing the encoding bitrate
    // down to nearly nothing.
    if (configuredBitrateKbps) {
      BOOST_LOG(debug) << "Client configured bitrate is "sv << configuredBitrateKbps << " Kbps"sv;

      // If the FEC percentage isn't too high, adjust the configured bitrate to ensure video
      // traffic doesn't exceed the user's selected bitrate when the FEC shards are included.
      if (config::stream.fec_percentage <= 80) {
        configuredBitrateKbps /= 100.f / (100 - config::stream.fec_percentage);
      }

      // Adjust the bitrate to account for audio traffic bandwidth usage (capped at 20% reduction).
      // The bitrate per channel is 256 Kbps for high quality mode and 96 Kbps for normal quality.
      auto audioBitrateAdjustment = (config.audio.flags[audio::config_t::HIGH_QUALITY] ? 256 : 96) * config.audio.channels;
      configuredBitrateKbps -= std::min((std::int64_t) audioBitrateAdjustment, configuredBitrateKbps / 5);

      // Reduce it by another 500Kbps to account for A/V packet overhead and control data
      // traffic (capped at 10% reduction).
      configuredBitrateKbps -= std::min((std::int64_t) 500, configuredBitrateKbps / 10);

      BOOST_LOG(debug) << "Final adjusted video encoding bitrate is "sv << configuredBitrateKbps << " Kbps"sv;
      config.monitor.bitrate = (int) configuredBitrateKbps;
    }

    if (session.adaptive_bitrate) {
      config.monitor.adaptive_bitrate = std::make_shared<video::adaptive_bitrate_controller>(config::video.max_bitrate > 0 ? std::min(config.monitor.bitrate, config::video.max_bitrate) : config.monitor.bitrate, config::video.max_bitrate > 0 ? config::video.max_bitrate : 150000);
    }

    if (config.monitor.videoFormat == 1 && video::active_hevc_mode == 1) {
      BOOST_LOG(warning) << "HEVC is disabled, yet the client requested HEVC"sv;

      respond(sock, session, &option, 400, "BAD REQUEST", req->sequenceNumber, {});
      return;
    }

    if (config.monitor.videoFormat == 2 && video::active_av1_mode == 1) {
      BOOST_LOG(warning) << "AV1 is disabled, yet the client requested AV1"sv;

      respond(sock, session, &option, 400, "BAD REQUEST", req->sequenceNumber, {});
      return;
    }

    // Check that any required encryption is enabled
    auto encryption_mode = net::encryption_mode_for_address(sock.remote_endpoint().address());
    if (encryption_mode == config::ENCRYPTION_MODE_MANDATORY &&
        (config.encryptionFlagsEnabled & (SS_ENC_VIDEO | SS_ENC_AUDIO)) != (SS_ENC_VIDEO | SS_ENC_AUDIO)) {
      BOOST_LOG(error) << "Rejecting client that cannot comply with mandatory encryption requirement"sv;

      respond(sock, session, &option, 403, "Forbidden", req->sequenceNumber, {});
      return;
    }

    const bool accepted = session.pending.accept([&] {
      auto stream_session = stream::session::alloc(config, session);
      server->insert(stream_session);
      if (stream::session::start(*stream_session, sock.remote_endpoint().address().to_string())) {
        server->remove(stream_session);
        return false;
      }
      return true;
    });
    if (!accepted) {
      BOOST_LOG(error) << "Launch expired or failed before streaming could start"sv;
      respond(sock, session, &option, 500, "Launch expired or failed", req->sequenceNumber, {});
      return;
    }
    failed_launch.disable();

    respond(sock, session, &option, 200, "OK", req->sequenceNumber, {});
  }

  void cmd_play(rtsp_server_t *server, tcp::socket &sock, launch_session_t &session, msg_t &&req) {
    OPTION_ITEM option {};

    // I know these string literals will not be modified
    option.option = const_cast<char *>("CSeq");

    auto seqn_str = std::to_string(req->sequenceNumber);
    option.content = const_cast<char *>(seqn_str.c_str());

    respond(sock, session, &option, 200, "OK", req->sequenceNumber, {});
  }

  void start() {
    platf::set_thread_name("rtsp");
    auto shutdown_event = mail::man->event<bool>(mail::shutdown);

    server.map("OPTIONS"sv, &cmd_option);
    server.map("DESCRIBE"sv, &cmd_describe);
    server.map("SETUP"sv, &cmd_setup);
    server.map("ANNOUNCE"sv, &cmd_announce);
    server.map("PLAY"sv, &cmd_play);

    boost::system::error_code ec;
    if (server.bind(net::af_from_enum_string(config::sunshine.address_family), net::map_port(rtsp_stream::RTSP_SETUP_PORT), ec)) {
      BOOST_LOG(fatal) << "Couldn't bind RTSP server to port ["sv << net::map_port(rtsp_stream::RTSP_SETUP_PORT) << "], " << ec.message();
      shutdown_event->raise(true);

      // Recovery seatbelt (P1, docs/design/2026-07-12-black-screen-permanent-fix.md, Mode 3): this
      // is a genuine, unrecoverable startup failure -- server.bind() above already retried past a
      // transiently draining socket (see should_retry_bind()). Exit NON-ZERO so launchd's
      // KeepAlive={SuccessfulExit:false} relaunches us instead of leaving Sunshine silently,
      // permanently dead. (Previously this path fell through to main()'s default exit code of 0,
      // which reads to launchd as "finished on purpose, don't relaunch".)
      lifetime::exit_sunshine(RTSP_BIND_FAILURE_EXIT_CODE, true);

      return;
    }

    net::set_listener_ready(net::listener_kind::rtsp,true);
    auto listener_guard=util::fail_guard([] {net::set_listener_ready(net::listener_kind::rtsp,false);});

    // Test hook (P0 instrumentation, docs/design/2026-07-12-black-screen-permanent-fix.md §5 Phase
    // 0): deterministically reproduce the exact crash/relaunch race Mode 3 fixes -- abort()
    // immediately after a successful bind so a relaunched instance has to bind past our own
    // still-draining socket, without waiting for a real crash to happen. Env-var gated, off by
    // default, never armed in normal operation; not a compile-time flag so it needs no separate
    // build.
    if (std::getenv("SUNSHINE_TEST_FORCE_CRASH_AFTER_BIND") != nullptr) {
      BOOST_LOG(warning) << "SUNSHINE_TEST_FORCE_CRASH_AFTER_BIND set -- aborting immediately after RTSP bind to simulate the crash/relaunch race"sv;
      std::abort();
    }

    std::thread rtsp_thread {[&shutdown_event] {
      platf::set_thread_name("rtsp::handler");
      auto broadcast_shutdown_event = mail::man->event<bool>(mail::broadcast_shutdown);

      // When quit_app_on_disconnect is set, we terminate the running app once every session ends,
      // instead of leaving it in Sunshine's resumable "paused" state. `had_session` guards the
      // launch race: the app is running (proc.running() > 0) briefly before the first RTSP session
      // is set up, so we only terminate after a session has actually existed and then all are gone.
      bool had_session = false;

      while (!shutdown_event->peek()) {
        server.iterate();

        if (broadcast_shutdown_event->peek()) {
          server.clear();
        } else {
          // cleanup all stopped sessions
          server.clear(false);
        }

        if (config::sunshine.quit_app_on_disconnect) {
          if (server.session_count() > 0) {
            had_session = true;
          } else if (had_session) {
            had_session = false;
            if (proc::proc.running() > 0) {
              BOOST_LOG(info) << "All sessions ended — terminating app (quit_app_on_disconnect)"sv;
              // proc.terminate() runs the app's prep-cmd 'undo' (our display arrange 'stop'),
              // which handles display restore on macOS. Don't also call revert_configuration()
              // here — that's a second, racing display mutation and is a no-op on macOS anyway.
              //
              // Teardown gate (design: docs/design/vd-lifecycle.md §2A, Stage 3), closing the
              // ORIGINAL ghost-minting race: arrange-stop must never run while the stream
              // thread's VD release transaction is still in flight. Ordering evidence, from
              // this file's own call graph (not merely asserted): `server.clear(false)` a few
              // lines above (this same loop iteration, this same thread) synchronously calls
              // `stream::session::join()` for any STOPPING session, which itself synchronously
              // calls `platf::streaming_will_stop()` -> `virtual_display_destroy()` when it is
              // the last session (stream.cpp ~1938-1965) — and since S2, that call BLOCKS until
              // the helper's ACK + pid reap before returning. So on THIS mainline path the VD
              // teardown has, in practice, already fully completed by the time control reaches
              // here: `server.clear(false)` runs strictly before this `if` block, on the same
              // thread, in the same call stack, with no yield in between. The wait below is
              // therefore expected to resolve immediately (0ms) in the common case; it exists
              // as defense-in-depth against any other path that could reach this point without
              // having gone through `clear(false)` first (e.g. a future refactor), and it is
              // ALWAYS bounded — proceeding on timeout, never hanging app-quit on VD teardown.
              if (platf::vd_teardown_wait(3s)) {
                BOOST_LOG(debug) << "VD teardown confirmed before app terminate"sv;
              } else {
                BOOST_LOG(warning) << "VD teardown not confirmed within 3s — proceeding (bounded)"sv;
              }
              proc::proc.terminate();
            }
          }
        }
      }

      server.clear();
    }};

    // Wait for shutdown
    shutdown_event->view();

    // Stop the server and join the server thread
    server.stop();
    rtsp_thread.join();
  }

  void print_msg(PRTSP_MESSAGE msg) {
    std::string_view type = msg->type == TYPE_RESPONSE ? "RESPONSE"sv : "REQUEST"sv;

    std::string_view payload {msg->payload, (size_t) msg->payloadLength};
    std::string_view protocol {msg->protocol};
    auto seqnm = msg->sequenceNumber;
    std::string_view messageBuffer {msg->messageBuffer};

    BOOST_LOG(debug) << "type ["sv << type << ']';
    BOOST_LOG(debug) << "sequence number ["sv << seqnm << ']';
    BOOST_LOG(debug) << "protocol :: "sv << protocol;
    BOOST_LOG(debug) << "payload :: "sv << payload;

    if (msg->type == TYPE_RESPONSE) {
      auto &resp = msg->message.response;

      auto statuscode = resp.statusCode;
      std::string_view status {resp.statusString};

      BOOST_LOG(debug) << "statuscode :: "sv << statuscode;
      BOOST_LOG(debug) << "status :: "sv << status;
    } else {
      auto &req = msg->message.request;

      std::string_view command {req.command};
      std::string_view target {req.target};

      BOOST_LOG(debug) << "command :: "sv << command;
      BOOST_LOG(debug) << "target :: "sv << target;
    }

    for (auto option = msg->options; option != nullptr; option = option->next) {
      std::string_view content {option->content};
      std::string_view name {option->option};

      BOOST_LOG(debug) << name << " :: "sv << content;
    }

    BOOST_LOG(debug) << "---Begin MessageBuffer---"sv << std::endl
                     << messageBuffer << std::endl
                     << "---End MessageBuffer---"sv << std::endl;
  }
}  // namespace rtsp_stream
