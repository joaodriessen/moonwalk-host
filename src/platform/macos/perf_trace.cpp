/**
 * @file src/platform/macos/perf_trace.cpp
 * @brief Definitions for the Phase-0 sck_real/sck_idle counters declared in perf_trace.h.
 */
#include "perf_trace.h"

// standard includes
#include <atomic>

// local includes
#include "src/config.h"

namespace {
  std::atomic<uint64_t> g_sck_real {0};
  std::atomic<uint64_t> g_sck_idle {0};
}  // namespace

extern "C" void perf_trace_note_sck_real() {
  if (!config::video.perf_trace) {
    return;
  }
  g_sck_real.fetch_add(1, std::memory_order_relaxed);
}

extern "C" void perf_trace_note_sck_idle() {
  if (!config::video.perf_trace) {
    return;
  }
  g_sck_idle.fetch_add(1, std::memory_order_relaxed);
}

extern "C" uint64_t perf_trace_exchange_sck_real() {
  return g_sck_real.exchange(0, std::memory_order_relaxed);
}

extern "C" uint64_t perf_trace_exchange_sck_idle() {
  return g_sck_idle.exchange(0, std::memory_order_relaxed);
}
