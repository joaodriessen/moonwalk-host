#include <future>
#include <gtest/gtest.h>
#include <src/audio.h>
#include <src/globals.h>

namespace {
  class recovery_mic: public platf::mic_t {
  public:
    recovery_mic(platf::capture_e status, int &destroyed):
        status(status),
        destroyed(destroyed) {}

    ~recovery_mic() override {
      ++destroyed;
    }

    platf::capture_e sample(std::vector<float> &out) override {
      std::fill(out.begin(), out.end(), 0.25f);
      return status;
    }

    platf::capture_e status;
    int &destroyed;
  };
}  // namespace

TEST(AudioRecovery, RetriesInitialFailureAndDeliversReplacementSamples) {
  using namespace std::chrono_literals;
  auto context = std::make_shared<safe::mail_raw_t>();
  auto shutdown = context->event<bool>(mail::shutdown);
  int attempts = 0, destroyed = 0, delivered = 0;
  audio::capture_samples(nullptr, [&]() -> std::unique_ptr<platf::mic_t> {
    if (++attempts == 1) {
      return nullptr;
    }
    return std::make_unique<recovery_mic>(platf::capture_e::ok, destroyed);
  },
                         [&](std::vector<float> samples) {
                           EXPECT_EQ(samples.size(), 960u);
                           EXPECT_EQ(samples.front(), 0.25f);
                           ++delivered;
                           shutdown->raise(true);
                         },
                         shutdown,
                         960,
                         1ms);
  EXPECT_EQ(attempts, 2);
  EXPECT_EQ(delivered, 1);
  EXPECT_EQ(destroyed, 1);
}

TEST(AudioRecovery, ReleasesStoppedSourceBeforeReopeningAndRetriesFailedReopen) {
  using namespace std::chrono_literals;
  auto context = std::make_shared<safe::mail_raw_t>();
  auto shutdown = context->event<bool>(mail::shutdown);
  int destroyed = 0, attempts = 0, delivered = 0;
  audio::capture_samples(std::make_unique<recovery_mic>(platf::capture_e::reinit, destroyed), [&]() -> std::unique_ptr<platf::mic_t> {
    EXPECT_EQ(destroyed, 1);
    if (++attempts == 1) {
      return nullptr;
    }
    return std::make_unique<recovery_mic>(platf::capture_e::ok, destroyed);
  },
                         [&](std::vector<float>) {
                           ++delivered;
                           shutdown->raise(true);
                         },
                         shutdown,
                         960,
                         1ms);
  EXPECT_EQ(attempts, 2);
  EXPECT_EQ(delivered, 1);
  EXPECT_EQ(destroyed, 2);
}

TEST(AudioRecovery, ShutdownInterruptsLongRetryBackoffWithoutOpeningDevice) {
  using namespace std::chrono_literals;
  auto context = std::make_shared<safe::mail_raw_t>();
  auto shutdown = context->event<bool>(mail::shutdown);
  int opens = 0;
  auto work = std::async(std::launch::async, [&] {
    audio::capture_samples(nullptr, [&]() -> std::unique_ptr<platf::mic_t> {
      ++opens;
      return nullptr;
    },
                           [](std::vector<float>) {
                           },
                           shutdown,
                           960,
                           5s);
  });
  shutdown->raise(true);
  EXPECT_EQ(work.wait_for(200ms), std::future_status::ready);
  work.get();
  EXPECT_EQ(opens, 0);
}
