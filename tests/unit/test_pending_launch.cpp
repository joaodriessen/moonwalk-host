#include <boost/asio/io_context.hpp>
#include <future>
#include <gtest/gtest.h>
#include <src/pending_launch.h>
#include <src/pending_launch_queue.h>

namespace {
  struct queued_launch {
    uint32_t id {};
    rtsp_stream::pending_launch_t pending;
  };
}  // namespace

TEST(PendingLaunchQueue, ActualTimerReleasesDisplayEvenWithRetainedSocketReference) {
  using namespace std::chrono_literals;
  boost::asio::io_context io;
  rtsp_stream::pending_launch_queue_t<queued_launch> queue(io);
  auto held_socket = std::make_shared<queued_launch>();
  held_socket->id = 1;
  int released = 0;
  held_socket->pending.arm([&] {
    ++released;
  });
  ASSERT_TRUE(queue.raise(held_socket, 1ms));
  io.run_for(100ms);
  EXPECT_EQ(released, 1);
  EXPECT_FALSE(queue.current());
  EXPECT_FALSE(held_socket->pending.accept([] {
    return true;
  }));
}

TEST(PendingLaunchQueue, StaleExpiryAndClearCannotRetireNewLaunch) {
  using namespace std::chrono_literals;
  boost::asio::io_context io;
  rtsp_stream::pending_launch_queue_t<queued_launch> queue(io);
  auto old_launch = std::make_shared<queued_launch>();
  auto new_launch = std::make_shared<queued_launch>();
  old_launch->id = 1;
  new_launch->id = 2;
  int old_released = 0, new_released = 0;
  old_launch->pending.arm([&] {
    ++old_released;
  });
  new_launch->pending.arm([&] {
    ++new_released;
  });
  ASSERT_TRUE(queue.raise(old_launch, 0ms));
  queue.clear(1);
  ASSERT_TRUE(queue.raise(new_launch, 1h));
  queue.clear(1);
  io.run_for(5ms);
  EXPECT_EQ(queue.current(), new_launch);
  EXPECT_EQ(old_released, 1);
  EXPECT_EQ(new_released, 0);
  queue.discard();
  EXPECT_EQ(new_released, 1);
}

TEST(PendingLaunch, ExpirationReleasesResourcesWhileSocketStillRetainsLaunch) {
  auto socket_reference = std::make_shared<rtsp_stream::pending_launch_t>();
  int released = 0, started = 0;
  socket_reference->arm([&] {
    ++released;
  });
  socket_reference->expire();
  EXPECT_EQ(released, 1);
  EXPECT_FALSE(socket_reference->accept([&] {
    ++started;
    return true;
  }));
  socket_reference->expire();
  socket_reference.reset();
  EXPECT_EQ(released, 1);
  EXPECT_EQ(started, 0);
}

TEST(PendingLaunch, FailedStartRetainsCleanupAndSuccessfulStartTransfersIt) {
  int released = 0;
  {
    rtsp_stream::pending_launch_t failed;
    failed.arm([&] {
      ++released;
    });
    EXPECT_FALSE(failed.accept([] {
      return false;
    }));
    failed.expire();
    EXPECT_EQ(released, 1);
  }
  {
    rtsp_stream::pending_launch_t accepted;
    accepted.arm([&] {
      ++released;
    });
    EXPECT_TRUE(accepted.accept([] {
      return true;
    }));
    accepted.expire();
  }
  EXPECT_EQ(released, 1);
}

TEST(PendingLaunch, ExpirationCannotInterruptAcceptanceOrReleaseAcceptedDisplay) {
  using namespace std::chrono_literals;
  rtsp_stream::pending_launch_t pending;
  int released = 0;
  pending.arm([&] {
    ++released;
  });
  std::promise<void> starting, finish;
  auto finish_future = finish.get_future();
  auto accepted = std::async(std::launch::async, [&] {
    return pending.accept([&] {
      starting.set_value();
      finish_future.wait();
      return true;
    });
  });
  starting.get_future().wait();
  auto expiry = std::async(std::launch::async, [&] {
    pending.expire();
  });
  EXPECT_EQ(expiry.wait_for(10ms), std::future_status::timeout);
  finish.set_value();
  EXPECT_TRUE(accepted.get());
  expiry.get();
  EXPECT_EQ(released, 0);
}
