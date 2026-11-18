#include <gtest/gtest.h>
#include <src/thread_safe.h>
#include <chrono>
#include <future>
#include <memory>
#include <thread>

using namespace std::chrono_literals;
namespace {
struct frame { int number; bool idr; };
// Keep the regression executable against the former nonblocking publication.
template<class Q, class Cancel, class Item>
auto publish(Q &queue, Cancel cancel, Item &&item, int) -> decltype(queue.raise_wait(1, cancel, std::forward<Item>(item))) {
  return queue.raise_wait(1, cancel, std::forward<Item>(item));
}
template<class Q, class Cancel, class Item>
bool publish(Q &queue, Cancel, Item &&item, long) {
  queue.raise(std::forward<Item>(item));return true;
}
}

TEST(EncodedVideoBackpressure, SlowSenderRetainsCompleteIdrAndEveryDependentFrameInOrder) {
  safe::queue_t<frame> queue;
  std::promise<void> started;
  std::thread producer([&] {
    started.set_value();
    for (int n = 0; n < 80; ++n)
      if (!publish(queue, [] { return false; }, frame {n, n == 0}, 0)) return;
    publish(queue, [] { return false; }, frame {-1, false}, 0);
  });
  started.get_future().wait();std::this_thread::sleep_for(25ms);
  std::vector<int> received;int idrs = 0;
  while (auto packet = queue.pop(2s)) {
    if (packet->number == -1) break;
    received.push_back(packet->number);idrs += packet->idr;
    std::this_thread::sleep_for(1ms);
  }
  queue.stop();producer.join();
  std::vector<int> expected;for (int n = 0; n < 80; ++n) expected.push_back(n);
  EXPECT_EQ(received, expected);EXPECT_EQ(idrs, 1);
}

TEST(EncodedVideoBackpressure, OnePendingPacketBlocksUntilEitherPopOverloadMakesSpace) {
  for (bool timed : {false, true}) {
    safe::queue_t<frame> queue;queue.raise(frame {0, true});
    std::promise<bool> completed;auto done = completed.get_future();
    std::thread producer([&] { completed.set_value(publish(queue, [] { return false; }, frame {1, false}, 0)); });
    EXPECT_EQ(done.wait_for(25ms), std::future_status::timeout);
    auto first = timed ? queue.pop(1s) : queue.pop();
    EXPECT_TRUE(bool(first));
    if (done.wait_for(2s) != std::future_status::ready) queue.stop();
    EXPECT_TRUE(done.get());producer.join();
    auto second = queue.pop(1s);EXPECT_TRUE(bool(second));
    if (second) EXPECT_EQ(second->number, 1);
    queue.stop();
  }
}

TEST(EncodedVideoBackpressure, QueueStopWakesBlockedProducerWithoutAcceptingItsPacket) {
  safe::queue_t<frame> queue;queue.raise(frame {0, true});
  std::promise<bool> completed;auto done = completed.get_future();
  std::thread producer([&] { completed.set_value(publish(queue, [] { return false; }, frame {1, false}, 0)); });
  EXPECT_EQ(done.wait_for(25ms), std::future_status::timeout);queue.stop();
  EXPECT_EQ(done.wait_for(2s), std::future_status::ready);
  EXPECT_FALSE(done.get());producer.join();
}

TEST(EncodedVideoBackpressure, SessionShutdownCancelsWhileSharedQueueRemainsRunning) {
  safe::queue_t<frame> queue;queue.raise(frame {0, true});safe::event_t<bool> shutdown;
  std::promise<bool> completed;auto done = completed.get_future();
  std::thread producer([&] { completed.set_value(publish(queue, [&] { return bool(shutdown.view(0ms)); }, frame {1, false}, 0)); });
  EXPECT_EQ(done.wait_for(25ms), std::future_status::timeout);shutdown.raise(true);
  if (done.wait_for(2s) != std::future_status::ready) queue.stop();
  EXPECT_FALSE(done.get());producer.join();EXPECT_TRUE(queue.running());
  auto first = queue.pop(1s);EXPECT_TRUE(bool(first));if (first) EXPECT_EQ(first->number, 0);
  queue.stop();
}

TEST(EncodedVideoBackpressure, CancelledPacketIsNotMovedIntoTheQueue) {
  safe::queue_t<std::unique_ptr<int>> queue;auto packet = std::make_unique<int>(42);
  EXPECT_FALSE(publish(queue, [] { return true; }, std::move(packet), 0));
  EXPECT_NE(packet, nullptr);EXPECT_FALSE(queue.pop(1ms));queue.stop();
}

TEST(EncodedVideoBackpressure, ManualPublicationKeepsItsExistingThirtyTwoPacketOverflowPolicy) {
  safe::queue_t<frame> queue;
  for (int n = 0; n < 33; ++n) queue.raise(frame {n, n == 0});
  auto retained = queue.pop(1s);ASSERT_TRUE(bool(retained));EXPECT_EQ(retained->number, 32);
  EXPECT_FALSE(queue.pop(1ms));queue.stop();
}
