#include <gtest/gtest.h>
#include <src/nvhttp.h>
#include <boost/asio/write.hpp>
#include <boost/asio/read.hpp>
#include <boost/asio/executor_work_guard.hpp>
#include <boost/asio/post.hpp>
#include <future>
#include <thread>

using namespace std::chrono_literals;

TEST(HttpsTeardown, PeerWithholdingCloseNotifyCannotBlockTheServerEventLoop) {
  using tcp = boost::asio::ip::tcp;
  using error_code = boost::system::error_code;
  boost::asio::io_context io;
  auto work = boost::asio::make_work_guard(io);
  boost::asio::ssl::context server_context(boost::asio::ssl::context::tls_server);
  boost::asio::ssl::context peer_context(boost::asio::ssl::context::tls_client);
  const auto credentials = crypto::gen_creds("TLS teardown fixture", 2048);
  server_context.use_certificate_chain(boost::asio::buffer(credentials.x509));
  server_context.use_private_key(boost::asio::buffer(credentials.pkey), boost::asio::ssl::context::pem);
  peer_context.set_verify_mode(boost::asio::ssl::verify_none);

  tcp::acceptor acceptor(io, tcp::endpoint(boost::asio::ip::address_v4::loopback(), 0));
  auto server = std::make_unique<nvhttp::SunshineHTTPS>(io, server_context);
  boost::asio::ssl::stream<tcp::socket> peer(io, peer_context);
  std::promise<error_code> accepted, connected, written, received, closed;
  auto server_ready = accepted.get_future(), peer_ready = connected.get_future();
  auto write_done = written.get_future(), read_done = received.get_future();
  auto close_done = closed.get_future();char close_byte = 0;
  std::promise<void> destruction_entered, next_callback;
  auto entered = destruction_entered.get_future(), progressed = next_callback.get_future();
  const std::string response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
  std::string body(response.size(), '\0');

  acceptor.async_accept(server->lowest_layer(), [&](const error_code &ec) {
    if (ec) { accepted.set_value(ec);return; }
    server->async_handshake(boost::asio::ssl::stream_base::server, [&](const error_code &error) { accepted.set_value(error); });
  });
  std::thread runner([&] { io.run(); });
  auto cleanup = util::fail_guard([&] {
    // Always release the old blocking destructor after the bounded assertion,
    // including assertion/setup failures. No fixture thread may outlive this test.
    error_code ignored;peer.lowest_layer().close(ignored);acceptor.close(ignored);
    io.stop();runner.join();
  });
  peer.lowest_layer().connect(acceptor.local_endpoint());
  peer.async_handshake(boost::asio::ssl::stream_base::client, [&](const error_code &error) { connected.set_value(error); });
  ASSERT_EQ(server_ready.wait_for(2s), std::future_status::ready);
  ASSERT_EQ(peer_ready.wait_for(2s), std::future_status::ready);
  ASSERT_FALSE(server_ready.get());ASSERT_FALSE(peer_ready.get());

  boost::asio::async_read(peer, boost::asio::buffer(body), [&](const error_code &error, std::size_t) { received.set_value(error); });
  boost::asio::async_write(*server, boost::asio::buffer(response), [&](const error_code &error, std::size_t) { written.set_value(error); });
  ASSERT_EQ(write_done.wait_for(2s), std::future_status::ready);
  ASSERT_EQ(read_done.wait_for(2s), std::future_status::ready);
  ASSERT_FALSE(write_done.get());ASSERT_FALSE(read_done.get());EXPECT_EQ(body, response);

  // The peer has read the complete response and deliberately performs no TLS
  // shutdown/read. Destruction runs on the same sole I/O thread as new requests.
  boost::asio::post(io, [&] {
    destruction_entered.set_value();server.reset();
    boost::asio::post(io, [&] { next_callback.set_value(); });
  });
  ASSERT_EQ(entered.wait_for(2s), std::future_status::ready);
  const auto progress = progressed.wait_for(300ms);
  EXPECT_EQ(progress, std::future_status::ready);
  if (progress == std::future_status::ready) {
    // Writable transport still delivers close_notify; the peer need not reply
    // before server teardown and unrelated I/O are allowed to finish.
    peer.async_read_some(boost::asio::buffer(&close_byte, 1), [&](const error_code &error, std::size_t) { closed.set_value(error); });
    ASSERT_EQ(close_done.wait_for(2s), std::future_status::ready);
    EXPECT_EQ(close_done.get(), boost::asio::error::eof);
  }
}
