#pragma once

#include <algorithm>
#include <chrono>
#include "thread_safe.h"

namespace stream::detail {
  // Initial A/V pings have their own queue. Session shutdown must also interrupt
  // that wait: RTSP joins these workers while holding its session-slot lock.
  // A real queued ping still wakes pop() immediately; idle cancellation is bounded.
  template<class Message, class Cancelled, class Accept>
  int wait_initial_ping(safe::queue_t<Message> &messages, std::chrono::milliseconds timeout,
                       Cancelled cancelled, Accept accept) {
    using clock = std::chrono::steady_clock;
    const auto deadline = clock::now() + timeout;
    const auto slice = std::chrono::duration_cast<clock::duration>(std::chrono::milliseconds(25));
    while (messages.running() && !cancelled()) {
      const auto now = clock::now();
      if (now >= deadline) break;
      auto message = messages.pop(std::min(deadline - now, slice));
      if (message && !cancelled() && accept(*message)) return 0;
    }
    return -1;
  }
} // namespace stream::detail
