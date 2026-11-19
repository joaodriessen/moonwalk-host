/**
 * @file src/main.cpp
 * @brief Definitions for the main entry point for Sunshine.
 */
// standard includes
#include <chrono>
#include <codecvt>
#include <csignal>
#include <cstdlib>
#include <fstream>
#include <iostream>

// local includes
#include "confighttp.h"
#include "display_device.h"
#include "entry_handler.h"
#include "globals.h"
#include "httpcommon.h"
#include "logging.h"
#include "main.h"
#include "nvhttp.h"
#include "process.h"
#include "system_tray.h"
#include "upnp.h"
#include "video.h"

extern "C" {
#include "rswrapper.h"
}

#if defined(__APPLE__) || defined(__MACH__)
  #include "platform/macos/xpc_control.h"
#endif

using namespace std::literals;

#if defined(__APPLE__) || defined(__MACH__)
  // Allow the menu app time to complete the signed XPC handshake on a cold launch.
  constexpr std::chrono::seconds kCaptureGateGrace {10};
#endif

std::map<int, std::function<void()>> signal_handlers;

void on_signal_forwarder(int sig) {
  signal_handlers.at(sig)();
}

template<class FN>
void on_signal(int sig, FN &&fn) {
  signal_handlers.emplace(sig, std::forward<FN>(fn));

  std::signal(sig, on_signal_forwarder);
}

std::map<std::string_view, std::function<int(const char *name, int argc, char **argv)>> cmd_to_func {
  {"creds"sv, [](const char *name, int argc, char **argv) {
     return args::creds(name, argc, argv);
   }},
  {"help"sv, [](const char *name, int argc, char **argv) {
     return args::help(name);
   }},
#ifdef _WIN32
  {"restore-nvprefs-undo"sv, [](const char *name, int argc, char **argv) {
     return args::restore_nvprefs_undo();
   }},
#endif
};

#ifdef _WIN32
LRESULT CALLBACK SessionMonitorWindowProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
  switch (uMsg) {
    case WM_CLOSE:
      DestroyWindow(hwnd);
      return 0;
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
    case WM_ENDSESSION:
      {
        // Terminate ourselves with a blocking exit call
        std::cout << "Received WM_ENDSESSION"sv << std::endl;
        lifetime::exit_sunshine(0, false);
        return 0;
      }
    default:
      return DefWindowProc(hwnd, uMsg, wParam, lParam);
  }
}

WINAPI BOOL ConsoleCtrlHandler(DWORD type) {
  if (type == CTRL_CLOSE_EVENT) {
    BOOST_LOG(info) << "Console closed handler called";
    lifetime::exit_sunshine(0, false);
  }
  return FALSE;
}
#endif

#if defined SUNSHINE_TRAY && SUNSHINE_TRAY >= 1
constexpr bool tray_is_enabled = true;
#else
constexpr bool tray_is_enabled = false;
#endif

void mainThreadLoop(const std::shared_ptr<safe::event_t<bool>> &shutdown_event) {
  bool run_loop = false;

  // Conditions that would require the main thread event loop
#ifndef _WIN32
  #if defined(__APPLE__) || defined(__MACH__)
  // On macOS the daemon's own tray always runs headless (system_tray::set_headless(), called
  // below before init_tray()) -- SkylightMenu is the one visible menu-bar icon. The NSApp pump
  // this loop drives is what keeps ScreenCaptureKit/virtual-display capture alive (memory
  // f006d058), so it must run unconditionally rather than being gated on
  // config::sunshine.system_tray, which becomes an inert legacy key on this platform (see
  // settings-ux.md).
  run_loop = tray_is_enabled;
  #else
  run_loop = tray_is_enabled && config::sunshine.system_tray;  // On Windows, tray runs in separate thread, so no main loop needed for tray
  #endif
#endif

  if (!run_loop) {
    BOOST_LOG(info) << "No main thread features enabled, skipping event loop"sv;
    // Wait for shutdown
    shutdown_event->view();
    return;
  }

  // Main thread event loop
  BOOST_LOG(info) << "Starting main loop"sv;

  // system_tray::process_tray_events() blocks on the native tray/UI event loop and only
  // returns when a tray event fires or system_tray::end_tray() is called -- the SIGINT/
  // SIGTERM handlers in main() already call end_tray() for user-initiated shutdown. But
  // shutdown_event can also be raised by a startup thread outside that path (e.g.
  // rtsp_stream::start() failing to bind its port), and nothing would otherwise wake the
  // blocked tray loop, leaving a zombie process with a dead RTSP listener. Watch for that
  // case here and nudge the tray loop so the shutdown is actually observed, without
  // turning this into a busy-spin poll: the watcher blocks on the same shutdown_event via
  // view() (no spinning) and only acts once, mirroring what the signal handlers already do.
  std::thread shutdown_tray_nudge([shutdown_event]() {
    shutdown_event->view();
    system_tray::end_tray();
  });

  while (system_tray::process_tray_events() == 0 && !shutdown_event->peek());
  BOOST_LOG(info) << "Main loop has exited"sv;

  shutdown_tray_nudge.join();
}

int main(int argc, char *argv[]) {
  lifetime::argv = argv;

  task_pool_util::TaskPool::task_id_t force_shutdown = nullptr;

#ifdef _WIN32
  // Avoid searching the PATH in case a user has configured their system insecurely
  // by placing a user-writable directory in the system-wide PATH variable.
  SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);

  setlocale(LC_ALL, "C");
#endif

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
  // Use UTF-8 conversion for the default C++ locale (used by boost::log)
  std::locale::global(std::locale(std::locale(), new std::codecvt_utf8<wchar_t>));
#pragma GCC diagnostic pop

  mail::man = std::make_shared<safe::mail_raw_t>();

  // parse config file
  const int config_result = config::parse(argc, argv);
  if (config_result != 0) {
    return config_result > 0 ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  auto log_deinit_guard = logging::init(config::sunshine.min_log_level, config::sunshine.log_file);
  if (!log_deinit_guard) {
    BOOST_LOG(error) << "Logging failed to initialize"sv;
  }

  // logging can begin at this point
  // if anything is logged prior to this point, it will appear in stdout, but not in the log viewer in the UI
  // the version should be printed to the log before anything else
  BOOST_LOG(info) << "Moonwalk Host " << SKYLIGHT_VERSION << " source " << PROJECT_VERSION_COMMIT << " (Sunshine engine " << PROJECT_VERSION << ")";

  // Log publisher metadata
  log_publisher_data();

  // Seed the live `display_cursor` global (src/globals.h) from the configured initial value.
  // This only sets the STARTING state -- the SkylightMenu XPC hide-cursor toggle
  // (src/platform/macos/xpc_control.mm setHideCursor:) still flips the same global at runtime
  // exactly as before, live, no restart needed.
  display_cursor = config::video.capture_cursor;
  BOOST_LOG(info) << "config: initial display_cursor = "sv << (display_cursor ? "shown"sv : "hidden"sv) << " (capture_cursor="sv << (config::video.capture_cursor ? "true"sv : "false"sv) << ")"sv;

  if (!config::sunshine.cmd.name.empty()) {
    auto fn = cmd_to_func.find(config::sunshine.cmd.name);
    if (fn == std::end(cmd_to_func)) {
      BOOST_LOG(fatal) << "Unknown command: "sv << config::sunshine.cmd.name;

      BOOST_LOG(info) << "Possible commands:"sv;
      for (auto &[key, _] : cmd_to_func) {
        BOOST_LOG(info) << '\t' << key;
      }

      return 7;
    }

    return fn->second(argv[0], config::sunshine.cmd.argc, config::sunshine.cmd.argv);
  }

  // Adding guard here first as it also performs recovery after crash,
  // otherwise people could theoretically end up without display output.
  // It also should be destroyed before forced shutdown to expedite the cleanup.
  auto display_device_deinit_guard = display_device::init(platf::appdata() / "display_device.state", config::video);
  if (!display_device_deinit_guard) {
    BOOST_LOG(error) << "Display device session failed to initialize"sv;
  }

#ifdef _WIN32
  // Modify relevant NVIDIA control panel settings if the system has corresponding gpu
  if (nvprefs_instance.load()) {
    // Restore global settings to the undo file left by improper termination of sunshine.exe
    nvprefs_instance.restore_from_and_delete_undo_file_if_exists();
    // Modify application settings for sunshine.exe
    nvprefs_instance.modify_application_profile();
    // Modify global settings, undo file is produced in the process to restore after improper termination
    nvprefs_instance.modify_global_profile();
    // Unload dynamic library to survive driver re-installation
    nvprefs_instance.unload();
  }

  // Wait as long as possible to terminate Sunshine.exe during logoff/shutdown
  SetProcessShutdownParameters(0x100, SHUTDOWN_NORETRY);

  // We must create a hidden window to receive shutdown notifications since we load gdi32.dll
  std::promise<HWND> session_monitor_hwnd_promise;
  auto session_monitor_hwnd_future = session_monitor_hwnd_promise.get_future();
  std::promise<void> session_monitor_join_thread_promise;
  auto session_monitor_join_thread_future = session_monitor_join_thread_promise.get_future();

  std::thread session_monitor_thread([&]() {
    platf::set_thread_name("session_monitor");
    session_monitor_join_thread_promise.set_value_at_thread_exit();

    WNDCLASSA wnd_class {};
    wnd_class.lpszClassName = "SunshineSessionMonitorClass";
    wnd_class.lpfnWndProc = SessionMonitorWindowProc;
    if (!RegisterClassA(&wnd_class)) {
      session_monitor_hwnd_promise.set_value(nullptr);
      BOOST_LOG(error) << "Failed to register session monitor window class"sv << std::endl;
      return;
    }

    auto wnd = CreateWindowExA(
      0,
      wnd_class.lpszClassName,
      "Sunshine Session Monitor Window",
      0,
      CW_USEDEFAULT,
      CW_USEDEFAULT,
      CW_USEDEFAULT,
      CW_USEDEFAULT,
      nullptr,
      nullptr,
      nullptr,
      nullptr
    );

    session_monitor_hwnd_promise.set_value(wnd);

    if (!wnd) {
      BOOST_LOG(error) << "Failed to create session monitor window"sv << std::endl;
      return;
    }

    ShowWindow(wnd, SW_HIDE);

    // Run the message loop for our window
    MSG msg {};
    while (GetMessage(&msg, nullptr, 0, 0) > 0) {
      TranslateMessage(&msg);
      DispatchMessage(&msg);
    }
  });

  auto session_monitor_join_thread_guard = util::fail_guard([&]() {
    if (session_monitor_hwnd_future.wait_for(1s) == std::future_status::ready) {
      if (HWND session_monitor_hwnd = session_monitor_hwnd_future.get()) {
        PostMessage(session_monitor_hwnd, WM_CLOSE, 0, 0);
      }

      if (session_monitor_join_thread_future.wait_for(1s) == std::future_status::ready) {
        session_monitor_thread.join();
        return;
      } else {
        BOOST_LOG(warning) << "session_monitor_join_thread_future reached timeout";
      }
    } else {
      BOOST_LOG(warning) << "session_monitor_hwnd_future reached timeout";
    }

    session_monitor_thread.detach();
  });

#endif

  task_pool.start(1);

  // Create signal handler after logging has been initialized
  auto shutdown_event = mail::man->event<bool>(mail::shutdown);
  on_signal(SIGINT, [&force_shutdown, &display_device_deinit_guard, shutdown_event]() {
    BOOST_LOG(info) << "Interrupt handler called"sv;

    auto task = []() {
      BOOST_LOG(fatal) << "10 seconds passed, yet Sunshine's still running: Forcing shutdown"sv;
      logging::log_flush();
      lifetime::debug_trap();
    };
    force_shutdown = task_pool.pushDelayed(task, 10s).task_id;

    // Break out of the main loop
    shutdown_event->raise(true);
    system_tray::end_tray();

    display_device_deinit_guard = nullptr;
  });

  on_signal(SIGTERM, [&force_shutdown, &display_device_deinit_guard, shutdown_event]() {
    BOOST_LOG(info) << "Terminate handler called"sv;

    auto task = []() {
      BOOST_LOG(fatal) << "10 seconds passed, yet Sunshine's still running: Forcing shutdown"sv;
      logging::log_flush();
      lifetime::debug_trap();
    };
    force_shutdown = task_pool.pushDelayed(task, 10s).task_id;

    // Break out of the main loop
    shutdown_event->raise(true);
    system_tray::end_tray();

    display_device_deinit_guard = nullptr;
  });

#ifdef _WIN32
  // Terminate gracefully on Windows when console window is closed
  SetConsoleCtrlHandler(ConsoleCtrlHandler, TRUE);
#endif

  proc::refresh(config::stream.file_apps);

  // If any of the following fail, we log an error and continue event though sunshine will not function correctly.
  // This allows access to the UI to fix configuration problems or view the logs.

  auto platf_deinit_guard = platf::init();
  if (!platf_deinit_guard) {
    BOOST_LOG(error) << "Platform failed to initialize"sv;
  }

  auto proc_deinit_guard = proc::init();
  if (!proc_deinit_guard) {
    BOOST_LOG(error) << "Proc failed to initialize"sv;
  }

  reed_solomon_init();
  auto input_deinit_guard = input::init();

  if (input::probe_gamepads()) {
    BOOST_LOG(warning) << "No gamepad input is available"sv;
  }

  if (video::probe_encoders()) {
    BOOST_LOG(error) << "Video failed to find working encoder"sv;
  }

  if (http::init()) {
    BOOST_LOG(fatal) << "HTTP interface failed to initialize"sv;

#ifdef _WIN32
    BOOST_LOG(fatal) << "To relaunch Sunshine successfully, use the shortcut in the Start Menu. Do not run Sunshine.exe manually."sv;
    std::this_thread::sleep_for(10s);
#endif

    return -1;
  }

#if defined(__APPLE__) || defined(__MACH__)
  // At this point only the local XPC control service is available. Keep the
  // early return before mDNS and network listeners so a failed menu handshake
  // never exposes discovery, pairing, or streaming.
  if (!platf::macos::wait_for_validated_menu(kCaptureGateGrace)) {
    BOOST_LOG(warning) << "No validated SkylightMenu peer attached within "sv
                        << std::chrono::duration_cast<std::chrono::seconds>(kCaptureGateGrace).count()
                        << "s of startup -- shutting down without starting mDNS/pairing/streaming"sv;
    shutdown_event->raise(true);
    return lifetime::desired_exit_code;
  }
#endif

  std::unique_ptr<platf::deinit_t> mDNS;
  auto sync_mDNS = std::async(std::launch::async, [&mDNS]() {
    mDNS = platf::publish::start();
  });

  std::unique_ptr<platf::deinit_t> upnp_unmap;
  auto sync_upnp = std::async(std::launch::async, [&upnp_unmap]() {
    upnp_unmap = upnp::start();
  });

  // FIXME: Temporary workaround: Simple-Web_server needs to be updated or replaced
  if (shutdown_event->peek()) {
    return lifetime::desired_exit_code;
  }

  std::thread httpThread {nvhttp::start};
  std::thread configThread;
  if (config::nvhttp.web_ui_enabled) {
    configThread = std::thread {confighttp::start};
  } else {
    BOOST_LOG(info) << "Web UI disabled by configuration (web_ui_enabled=false); native SkylightMenu remains fully functional."sv;
  }
  std::thread rtspThread {rtsp_stream::start};

#ifdef _WIN32
  // If we're using the default port and GameStream is enabled, warn the user
  if (config::sunshine.port == 47989 && is_gamestream_enabled()) {
    BOOST_LOG(fatal) << "GameStream is still enabled in GeForce Experience! This *will* cause streaming problems with Sunshine!"sv;
    BOOST_LOG(fatal) << "Disable GameStream on the SHIELD tab in GeForce Experience or change the Port setting on the Advanced tab in the Sunshine Web UI."sv;
  }
#endif

#if defined(__APPLE__) || defined(__MACH__)
  // Capture depends on the AppKit event pump initialized by the tray library.
  // Start it headless regardless of the legacy system_tray setting so only
  // the menu app presents an icon.
  if (tray_is_enabled) {
    BOOST_LOG(info) << "Starting system tray (headless; SkylightMenu owns the visible menu-bar icon)"sv;
    system_tray::set_headless(true);
    system_tray::init_tray();
  }
#else
  if (tray_is_enabled && config::sunshine.system_tray) {
    BOOST_LOG(info) << "Starting system tray"sv;
#ifdef _WIN32
    // TODO: Windows has a weird bug where when running as a service and on the first Windows boot,
    // the tray icon would not appear even though Sunshine is running correctly otherwise.
    // Restarting the service would allow the icon to appear normally.
    // For now we will keep the Windows tray icon on a separate thread.
    // Ideally, we would run the system tray on the main thread for all platforms.
    system_tray::init_tray_threaded();
#else
    system_tray::init_tray();
#endif
  }
#endif

  mainThreadLoop(shutdown_event);

  httpThread.join();
  if (configThread.joinable()) {
    configThread.join();
  }
  rtspThread.join();

  task_pool.stop();
  task_pool.join();

#ifdef _WIN32
  // Restore global NVIDIA control panel settings
  if (nvprefs_instance.owning_undo_file() && nvprefs_instance.load()) {
    nvprefs_instance.restore_global_profile();
    nvprefs_instance.unload();
  }
#endif

  return lifetime::desired_exit_code;
}
