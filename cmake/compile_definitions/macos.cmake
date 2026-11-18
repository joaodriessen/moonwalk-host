# macos specific compile definitions

add_compile_definitions(SUNSHINE_PLATFORM="macos")

if(NOT BOOST_USE_STATIC AND NOT FETCH_CONTENT_BOOST_USED)
    ADD_DEFINITIONS(-DBOOST_LOG_DYN_LINK)
endif()

# ScreenCaptureKit for system audio capture (macOS 12.3+)
FIND_LIBRARY(SCREEN_CAPTURE_KIT_LIBRARY ScreenCaptureKit)

# IOKit for virtual HID gamepad (IOHIDUserDevice)
FIND_LIBRARY(IOKIT_LIBRARY IOKit)
FIND_LIBRARY(IMAGE_IO_LIBRARY ImageIO)

list(APPEND SUNSHINE_EXTERNAL_LIBRARIES
        ${APP_KIT_LIBRARY}
        ${APP_SERVICES_LIBRARY}
        ${AV_FOUNDATION_LIBRARY}
        ${CORE_MEDIA_LIBRARY}
        ${CORE_VIDEO_LIBRARY}
        ${FOUNDATION_LIBRARY}
        ${SECURITY_FRAMEWORK}
        ${VIDEO_TOOLBOX_LIBRARY}
        ${SCREEN_CAPTURE_KIT_LIBRARY}
        ${IOKIT_LIBRARY}
        ${IMAGE_IO_LIBRARY})

set(APPLE_PLIST_FILE "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/assets/Info.plist")

set(PLATFORM_TARGET_FILES
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_audio.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_audio.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_img_t.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_video.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_video.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/black_frame_detector.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_capture.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_capture.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_capture_retry.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/perf_trace.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/perf_trace.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_audio.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_audio.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/gamepad.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/gamepad.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/hid_gamepad.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/hid_gamepad.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/virtual_display.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/virtual_display.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/display.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/input.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/microphone.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/misc.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/misc.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/nv12_zero_device.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/nv12_zero_device.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/pasteboard.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/publish.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/xpc_control.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/xpc_control.mm"
        "${CMAKE_SOURCE_DIR}/third-party/TPCircularBuffer/TPCircularBuffer.c"
        "${CMAKE_SOURCE_DIR}/third-party/TPCircularBuffer/TPCircularBuffer.h"
        ${APPLE_PLIST_FILE})

# ARC source list — the ONE list of files compiled with -fobjc-arc.
# set_source_files_properties is directory-scoped, so tests/CMakeLists.txt (which
# recompiles the platform sources into test_sunshine) applies this same list again;
# otherwise the test binary silently builds these files as MRC with different memory
# semantics than production. Add new ARC files HERE only.
# - virtual_display.m: required for CGVirtualDisplay private API lifecycle management
# - hid_gamepad.m/gamepad.m (tier 1) + microphone.mm/display.mm (tier 2) +
#   av_audio.m/av_video.m (tier 3) + sc_capture.m/sc_audio.m/input.mm (tier 4,
#   migration complete): ARC migration per
#   docs/overhaul-dossiers/dossier-macos-platform.md
# - xpc_control.mm: new file (S0 walking skeleton, docs/design/menubar-app.md), ARC by
#   default preference for new ObjC++ sources -- no MRC legacy to match.
# - pasteboard.mm: new file (native in-stream clipboard host backend), same
#   ARC-by-default preference -- no MRC legacy to match.
set(SUNSHINE_ARC_SOURCES
        "${CMAKE_SOURCE_DIR}/src/platform/macos/virtual_display.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/hid_gamepad.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/gamepad.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/microphone.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/display.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_audio.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_video.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/xpc_control.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_capture.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_audio.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/input.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/pasteboard.mm")
set_source_files_properties(${SUNSHINE_ARC_SOURCES}
        PROPERTIES COMPILE_FLAGS "-fobjc-arc")

# sc_capture.m is compiled as Objective-C++ (filename kept as .m) so its P2 crash-proofing boundary
# catch (docs/design/2026-07-12-black-screen-permanent-fix.md §3 Mode 2) can use the unified
# ObjC++ exception model: @try/@catch there catches both NSExceptions AND escaping C++ exceptions
# (e.g. std::bad_function_call) at the ScreenCaptureKit callback boundary. Plain Objective-C (the
# default clang treats a bare .m file as, regardless of driver) only has -fobjc-exceptions, which
# does not catch a C++ exception. This project never formally enables CMake's cross-platform OBJC/
# OBJCXX languages (no enable_language/project(LANGUAGES...) call exists) -- .mm files here already
# work by compiling through the CXX language, with clang's own extension sniffing giving them
# Objective-C++ parsing; -x objective-c++ replicates that same trick for this .m file: LANGUAGE CXX
# routes it through the CXX compiler/flags, and -x overrides clang's normal "a .m file means plain
# Objective-C" extension-based default. Directory-scoped like the ARC flags above -- re-applied for
# the test binary in tests/CMakeLists.txt.
set_source_files_properties("${CMAKE_SOURCE_DIR}/src/platform/macos/sc_capture.m"
        PROPERTIES LANGUAGE CXX
        COMPILE_FLAGS "-x objective-c++ -fobjc-arc")

if(SUNSHINE_ENABLE_TRAY)
    list(APPEND SUNSHINE_EXTERNAL_LIBRARIES
            ${COCOA})
    list(APPEND PLATFORM_TARGET_FILES
            "${CMAKE_SOURCE_DIR}/third-party/tray/src/tray_darwin.m")
endif()

# Build vd_helper: standalone subprocess for creating CGVirtualDisplay
add_executable(vd_helper "${CMAKE_SOURCE_DIR}/src/platform/macos/vd_helper.m")
set_source_files_properties(
        "${CMAKE_SOURCE_DIR}/src/platform/macos/vd_helper.m"
        PROPERTIES COMPILE_FLAGS "-fobjc-arc")
target_link_libraries(vd_helper PRIVATE
        "-framework Foundation"
        "-framework AppKit"
        "-framework CoreGraphics"
        "-framework IOKit"
        "-F/System/Library/PrivateFrameworks"
        "-framework SkyLight")
# Place vd_helper next to the sunshine binary
set_target_properties(vd_helper PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
