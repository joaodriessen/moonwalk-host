#include <gtest/gtest.h>
#include <future>
#include <src/stream_initial_ping.h>

using namespace std::chrono_literals;

TEST(InitialPing, ShutdownInterruptsOtherwiseIdlePingQueue) {
  safe::queue_t<int> queue;
  safe::event_t<bool> shutdown;
  std::promise<void> started;
  bool accepted = false;
  auto work = std::async(std::launch::async, [&] {
    started.set_value();
    return stream::detail::wait_initial_ping(queue, 5s, [&] { return shutdown.peek(); }, [&](int) { accepted = true; return true; });
  });
  started.get_future().wait();
  shutdown.raise(true);
  const auto status = work.wait_for(200ms);
  EXPECT_EQ(status, std::future_status::ready);
  queue.stop(); // keep even a regressed wait from stranding this fixture
  EXPECT_EQ(work.get(), -1);
  EXPECT_FALSE(accepted);
}

TEST(InitialPing, RealQueueSkipsUnrelatedMessageThenAcceptsPingImmediately) {
  safe::queue_t<int> queue;
  queue.raise(1); queue.raise(7);
  int accepted = 0;
  EXPECT_EQ(stream::detail::wait_initial_ping(queue, 5s, [] { return false; }, [&](int value) { accepted = value; return value == 7; }), 0);
  EXPECT_EQ(accepted, 7);
}

TEST(InitialPing, AlreadyCancelledDoesNotAcceptQueuedPing) {
  safe::queue_t<int> queue;
  queue.raise(7);
  bool accepted = false;
  EXPECT_EQ(stream::detail::wait_initial_ping(queue, 5s, [] { return true; }, [&](int) { accepted = true; return true; }), -1);
  EXPECT_FALSE(accepted);
}

TEST(InitialPing, StopsForClosedQueueAndForNormalTimeout) {
  safe::queue_t<int> closed;
  closed.stop();
  EXPECT_EQ(stream::detail::wait_initial_ping(closed, 5s, [] { return false; }, [](int) { return true; }), -1);
  safe::queue_t<int> idle;
  const auto before = std::chrono::steady_clock::now();
  EXPECT_EQ(stream::detail::wait_initial_ping(idle, 40ms, [] { return false; }, [](int) { return true; }), -1);
  const auto elapsed = std::chrono::steady_clock::now() - before;
  EXPECT_GE(elapsed, 30ms);
  EXPECT_LT(elapsed, 250ms);
}
