#include "../tests_common.h"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <thread>

#include <boost/asio/ip/tcp.hpp>
#include <nlohmann/json.hpp>
#include <Simple-Web-Server/client_https.hpp>
#include <Simple-Web-Server/crypto.hpp>

#include "src/config.h"
#include "src/confighttp.h"
#include "src/crypto.h"
#include "src/file_handler.h"
#include "src/httpcommon.h"
#include "src/process.h"
#include "src/utility.h"

TEST(WebApps, RedirectsPageAliasesAndRejectsStaleApplicationEdits) {
  namespace fs = std::filesystem;
  using boost::asio::ip::tcp;
  using namespace std::chrono_literals;

  auto directory = fs::temp_directory_path() / ("moonwalk-application-test-" + crypto::rand_alphabet(10, "0123456789abcdef"));
  ASSERT_TRUE(fs::create_directory(directory));
  auto apps_path = (directory / "apps.json").string();
  const auto previous_config = config::sunshine;
  const auto previous_http = config::nvhttp;
  const auto previous_apps = config::stream.file_apps;
  const auto previous_origin = http::origin_web_ui_allowed;
  auto previous_mail = mail::man;
  auto restore = util::fail_guard([&] {
    config::sunshine = previous_config;
    config::nvhttp = previous_http;
    config::stream.file_apps = previous_apps;
    http::origin_web_ui_allowed = previous_origin;
    mail::man = std::move(previous_mail);
    proc::proc = proc::proc_t {};
    std::error_code ignored;
    fs::remove_all(directory, ignored);
  });

  const auto key = directory / "key.pem";
  const auto cert = directory / "cert.pem";
  const auto credentials = crypto::gen_creds("Browser tests", 2048);
  std::ofstream(key) << credentials.pkey;
  std::ofstream(cert) << credentials.x509;
  std::ofstream(apps_path) << R"({"env": {}, "apps": [{"name": "First Desktop"}, {"name": "Second Desktop"}]})";
  config::nvhttp.cert = cert.string();
  config::nvhttp.pkey = key.string();
  config::sunshine.bind_address = "127.0.0.1";
  config::sunshine.address_family = "ipv4";
  config::sunshine.username = "example-admin";
  config::sunshine.salt = "browser-test-salt";
  config::sunshine.password = util::hex(crypto::hash("example-password" + config::sunshine.salt)).to_string();
  http::origin_web_ui_allowed = net::from_enum_string("pc");
  config::stream.file_apps = apps_path;
  mail::man = std::make_shared<safe::mail_raw_t>();

  boost::asio::io_context io;
  tcp::acceptor reservation(io, {boost::asio::ip::address_v4::loopback(), 0});
  const auto port = reservation.local_endpoint().port();
  ASSERT_GT(port, 1025);
  config::sunshine.port = port - confighttp::PORT_HTTPS;
  reservation.close();

  std::thread server(confighttp::start);
  auto stop_server = util::fail_guard([&] {
    mail::man->event<bool>(mail::shutdown)->raise(true);
    server.join();
  });
  SimpleWeb::Client<SimpleWeb::HTTPS> client("127.0.0.1:" + std::to_string(port), false);
  client.config.timeout = 3;
  client.config.timeout_connect = 1;
  SimpleWeb::CaseInsensitiveMultimap headers {{"Content-Type", "application/json"}, {"Connection", "close"},
    {"Authorization", "Basic " + SimpleWeb::Crypto::Base64::encode("example-admin:example-password")}};
  std::shared_ptr<SimpleWeb::Client<SimpleWeb::HTTPS>::Response> first;
  const auto deadline = std::chrono::steady_clock::now() + 2s;
  while (!first && std::chrono::steady_clock::now() < deadline) {
    try {
      first = client.request("GET", "/api/apps", "", headers);
    } catch (const boost::system::system_error &) {
      std::this_thread::sleep_for(20ms);
    }
  }
  ASSERT_TRUE(first);
  ASSERT_TRUE(first->status_code.starts_with("200 "));

  for (const std::string page : {"/pin", "/apps", "/config", "/password", "/welcome", "/troubleshooting"}) {
    SCOPED_TRACE(page);
    // A trailing slash would make the browser look for relative assets one
    // directory too deep. Preserve the settings query during the redirect.
    const auto alias = client.request("GET", page + "/?tab=general&value=a%2Fb", "", headers);
    EXPECT_TRUE(alias->status_code.starts_with("307 "));
    const auto location = alias->header.find("Location");
    if (location != alias->header.end()) {
      EXPECT_EQ(location->second, page + "?tab=general&value=a%2Fb");
    } else {
      ADD_FAILURE() << "Missing Location header";
    }
  }
  const auto canonical = client.request("GET", "/config?tab=general", "", headers);
  EXPECT_TRUE(canonical->status_code.starts_with("200 "));
  const auto protected_page = client.request("GET", "/config");
  EXPECT_TRUE(protected_page->status_code.starts_with("401 "));
  const auto unrelated = client.request("GET", "/missing/");
  EXPECT_TRUE(unrelated->status_code.starts_with("404 "));

  ASSERT_TRUE(first->header.contains("ETag"));
  headers.emplace("If-Match", first->header.find("ETag")->second);

  const auto saved = client.request("POST", "/api/apps", R"({"index":0,"name":"Third Desktop"})", headers);
  ASSERT_TRUE(saved->status_code.starts_with("200 "));
  EXPECT_EQ(nlohmann::json::parse(saved->content.string())["status"], true);
  const auto after = file_handler::read_file(apps_path.c_str());
  EXPECT_NE(after.find("Third Desktop"), std::string::npos);

  const auto stale = client.request("DELETE", "/api/apps/0", "", headers);
  EXPECT_TRUE(stale->status_code.starts_with("412 "));
  EXPECT_EQ(file_handler::read_file(apps_path.c_str()), after);
  EXPECT_EQ(proc::proc.get_apps().size(), 2);
}
