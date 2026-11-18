/**
 * @file src/platform/macos/misc.mm
 * @brief Miscellaneous definitions for macOS platform.
 */

// Required for IPV6_PKTINFO with Darwin headers
#ifndef __APPLE_USE_RFC_3542  // NOLINT(bugprone-reserved-identifier)
  #define __APPLE_USE_RFC_3542 1
#endif

// standard includes
#include <algorithm>
#include <chrono>
#include <cmath>
#include <fcntl.h>
#include <ifaddrs.h>
#include <sstream>
#include <unistd.h>

// platform includes
#include <ApplicationServices/ApplicationServices.h>
#include <AppKit/AppKit.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <net/if_dl.h>
#include <pwd.h>
#include <sys/qos.h>

// lib includes
#include <boost/asio/ip/address.hpp>
#include <boost/asio/ip/host_name.hpp>
#include <boost/process/v1.hpp>

// local includes
#include "misc.h"
#include "virtual_display.h"
#include "virtual_display_readiness.h"
#include "xpc_control.h"
#include "src/entry_handler.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/headless_gate.h"

using namespace std::literals;
namespace fs = std::filesystem;
namespace bp = boost::process::v1;

namespace platf::macos {
  uint32_t pending_display_generation() { return ::virtual_display_get_generation(); }
}

namespace platf {

  std::optional<cursor_image_t> capture_system_cursor(bool include_png) {
    @autoreleasepool {
      // This deprecated AppKit API is still the documented way to obtain the
      // cursor set by *another* application. NSCursor.currentCursor only sees
      // Skylight's own cursor; ScreenCaptureKit can only composite the system
      // cursor into a video frame, which would lag the instant client pointer.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      NSCursor *cursor = [NSCursor currentSystemCursor];
#pragma clang diagnostic pop
      if (!cursor || !cursor.image) {
        return std::nullopt;
      }

      NSImage *image = cursor.image;
      NSBitmapImageRep *bitmap = nil;
      for (NSImageRep *rep in image.representations) {
        if ([rep isKindOfClass:[NSBitmapImageRep class]] &&
            rep.pixelsWide > 0 && rep.pixelsHigh > 0 &&
            rep.pixelsWide <= 256 && rep.pixelsHigh <= 256 &&
            ((NSBitmapImageRep *) rep).bitsPerPixel == 32 &&
            !((NSBitmapImageRep *) rep).isPlanar) {
          if (!bitmap || rep.pixelsWide * rep.pixelsHigh > bitmap.pixelsWide * bitmap.pixelsHigh) {
            bitmap = (NSBitmapImageRep *) rep;
          }
        }
      }
      if (!bitmap) {
        NSRect rect = NSMakeRect(0, 0, image.size.width, image.size.height);
        CGImageRef cg_image = [image CGImageForProposedRect:&rect context:nil hints:nil];
        if (cg_image) {
          bitmap = [[[NSBitmapImageRep alloc] initWithCGImage:cg_image] autorelease];
        }
      }
      if (!bitmap || bitmap.pixelsWide < 1 || bitmap.pixelsHigh < 1 ||
          bitmap.pixelsWide > 256 || bitmap.pixelsHigh > 256 ||
          bitmap.bitsPerPixel != 32 || bitmap.isPlanar ||
          bitmap.bytesPerRow < bitmap.pixelsWide * 4 || !bitmap.bitmapData ||
          image.size.width <= 0 || image.size.height <= 0) {
        return std::nullopt;
      }

      cursor_image_t result;
      result.point_width = std::clamp((int) std::lround(image.size.width), 1, 256);
      result.point_height = std::clamp((int) std::lround(image.size.height), 1, 256);
      result.hot_x = std::clamp((int) std::lround(cursor.hotSpot.x * bitmap.pixelsWide / image.size.width), 0, (int) bitmap.pixelsWide - 1);
      result.hot_y = std::clamp((int) std::lround(cursor.hotSpot.y * bitmap.pixelsHigh / image.size.height), 0, (int) bitmap.pixelsHigh - 1);

      // Hash only actual pixels, never row padding (which need not be stable).
      // The hash is a per-poll change token, not a security primitive.
      std::uint64_t hash = 14695981039346656037ULL;
      auto mix = [&hash](std::uint8_t value) {
        hash = (hash ^ value) * 1099511628211ULL;
      };
      for (int value : {(int) bitmap.pixelsWide, (int) bitmap.pixelsHigh,
                        result.hot_x, result.hot_y, result.point_width, result.point_height}) {
        for (int byte = 0; byte < 4; ++byte) {
          mix((std::uint8_t) (value >> (byte * 8)));
        }
      }
      const auto *pixels = bitmap.bitmapData;
      for (NSInteger row = 0; row < bitmap.pixelsHigh; ++row) {
        for (NSInteger col = 0; col < bitmap.pixelsWide * 4; ++col) {
          mix(pixels[row * bitmap.bytesPerRow + col]);
        }
      }
      result.hash = hash;

      if (include_png) {
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!png || png.length == 0 || png.length > 512 * 1024) {
          return std::nullopt;
        }
        result.png.assign((const char *) png.bytes, png.length);
      }
      return result;
    }
  }

// Even though the following two functions are available starting in macOS 10.15, they weren't
// actually in the Mac SDK until Xcode 12.2, the first to include the SDK for macOS 11
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 110000  // __MAC_11_0
  // If they're not in the SDK then we can use our own function definitions.
  // Need to use weak import so that this will link in macOS 10.14 and earlier
  extern "C" bool CGPreflightScreenCaptureAccess(void) __attribute__((weak_import));
  extern "C" bool CGRequestScreenCaptureAccess(void) __attribute__((weak_import));
#endif

  namespace {
    auto screen_capture_allowed = std::atomic<bool> {false};

    std::string display_reconfiguration_flags(CGDisplayChangeSummaryFlags flags) {
      struct flag_name_t {
        CGDisplayChangeSummaryFlags flag;
        const char *name;
      };
      static constexpr flag_name_t flag_names[] = {
        {kCGDisplayAddFlag, "add"},
        {kCGDisplayRemoveFlag, "remove"},
        {kCGDisplayEnabledFlag, "enabled"},
        {kCGDisplayDisabledFlag, "disabled"},
        {kCGDisplayMirrorFlag, "mirror"},
        {kCGDisplayUnMirrorFlag, "unmirror"},
        {kCGDisplaySetMainFlag, "set-main"},
        {kCGDisplaySetModeFlag, "mode-change"},
      };

      std::ostringstream names;
      bool first = true;
      for (const auto &entry : flag_names) {
        if ((flags & entry.flag) == 0) {
          continue;
        }
        if (!first) {
          names << '|';
        }
        names << entry.name;
        first = false;
      }
      return first ? "none" : names.str();
    }

    void display_reconfiguration_callback(CGDirectDisplayID display_id,
                                          CGDisplayChangeSummaryFlags flags,
                                          void *) {
      const auto timestamp_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
      BOOST_LOG(info) << "CoreGraphics display reconfiguration t_monotonic_ms=" << timestamp_ms
                      << " display=" << display_id
                      << " flags=0x" << std::hex << static_cast<uint32_t>(flags) << std::dec
                      << " (" << display_reconfiguration_flags(flags) << ')';
    }
  }  // namespace

  // Return whether screen capture is allowed for this process.
  bool is_screen_capture_allowed() {
    return screen_capture_allowed;
  }

  bool preflight_accessibility_access() { return AXIsProcessTrusted(); }

  // Fresh per-call Screen Recording preflight (see misc.h doc comment). Deliberately does NOT
  // read/write the is_screen_capture_allowed() cache above: that flag is a startup-time gate
  // (set once in init(), used to decide whether the daemon should even come up); this is a
  // per-request check so a grant/revoke while the daemon is already running is picked up on the
  // very next launch/resume. Same weak-import guard and availability check as init() above,
  // since these symbols only exist from macOS 10.15 on the SDKs enumerated there.
  bool preflight_screen_capture_access() {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
    if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:((NSOperatingSystemVersion) {10, 15, 0})] ||
        CGPreflightScreenCaptureAccess == nullptr || CGRequestScreenCaptureAccess == nullptr) {
      // Can't check on this OS version; assume allowed rather than block streaming outright.
      return true;
    }
    if (CGPreflightScreenCaptureAccess()) {
      return true;
    }
    BOOST_LOG(error) << "No screen capture permission! Rejecting launch/resume request."sv;
    BOOST_LOG(error) << "Please activate it in 'System Settings' -> 'Privacy & Security' -> 'Screen Recording'"sv;
    return false;
#pragma clang diagnostic pop
  }

  std::unique_ptr<deinit_t> init() {
    const CGError display_callback_result = CGDisplayRegisterReconfigurationCallback(
      display_reconfiguration_callback, nullptr);
    if (display_callback_result != kCGErrorSuccess) {
      BOOST_LOG(warning) << "Failed to register CoreGraphics display reconfiguration callback: "
                         << display_callback_result;
    }

    // S0+ (docs/design/menubar-app.md): start the XPC control listener for the native
    // SkylightMenu.app FIRST, unconditionally -- BEFORE the screen-capture permission gate
    // below. Non-blocking (see xpc_control.mm), never touches the capture/encode/protocol
    // path -- a failure here is logged and non-fatal to the daemon.
    //
    // S3 ORDERING NOTE (why this moved above the gate): S3 adds a permission-ONBOARDING view
    // that reads the daemon's live TCC state over this exact channel (`getPermissionState`)
    // to guide a user who has NOT yet granted Screen Recording. If this call stayed below the
    // gate (as in S0-S2), a fresh install with zero grants would `return nullptr` before ever
    // starting the XPC listener -- the app could never reach the daemon to show "not granted
    // yet" or walk the user to System Settings, exactly the scenario onboarding exists for.
    // Starting the listener unconditionally breaks that chicken-and-egg deadlock; it is still
    // read-only/inert with respect to capture (see xpc_control.mm's own comments) so this
    // reorder carries no new risk to the capture/protocol path itself.
    platf::macos::start_xpc_control_service();

    // This will generate a warning about CGPreflightScreenCaptureAccess and
    // CGRequestScreenCaptureAccess being unavailable before macOS 10.15, but
    // we have a guard to prevent it from being called on those earlier systems.
    // Unfortunately the supported way to silence this warning, using @available,
    // produces linker errors for __isPlatformVersionAtLeast, so we have to use
    // a different method.
    // We also ignore "tautological-pointer-compare" because when compiling with
    // Xcode 12.2 and later, these functions are not weakly linked and will never
    // be null, and therefore generate this warning. Since we are weakly linking
    // when compiling with earlier Xcode versions, the check for null is
    // necessary, and so we ignore the warning.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:((NSOperatingSystemVersion) {10, 15, 0})] &&
        // Double check that these weakly-linked symbols have been loaded:
        CGPreflightScreenCaptureAccess != nullptr && CGRequestScreenCaptureAccess != nullptr &&
        !CGPreflightScreenCaptureAccess()) {
      BOOST_LOG(error) << "No screen capture permission!"sv;
      BOOST_LOG(error) << "Please activate it in 'System Preferences' -> 'Privacy' -> 'Screen Recording'"sv;
      return nullptr;
    }
#pragma clang diagnostic pop
    // Record that we determined that we have the screen capture permission.
    screen_capture_allowed = true;

    // Read-only startup diagnostic. The explicit local XPC action is the sole prompt owner.
    BOOL accessibility_trusted = AXIsProcessTrusted();
    if (accessibility_trusted) {
      BOOST_LOG(info) << "Accessibility permission already granted."sv;
    } else {
      BOOST_LOG(warning) << "No Accessibility permission! Remote keyboard/mouse input will not work."sv;
      BOOST_LOG(warning) << "Please activate it in 'System Settings' -> 'Privacy & Security' -> 'Accessibility'"sv;
    }

    return std::make_unique<deinit_t>();
  }

  fs::path appdata() {
    const char *homedir;
    if ((homedir = getenv("HOME")) == nullptr) {
      homedir = getpwuid(geteuid())->pw_dir;
    }

    return fs::path {homedir} / ".config/skylight"sv;
  }

  using ifaddr_t = util::safe_ptr<ifaddrs, freeifaddrs>;

  ifaddr_t get_ifaddrs() {
    ifaddrs *p {nullptr};

    getifaddrs(&p);

    return ifaddr_t {p};
  }

  std::string from_sockaddr(const sockaddr *const ip_addr) {
    char data[INET6_ADDRSTRLEN] = {};

    auto family = ip_addr->sa_family;
    if (family == AF_INET6) {
      inet_ntop(AF_INET6, &((sockaddr_in6 *) ip_addr)->sin6_addr, data, INET6_ADDRSTRLEN);
    } else if (family == AF_INET) {
      inet_ntop(AF_INET, &((sockaddr_in *) ip_addr)->sin_addr, data, INET_ADDRSTRLEN);
    }

    return std::string {data};
  }

  std::pair<std::uint16_t, std::string> from_sockaddr_ex(const sockaddr *const ip_addr) {
    char data[INET6_ADDRSTRLEN] = {};

    auto family = ip_addr->sa_family;
    std::uint16_t port = 0;
    if (family == AF_INET6) {
      inet_ntop(AF_INET6, &((sockaddr_in6 *) ip_addr)->sin6_addr, data, INET6_ADDRSTRLEN);
      port = ((sockaddr_in6 *) ip_addr)->sin6_port;
    } else if (family == AF_INET) {
      inet_ntop(AF_INET, &((sockaddr_in *) ip_addr)->sin_addr, data, INET_ADDRSTRLEN);
      port = ((sockaddr_in *) ip_addr)->sin_port;
    }

    return {port, std::string {data}};
  }

  std::string get_mac_address(const std::string_view &address) {
    auto ifaddrs = get_ifaddrs();

    for (auto pos = ifaddrs.get(); pos != nullptr; pos = pos->ifa_next) {
      if (pos->ifa_addr && address == from_sockaddr(pos->ifa_addr)) {
        BOOST_LOG(verbose) << "Looking for MAC of "sv << pos->ifa_name;

        struct ifaddrs *ifap, *ifaptr;
        unsigned char *ptr;
        std::string mac_address;

        if (getifaddrs(&ifap) == 0) {
          for (ifaptr = ifap; ifaptr != nullptr; ifaptr = (ifaptr)->ifa_next) {
            if (!strcmp((ifaptr)->ifa_name, pos->ifa_name) && (((ifaptr)->ifa_addr)->sa_family == AF_LINK)) {
              ptr = (unsigned char *) LLADDR((struct sockaddr_dl *) (ifaptr)->ifa_addr);
              char buff[100];

              snprintf(buff, sizeof(buff), "%02x:%02x:%02x:%02x:%02x:%02x", *ptr, *(ptr + 1), *(ptr + 2), *(ptr + 3), *(ptr + 4), *(ptr + 5));
              mac_address = buff;
              break;
            }
          }

          freeifaddrs(ifap);

          if (ifaptr != nullptr) {
            BOOST_LOG(verbose) << "Found MAC of "sv << pos->ifa_name << ": "sv << mac_address;
            return mac_address;
          }
        }
      }
    }

    BOOST_LOG(warning) << "Unable to find MAC address for "sv << address;
    return "00:00:00:00:00:00"s;
  }

  bp::child run_command(bool elevated, bool interactive, const std::string &cmd, boost::filesystem::path &working_dir, const bp::environment &env, FILE *file, std::error_code &ec, bp::group *group) {
    // clang-format off
    if (!group) {
      if (!file) {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > bp::null, bp::std_err > bp::null, bp::limit_handles, ec);
      }
      else {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > file, bp::std_err > file, bp::limit_handles, ec);
      }
    }
    else {
      if (!file) {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > bp::null, bp::std_err > bp::null, bp::limit_handles, ec, *group);
      }
      else {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > file, bp::std_err > file, bp::limit_handles, ec, *group);
      }
    }
    // clang-format on
  }

  /**
   * @brief Open a url in the default web browser.
   * @param url The url to open.
   */
  void open_url(const std::string &url) {
    boost::filesystem::path working_dir;
    std::string cmd = R"(open ")" + url + R"(")";

    boost::process::v1::environment _env = boost::this_process::environment();
    std::error_code ec;
    auto child = run_command(false, false, cmd, working_dir, _env, nullptr, ec, nullptr);
    if (ec) {
      BOOST_LOG(warning) << "Couldn't open url ["sv << url << "]: System: "sv << ec.message();
    } else {
      BOOST_LOG(info) << "Opened url ["sv << url << "]"sv;
      child.detach();
    }
  }

  void adjust_thread_priority(thread_priority_e priority) {
    qos_class_t mac_priority;

    switch (priority) {
      case thread_priority_e::low:
        mac_priority = QOS_CLASS_UTILITY;
        break;
      case thread_priority_e::normal:
        mac_priority = QOS_CLASS_DEFAULT;
        break;
      case thread_priority_e::high:
        mac_priority = QOS_CLASS_USER_INITIATED;
        break;
      case thread_priority_e::critical:
        mac_priority = QOS_CLASS_USER_INTERACTIVE;
        break;
      default:
        BOOST_LOG(error) << "Unknown thread priority: "sv << (int) priority;
        return;
    }

    // https://github.com/apple/darwin-libpthread/blob/main/include/sys/qos.h
    pthread_set_qos_class_self_np(mac_priority, 0);

    // The capture/encode thread is latency-critical. Opt the ENTIRE process out of App Nap
    // and timer coalescing — macOS otherwise batches this background LSUIElement LaunchAgent's
    // timers to save power, which shows up as regular, periodic frame-pacing jitter that
    // ProcessType=Interactive alone doesn't fix. NSActivityLatencyCritical specifically
    // disables timer coalescing. Held for the process lifetime. This file is MRC (not ARC), so the
    // autoreleased activity token returned by beginActivityWithOptions: is explicitly retained here
    // to keep it alive for the process lifetime; without the retain it can be deallocated and App
    // Nap silently re-engages.
    if (priority == thread_priority_e::critical) {
      static id app_nap_activity = nil;
      static dispatch_once_t app_nap_once;
      dispatch_once(&app_nap_once, ^{
        app_nap_activity = [[NSProcessInfo processInfo]
          beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical | NSActivityIdleSystemSleepDisabled)
                            reason:@"Moonwalk Host low-latency video streaming"];
        [app_nap_activity retain];
      });
    }
  }

  void set_thread_name(const std::string &name) {
    pthread_setname_np(name.c_str());
  }

  void enable_mouse_keys() {
    // Unimplemented
  }

  void streaming_will_start() {
    // Nothing to do
  }

  void streaming_will_stop() {
    virtual_display_destroy();
  }

  // --- VD teardown-complete signal (design: docs/design/vd-lifecycle.md §2A, Stage 3) ------
  //
  // Cross-thread order gate closing the original ghost-minting race: the stream thread's
  // streaming_will_stop() -> virtual_display_destroy() (below) now BLOCKS until the helper's
  // "released" ACK + pid reap (S2, hard-bounded ≤~8s worst case) before it returns, and
  // returning IS "teardown complete" per the design's revised gate criterion. Raising this
  // signal right after `::virtual_display_destroy()` returns therefore asserts exactly that
  // fact for any other caller (e.g. rtsp.cpp's quit_app_on_disconnect block) that must not run
  // a display-mutating action (arrange-stop/displayplacer) while a release is still in flight.
  //
  // A plain file-scope `safe::signal_t` (== `safe::event_t<bool>`, the same primitive
  // src/stream.cpp's `controlEnd` and src/video.cpp's `reinit_event`/`join_event` use for
  // cross-thread join/shutdown signalling) is used directly here rather than routed through
  // `mail::man`'s string-keyed event bus. `mail::man`'s map holds only a WEAK reference per id
  // (src/thread_safe.h:509-521 `mail_raw_t::event<T>`) and evicts the entry the moment every
  // last shared_ptr holder of that event drops out of scope (`post_t::~post_t` -> `cleanup()`).
  // Every existing `mail::man->event<T>(...)` call site anchors its shared_ptr in a
  // long-lived session-thread scope (e.g. the capture-thread function in video.cpp holds
  // `idr_events` for its whole run). This signal has no such anchor — it's raised from a
  // one-shot ObjC++ callback in misc.mm and waited on from an unrelated one-shot call in
  // rtsp.cpp/nvhttp.cpp — so routing it through the weak-map bus risked the raise and the wait
  // never overlapping in time and the signal being silently dropped. A static local object has
  // no such lifetime hazard.
  static safe::signal_t vd_teardown_event;

  void macos::release_pending_display(uint32_t generation) {
    // Match and destroy under vd_mutex. Publish completion before a new create
    // can reset the gate, so delayed old cleanup cannot satisfy a newer wait.
    ::virtual_display_destroy_generation(generation, [] { vd_teardown_event.raise(true); });
  }

  std::uint32_t virtual_display_create(int width, int height, int fps, int desktop_scale) {
    // New session starting: clear any stale teardown-complete signal left by the PREVIOUS
    // session before this one exists, so a late/slow waiter checking on behalf of THIS session
    // can never be satisfied by session N-1's completion (design: "the signal must reset
    // appropriately for the next session"). Reset happens here, at create — not at destroy —
    // because destroy has no notion of "a new session is about to begin"; create does, and
    // create is this signal's only writer besides the destroy-side raise below.
    // Reset under the same registry lock as generation-scoped pending release.
    // A timeout finishing concurrently with this create cannot leave a stale
    // completion signal armed for the new display.
    return ::virtual_display_create(width, height, fps, desktop_scale, [] { vd_teardown_event.reset(); });
  }

  void virtual_display_destroy() {
    ::virtual_display_destroy();
    // ::virtual_display_destroy() only returns once destroy_session_locked() has completed (or
    // immediately if there was nothing LIVE to tear down) — either way, by this point there is
    // no in-flight release transaction left for a subsequent arrange-stop to corrupt. Raise
    // unconditionally; the "nothing was LIVE" case is exactly "already torn down / never was
    // live", which likewise satisfies "no release in flight" for the wait below.
    vd_teardown_event.raise(true);
  }

  bool vd_teardown_wait(std::chrono::milliseconds timeout) {
    // `view()`, not `pop()` — deliberately non-consuming. This signal can legitimately be
    // checked by more than one caller for the same completed teardown (e.g. nvhttp.cpp's
    // /cancel path terminates sessions directly, which can itself cause the rtsp thread's
    // quit_app_on_disconnect branch to also observe session_count()==0 on its next loop
    // iteration and check this same gate). `reset()` at the next virtual_display_create() is
    // what clears the signal for the next session, not consumption by a waiter — see the
    // comment on `vd_teardown_event` above.
    return vd_teardown_event.view(timeout);
  }

  bool vd_wait_active(std::uint32_t display_id, std::chrono::milliseconds timeout) {
    // Check the complete capture postcondition; a nonzero helper ID can outlive its display.
    if (display_id == 0) {
      return false;
    }

    constexpr auto poll_interval {std::chrono::milliseconds(25)};
    const auto deadline {std::chrono::steady_clock::now() + timeout};
    while (true) {
      auto bounds = CGDisplayBounds(display_id);
      if (skylight_virtual_display_ready(CGDisplayIsOnline(display_id), CGDisplayIsActive(display_id),
                                        CGDisplayIsInMirrorSet(display_id), CGDisplayMirrorsDisplay(display_id),
                                        bounds.size.width, bounds.size.height)) {
        return true;
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        return false;
      }
      std::this_thread::sleep_for(poll_interval);
    }
  }

  std::uint32_t virtual_display_get_id() {
    return ::virtual_display_get_id();
  }

  // P3 Option A headless gate (docs/design/2026-07-12-p3-asleep-external-capture.md §3.1): build
  // the descriptor list CGGetActiveDisplayList reports and hand it to the pure predicate in
  // headless_gate.h. If enumeration itself fails, fail toward today's unconditional-create
  // behavior (return false / "no active physical") rather than silently skipping VD creation on
  // an API error we can't interpret.
  bool has_active_physical_display() {
    CGDirectDisplayID active[32];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(32, active, &count) != kCGErrorSuccess) {
      return false;
    }

    std::vector<platf::macos::DisplayDescriptor> descriptors;
    descriptors.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
      platf::macos::DisplayDescriptor descriptor;
      descriptor.id = active[i];
      descriptor.vendor_number = static_cast<std::uint32_t>(CGDisplayVendorNumber(active[i]));
      descriptor.is_builtin = CGDisplayIsBuiltin(active[i]);
      descriptors.push_back(descriptor);
    }

    return platf::macos::has_active_physical_display(descriptors);
  }

  void restart_on_exit() {
    char executable[2048];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) < 0) {
      BOOST_LOG(fatal) << "NSGetExecutablePath() failed: "sv << errno;
      return;
    }

    // ASIO doesn't use O_CLOEXEC, so we have to close all fds ourselves
    int openmax = (int) sysconf(_SC_OPEN_MAX);
    for (int fd = STDERR_FILENO + 1; fd < openmax; fd++) {
      close(fd);
    }

    // Re-exec ourselves with the same arguments
    if (execv(executable, lifetime::get_argv()) < 0) {
      BOOST_LOG(fatal) << "execv() failed: "sv << errno;
      return;
    }
  }

  void restart() {
    // Gracefully clean up and restart ourselves instead of exiting
    atexit(restart_on_exit);
    lifetime::exit_sunshine(0, true);
  }

  int set_env(const std::string &name, const std::string &value) {
    return setenv(name.c_str(), value.c_str(), 1);
  }

  int unset_env(const std::string &name) {
    return unsetenv(name.c_str());
  }

  bool request_process_group_exit(std::uintptr_t native_handle) {
    if (killpg((pid_t) native_handle, SIGTERM) == 0 || errno == ESRCH) {
      BOOST_LOG(debug) << "Successfully sent SIGTERM to process group: "sv << native_handle;
      return true;
    } else {
      BOOST_LOG(warning) << "Unable to send SIGTERM to process group ["sv << native_handle << "]: "sv << errno;
      return false;
    }
  }

  bool process_group_running(std::uintptr_t native_handle) {
    return waitpid(-((pid_t) native_handle), nullptr, WNOHANG) >= 0;
  }

  struct sockaddr_in to_sockaddr(boost::asio::ip::address_v4 address, uint16_t port) {
    struct sockaddr_in saddr_v4 = {};

    saddr_v4.sin_family = AF_INET;
    saddr_v4.sin_port = htons(port);

    auto addr_bytes = address.to_bytes();
    memcpy(&saddr_v4.sin_addr, addr_bytes.data(), sizeof(saddr_v4.sin_addr));

    return saddr_v4;
  }

  struct sockaddr_in6 to_sockaddr(boost::asio::ip::address_v6 address, uint16_t port) {
    struct sockaddr_in6 saddr_v6 = {};

    saddr_v6.sin6_family = AF_INET6;
    saddr_v6.sin6_port = htons(port);
    saddr_v6.sin6_scope_id = address.scope_id();

    auto addr_bytes = address.to_bytes();
    memcpy(&saddr_v6.sin6_addr, addr_bytes.data(), sizeof(saddr_v6.sin6_addr));

    return saddr_v6;
  }

  bool send_batch(batched_send_info_t &send_info) {
    // Fall back to unbatched send calls
    return false;
  }

  bool send(send_info_t &send_info) {
    auto sockfd = (int) send_info.native_socket;
    struct msghdr msg = {};

    // Convert the target address into a sockaddr
    struct sockaddr_in taddr_v4 = {};
    struct sockaddr_in6 taddr_v6 = {};
    if (send_info.target_address.is_v6()) {
      taddr_v6 = to_sockaddr(send_info.target_address.to_v6(), send_info.target_port);

      msg.msg_name = (struct sockaddr *) &taddr_v6;
      msg.msg_namelen = sizeof(taddr_v6);
    } else {
      taddr_v4 = to_sockaddr(send_info.target_address.to_v4(), send_info.target_port);

      msg.msg_name = (struct sockaddr *) &taddr_v4;
      msg.msg_namelen = sizeof(taddr_v4);
    }

    union {
      char buf[std::max(CMSG_SPACE(sizeof(struct in_pktinfo)), CMSG_SPACE(sizeof(struct in6_pktinfo)))];
      struct cmsghdr alignment;
    } cmbuf {};

    socklen_t cmbuflen = 0;

    msg.msg_control = cmbuf.buf;
    msg.msg_controllen = sizeof(cmbuf.buf);

    auto pktinfo_cm = CMSG_FIRSTHDR(&msg);
    if (send_info.source_address.is_v6()) {
      struct in6_pktinfo pktInfo {};

      struct sockaddr_in6 saddr_v6 = to_sockaddr(send_info.source_address.to_v6(), 0);
      pktInfo.ipi6_addr = saddr_v6.sin6_addr;
      pktInfo.ipi6_ifindex = 0;

      cmbuflen += CMSG_SPACE(sizeof(pktInfo));

      pktinfo_cm->cmsg_level = IPPROTO_IPV6;
      pktinfo_cm->cmsg_type = IPV6_PKTINFO;
      pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
      memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
    } else {
      struct in_pktinfo pktInfo {};

      struct sockaddr_in saddr_v4 = to_sockaddr(send_info.source_address.to_v4(), 0);
      pktInfo.ipi_spec_dst = saddr_v4.sin_addr;
      pktInfo.ipi_ifindex = 0;

      cmbuflen += CMSG_SPACE(sizeof(pktInfo));

      pktinfo_cm->cmsg_level = IPPROTO_IP;
      pktinfo_cm->cmsg_type = IP_PKTINFO;
      pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
      memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
    }

    struct iovec iovs[2] = {};
    int iovlen = 0;
    if (send_info.header) {
      iovs[iovlen].iov_base = (void *) send_info.header;
      iovs[iovlen].iov_len = send_info.header_size;
      iovlen++;
    }
    iovs[iovlen].iov_base = (void *) send_info.payload;
    iovs[iovlen].iov_len = send_info.payload_size;
    iovlen++;

    msg.msg_iov = iovs;
    msg.msg_iovlen = iovlen;

    msg.msg_controllen = cmbuflen;

    auto bytes_sent = sendmsg(sockfd, &msg, 0);

    // If there's no send buffer space, wait for some to be available
    while (bytes_sent < 0 && errno == EAGAIN) {
      struct pollfd pfd;

      pfd.fd = sockfd;
      pfd.events = POLLOUT;

      if (poll(&pfd, 1, -1) != 1) {
        BOOST_LOG(warning) << "poll() failed: "sv << errno;
        break;
      }

      // Try to send again
      bytes_sent = sendmsg(sockfd, &msg, 0);
    }

    if (bytes_sent < 0) {
      BOOST_LOG(warning) << "sendmsg() failed: "sv << errno;
      return false;
    }

    return true;
  }

  // We can't track QoS state separately for each destination on this OS,
  // so we keep a ref count to only disable QoS options when all clients
  // are disconnected.
  static std::atomic<int> qos_ref_count = 0;

  class qos_t: public deinit_t {
  public:
    qos_t(int sockfd, std::vector<std::tuple<int, int, int>> options):
        sockfd(sockfd),
        options(options) {
      qos_ref_count++;
    }

    virtual ~qos_t() {
      if (--qos_ref_count == 0) {
        for (const auto &tuple : options) {
          auto reset_val = std::get<2>(tuple);
          if (setsockopt(sockfd, std::get<0>(tuple), std::get<1>(tuple), &reset_val, sizeof(reset_val)) < 0) {
            BOOST_LOG(warning) << "Failed to reset option: "sv << errno;
          }
        }
      }
    }

  private:
    int sockfd;
    std::vector<std::tuple<int, int, int>> options;
  };

  /**
   * @brief Enables QoS on the given socket for traffic to the specified destination.
   * @param native_socket The native socket handle.
   * @param address The destination address for traffic sent on this socket.
   * @param port The destination port for traffic sent on this socket.
   * @param data_type The type of traffic sent on this socket.
   * @param dscp_tagging Specifies whether to enable DSCP tagging on outgoing traffic.
   */
  std::unique_ptr<deinit_t> enable_socket_qos(uintptr_t native_socket, boost::asio::ip::address &address, uint16_t port, qos_data_type_e data_type, bool dscp_tagging) {
    int sockfd = (int) native_socket;
    std::vector<std::tuple<int, int, int>> reset_options;

    // We can use SO_NET_SERVICE_TYPE to set link-layer prioritization without DSCP tagging
    int service_type = 0;
    switch (data_type) {
      case qos_data_type_e::video:
        service_type = NET_SERVICE_TYPE_VI;
        break;
      case qos_data_type_e::audio:
        service_type = NET_SERVICE_TYPE_VO;
        break;
      default:
        BOOST_LOG(error) << "Unknown traffic type: "sv << (int) data_type;
        break;
    }

    if (service_type) {
      if (setsockopt(sockfd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service_type, sizeof(service_type)) == 0) {
        // Reset SO_NET_SERVICE_TYPE to best-effort when QoS is disabled
        reset_options.emplace_back(std::make_tuple(SOL_SOCKET, SO_NET_SERVICE_TYPE, NET_SERVICE_TYPE_BE));
      } else {
        BOOST_LOG(error) << "Failed to set SO_NET_SERVICE_TYPE: "sv << errno;
      }
    }

    // Raw DSCP tagging (IP_TOS) is deliberately NOT applied here, even when the client
    // negotiates it (dscp_tagging). Consumer Wi-Fi gear maps DSCP CS5/AF41 to the WMM
    // AC_VI (video) queue and some APs silently black-hole that queue downstream: live
    // testing on 2026-07-20 showed CS5-marked UDP of ANY size dropped host->client
    // (while CS6/EF/unmarked passed), which presented as "client connects, audio works,
    // no video ever arrives". SO_NET_SERVICE_TYPE above is Apple's sanctioned QoS
    // mechanism, provides the link-layer prioritization we want on the host side, and
    // does not stamp DSCP on the wire — verified delivered on the same path that
    // dropped DSCP-tagged packets.
    (void) dscp_tagging;
    (void) address;

    return std::make_unique<qos_t>(sockfd, reset_options);
  }

  std::string get_host_name() {
    try {
      std::string name = boost::asio::ip::host_name();

      // On macOS, gethostname() (what boost::asio::ip::host_name() wraps) returns the mDNS/
      // Bonjour local hostname -- literally "studio-mac.local", trailing ".local" and all. This
      // value becomes <hostname> in /serverinfo (see nvhttp.cpp's use of config::nvhttp.
      // sunshine_name) and is shown verbatim by every client (SkylightMenu's pairing list,
      // Starlight's host list, stock Moonlight) -- none of them strip it, because none of them
      // can tell "this name genuinely ends in .local" apart from "this is the mDNS suffix
      // macOS always appends". Stripping it once here, at the source, fixes it everywhere.
      constexpr std::string_view suffix = ".local";
      if (name.size() > suffix.size() &&
          std::equal(suffix.rbegin(), suffix.rend(), name.rbegin(),
                      [](char a, char b) {
                        return std::tolower(static_cast<unsigned char>(a)) == std::tolower(static_cast<unsigned char>(b));
                      })) {
        name.erase(name.size() - suffix.size());
      }

      return name;
    } catch (boost::system::system_error &err) {
      BOOST_LOG(error) << "Failed to get hostname: "sv << err.what();
      return "Moonwalk Host"s;
    }
  }

  class macos_high_precision_timer: public high_precision_timer {
  public:
    void sleep_for(const std::chrono::nanoseconds &duration) override {
      std::this_thread::sleep_for(duration);
    }

    operator bool() override {
      return true;
    }
  };

  std::unique_ptr<high_precision_timer> create_high_precision_timer() {
    return std::make_unique<macos_high_precision_timer>();
  }
}  // namespace platf

namespace dyn {
  void *handle(const std::vector<const char *> &libs) {
    void *handle;

    for (auto lib : libs) {
      handle = dlopen(lib, RTLD_LAZY | RTLD_LOCAL);
      if (handle) {
        return handle;
      }
    }

    std::stringstream ss;
    ss << "Couldn't find any of the following libraries: ["sv << libs.front();
    std::for_each(std::begin(libs) + 1, std::end(libs), [&](auto lib) {
      ss << ", "sv << lib;
    });

    ss << ']';

    BOOST_LOG(error) << ss.str();

    return nullptr;
  }

  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict) {
    int err = 0;
    for (auto &func : funcs) {
      TUPLE_2D_REF(fn, name, func);

      *fn = (void (*)()) dlsym(handle, name);

      if (!*fn && strict) {
        BOOST_LOG(error) << "Couldn't find function: "sv << name;

        err = -1;
      }
    }

    return err;
  }
}  // namespace dyn
