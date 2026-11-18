/**
 * @file src/platform/macos/perf_trace.h
 * @brief Phase-0 instrumentation counters (docs/design/pipeline-overhaul.md §2), shared between
 *        the ScreenCaptureKit delivery callback (sc_capture.m, plain Objective-C) and the
 *        cross-platform encode loop (video.cpp) which owns the rolling [perf] summary log line.
 * @details C linkage so sc_capture.m -- a plain .m file, not Objective-C++ -- can call in without
 *          becoming a C++ translation unit. Definitions live in perf_trace.cpp. The `note_*`
 *          functions internally no-op unless config::video.perf_trace is enabled, so callers
 *          never need to check the flag themselves; the on-path cost when disabled is one bool
 *          load, i.e. no behavior change to the capture callback when perf_trace is off.
 */
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Called from the SCK delivery callback (sc_capture.m didOutputSampleBuffer:ofType:) for every
// SCStreamOutputTypeScreen sample: sck_real only for a valid complete source
// frame, sck_idle only for SCFrameStatusIdle. No-op unless config::video.perf_trace is true.
void perf_trace_note_sck_real(void);
void perf_trace_note_sck_idle(void);

// Read-and-reset the rolling counters above. Called once per second from the encode loop
// (video.cpp) when assembling the [perf] summary line.
uint64_t perf_trace_exchange_sck_real(void);
uint64_t perf_trace_exchange_sck_idle(void);

#ifdef __cplusplus
}
#endif
