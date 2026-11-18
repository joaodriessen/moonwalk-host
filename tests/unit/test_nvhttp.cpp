/**
 * @file tests/unit/test_nvhttp.cpp
 * @brief Test src/nvhttp.cpp -- regression coverage for the width/height/fps launch-field clamps
 * shipped in commit 4bb9c90e, matching the sibling rtsp.cpp launch-field clamps documented (as an
 * integration-only gap) in tests/unit/test_rtsp.cpp.
 *
 * `nvhttp::make_launch_session(bool host_audio, const nvhttp::args_t &args)` (src/nvhttp.cpp:382)
 * has external linkage (declared inside `namespace nvhttp`, not an anonymous namespace, not
 * `static`) but is not exposed in nvhttp.h, so a forward declaration here is enough for the linker
 * to resolve it against nvhttp.cpp's real definition -- the same pattern used by
 * tests/unit/test_confighttp.cpp for confighttp.cpp's non-header-exposed validators. `args_t` is
 * itself just `nvhttp`'s alias for `SimpleWeb::CaseInsensitiveMultimap` (src/nvhttp.cpp:224), a
 * type independently defined in Simple-Web-Server/utility.hpp, so redeclaring the alias here does
 * not depend on any nvhttp.cpp implementation detail.
 *
 * `make_launch_session()` is genuinely unit-reachable end to end: it takes a plain
 * `args_t` value (no live socket/session state) and returns `nullptr` on rejection or a real
 * `std::shared_ptr<rtsp_stream::launch_session_t>` on acceptance -- both directly observable. A
 * valid 16-byte `rikey` and a `rikeyid` must be supplied for every case (including the reject
 * cases run *before* the width/height/fps checks) because `get_arg(args, "rikeyid")` has no
 * default and throws `std::out_of_range` if the key is absent (src/nvhttp.cpp:235-243).
 */
#include "../tests_common.h"

#include <Simple-Web-Server/server_http.hpp>

#include <src/rtsp.h>

namespace nvhttp {
  using args_t = SimpleWeb::CaseInsensitiveMultimap;
  std::shared_ptr<rtsp_stream::launch_session_t> make_launch_session(bool host_audio, const args_t &args);
  std::shared_ptr<rtsp_stream::launch_session_t> make_launch_session(bool host_audio, const args_t &args, std::string &validation_error);
}  // namespace nvhttp

namespace {
  nvhttp::args_t base_args(const std::string &mode) {
    nvhttp::args_t args;
    // 32 hex chars == 16 bytes, satisfying the unrelated (already-shipped) rikey-length guard
    // that runs before the width/height/fps checks under test.
    args.emplace("rikey", "0123456789abcdef0123456789abcdef");
    args.emplace("rikeyid", "1");
    args.emplace("mode", mode);
    return args;
  }
}  // namespace

// ---------------------------------------------------------------------
// Reject cases: width/height outside (0, 8192], fps outside (0, 240] must all yield nullptr
// (src/nvhttp.cpp:404-424).
// ---------------------------------------------------------------------

TEST(NvhttpMakeLaunchSessionTest, ZeroWidthIsRejected) {
  auto args = base_args("0x1080x60");
  EXPECT_EQ(nvhttp::make_launch_session(false, args), nullptr);
}

TEST(NvhttpMakeLaunchSessionTest, NegativeWidthIsRejected) {
  auto args = base_args("-1x1080x60");
  EXPECT_EQ(nvhttp::make_launch_session(false, args), nullptr);
}

TEST(NvhttpMakeLaunchSessionTest, WidthOverMaxIsRejected) {
  auto args = base_args("8193x1080x60");
  EXPECT_EQ(nvhttp::make_launch_session(false, args), nullptr);
}

TEST(NvhttpMakeLaunchSessionTest, ZeroHeightIsRejected) {
  auto args = base_args("1920x0x60");
  EXPECT_EQ(nvhttp::make_launch_session(false, args), nullptr);
}

TEST(NvhttpMakeLaunchSessionTest, NegativeHeightIsRejected) {
  auto args = base_args("1920x-1x60");
  EXPECT_EQ(nvhttp::make_launch_session(false, args), nullptr);
}

TEST(NvhttpMakeLaunchSessionTest, HeightOverMaxIsRejected) {
  auto args = base_args("1920x8193x60");
  EXPECT_EQ(nvhttp::make_launch_session(false, args), nullptr);
}

TEST(NvhttpMakeLaunchSessionTest, ZeroFpsIsRejected) {
  auto args = base_args("1920x1080x0");
  EXPECT_EQ(nvhttp::make_launch_session(false, args), nullptr);
}

TEST(NvhttpMakeLaunchSessionTest, NegativeFpsIsRejected) {
  auto args = base_args("1920x1080x-1");
  EXPECT_EQ(nvhttp::make_launch_session(false, args), nullptr);
}

TEST(NvhttpMakeLaunchSessionTest, FpsOverMaxIsRejected) {
  auto args = base_args("1920x1080x241");
  EXPECT_EQ(nvhttp::make_launch_session(false, args), nullptr);
}

// ---------------------------------------------------------------------
// Accept cases: legit resolutions/framerates at or within the clamp boundaries must not be
// false-rejected.
// ---------------------------------------------------------------------

TEST(NvhttpMakeLaunchSessionTest, FullHdAt60IsAccepted) {
  auto args = base_args("1920x1080x60");
  auto session = nvhttp::make_launch_session(false, args);
  ASSERT_NE(session, nullptr);
  EXPECT_EQ(session->width, 1920);
  EXPECT_EQ(session->height, 1080);
  EXPECT_EQ(session->fps, 60);
}

TEST(NvhttpMakeLaunchSessionTest, FourKAt120IsAccepted) {
  auto args = base_args("3840x2160x120");
  auto session = nvhttp::make_launch_session(false, args);
  ASSERT_NE(session, nullptr);
  EXPECT_EQ(session->width, 3840);
  EXPECT_EQ(session->height, 2160);
  EXPECT_EQ(session->fps, 120);
}

TEST(NvhttpMakeLaunchSessionTest, EightKAt30IsAccepted) {
  auto args = base_args("7680x4320x30");
  auto session = nvhttp::make_launch_session(false, args);
  ASSERT_NE(session, nullptr);
  EXPECT_EQ(session->width, 7680);
  EXPECT_EQ(session->height, 4320);
  EXPECT_EQ(session->fps, 30);
}

TEST(NvhttpMakeLaunchSessionTest, ExactMaxWidthHeightAndFpsBoundaryIsAccepted) {
  // The clamp is "> 8192" / "> 240", so exactly 8192 and exactly 240 must both still pass --
  // guards against an off-by-one if the condition is ever refactored to "|| width >= 8192".
  auto args = base_args("8192x8192x240");
  auto session = nvhttp::make_launch_session(false, args);
  ASSERT_NE(session, nullptr);
  EXPECT_EQ(session->width, 8192);
  EXPECT_EQ(session->height, 8192);
  EXPECT_EQ(session->fps, 240);
}

TEST(NvhttpMakeLaunchSessionTest, OptionalSettingsAreStrictAndPreserveLegacyDefaults) {
  auto args = base_args("1920x1080x60");
  std::string error;
  auto session = nvhttp::make_launch_session(false, args, error);
  ASSERT_NE(session, nullptr);
  EXPECT_EQ(session->desktop_scale, 0);
  EXPECT_FALSE(session->adaptive_bitrate);
  args.emplace("desktopScale", "2"); args.emplace("adaptiveBitrate", "1");
  session = nvhttp::make_launch_session(false, args, error);
  ASSERT_NE(session, nullptr);
  EXPECT_EQ(session->desktop_scale, 2);
  EXPECT_TRUE(session->adaptive_bitrate);
  args.erase("desktopScale"); args.emplace("desktopScale", "3");
  EXPECT_EQ(nvhttp::make_launch_session(false, args, error), nullptr);
  EXPECT_NE(error.find("desktop scale"), std::string::npos);
  EXPECT_EQ(error.find("rikey"), std::string::npos);
#ifdef __APPLE__
  args.erase("desktopScale"); args.emplace("desktopScale", "2");
  args.erase("mode"); args.emplace("mode", "1921x1080x60");
  EXPECT_EQ(nvhttp::make_launch_session(false, args, error), nullptr);
  EXPECT_NE(error.find("even"), std::string::npos);
#endif
}
