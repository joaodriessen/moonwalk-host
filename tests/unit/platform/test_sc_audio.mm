#import "src/platform/macos/sc_audio.h"

#include <gtest/gtest.h>
#include <src/platform/common.h>
#include <src/platform/macos/audio_capture_bridge.h>
#include <src/platform/macos/audio_source_probe.h>

// Inert framework boundary: never calls SCShareableContent enumeration, opens a
// real SCStream, or posts input. The production SCAudioCapture lifecycle runs.
@interface InertAudioContent: NSObject
@property (nonatomic, readonly) NSArray *displays;
@end
@implementation InertAudioContent

- (NSArray *)displays {
  return @[[[NSObject alloc] init]];
}

@end

@interface InertAudioStream: NSObject
@property (nonatomic) BOOL failsStart;
@property (nonatomic) int stopCount;
- (BOOL)addStreamOutput:(id)output type:(SCStreamOutputType)type sampleHandlerQueue:(dispatch_queue_t)queue error:(NSError **)error;
- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))completion;
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completion;
@end
@implementation InertAudioStream

- (BOOL)addStreamOutput:(id)output type:(SCStreamOutputType)type sampleHandlerQueue:(dispatch_queue_t)queue error:(NSError **)error {
  return YES;
}

- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))completion {
  completion(self.failsStart ? [NSError errorWithDomain:@"InertAudioStream" code:1 userInfo:nil] : nil);
}

- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completion {
  ++_stopCount;
  completion(nil);
}

@end

@interface InertAudioCapture: SCAudioCapture
@property (nonatomic) BOOL failsStart;
@property (nonatomic) NSInteger configuredChannels;
@property (nonatomic, strong) InertAudioStream *lastStream;
@end
@implementation InertAudioCapture

- (void)loadShareableContent:(void (^)(SCShareableContent *, NSError *))completion {
  completion((SCShareableContent *) [[InertAudioContent alloc] init], nil);
}

- (SCStream *)createStreamForDisplay:(SCDisplay *)display configuration:(SCStreamConfiguration *)configuration {
  self.configuredChannels = configuration.channelCount;
  self.lastStream = [[InertAudioStream alloc] init];
  self.lastStream.failsStart = self.failsStart;
  return (SCStream *) self.lastStream;
}

@end

TEST(NativeMacAudioLifecycle, FailedStartCleansPartialStreamAndRing) {
  @autoreleasepool {
    InertAudioCapture *capture = [[InertAudioCapture alloc] init];
    capture.failsStart = YES;
    EXPECT_EQ([capture startCaptureWithSampleRate:48000 channels:2], -1);
    EXPECT_FALSE(capture.isCapturing);
    EXPECT_EQ(capture.lastStream.stopCount, 1);
    EXPECT_EQ([capture getAudioBuffer]->buffer, nullptr);
    EXPECT_EQ(capture.stream, nil);
    [capture stopCapture];
    EXPECT_EQ(capture.lastStream.stopCount, 1);
  }
}

TEST(NativeMacAudioLifecycle, ErrorStopStillCleansAndOldErrorCannotStopReplacement) {
  @autoreleasepool {
    InertAudioCapture *capture = [[InertAudioCapture alloc] init];
    ASSERT_EQ([capture startCaptureWithSampleRate:48000 channels:2], 0);
    InertAudioStream *oldStream = capture.lastStream;
    [capture stream:(SCStream *) oldStream didStopWithError:[NSError errorWithDomain:@"test" code:1 userInfo:nil]];
    EXPECT_FALSE(capture.isCapturing);
    [capture stopCapture];
    EXPECT_EQ(oldStream.stopCount, 1);
    EXPECT_EQ([capture getAudioBuffer]->buffer, nullptr);
    ASSERT_EQ([capture startCaptureWithSampleRate:48000 channels:2], 0);
    [capture stream:(SCStream *) oldStream didStopWithError:[NSError errorWithDomain:@"test" code:2 userInfo:nil]];
    EXPECT_TRUE(capture.isCapturing);
    EXPECT_EQ(capture.configuredChannels, 2);
    [capture stopCapture];
    EXPECT_EQ(capture.lastStream.stopCount, 1);
  }
}

TEST(NativeMacAudioLifecycle, RefusesUnsupportedNegotiationBeforeCreatingStream) {
  @autoreleasepool {
    InertAudioCapture *capture = [[InertAudioCapture alloc] init];
    EXPECT_EQ([capture startCaptureWithSampleRate:48000 channels:6], -1);
    EXPECT_EQ([capture startCaptureWithSampleRate:48000 channels:8], -1);
    EXPECT_EQ(capture.lastStream, nil);
    EXPECT_EQ([capture getAudioBuffer]->buffer, nullptr);
  }
}

TEST(NativeMacAudioLifecycle, OwnerReturnsReinitAfterStopAndReleasesResources) {
  @autoreleasepool {
    InertAudioCapture *capture = [[InertAudioCapture alloc] init];
    ASSERT_EQ([capture startCaptureWithSampleRate:48000 channels:2], 0);
    auto owner = platf::macos::make_system_audio_microphone((__bridge void *) capture);
    const std::vector<float> original {0.1f, 0.2f, 0.3f, 0.4f};
    ASSERT_TRUE(TPCircularBufferProduceBytes([capture getAudioBuffer], original.data(), original.size() * sizeof(float)));
    std::vector<float> samples(original.size());
    EXPECT_EQ(owner->sample(samples), platf::capture_e::ok);
    EXPECT_EQ(samples, original);
    [capture stream:capture.stream didStopWithError:[NSError errorWithDomain:@"test" code:3 userInfo:nil]];
    EXPECT_EQ(owner->sample(samples), platf::capture_e::reinit);
    owner.reset();
    EXPECT_EQ(capture.stream, nil);
    EXPECT_EQ([capture getAudioBuffer]->buffer, nullptr);
    EXPECT_EQ(capture.lastStream.stopCount, 1);
  }
}

TEST(NativeMacAudioLifecycle, ActualFormatMismatchIsRejectedBeforeBuffering) {
  @autoreleasepool {
    InertAudioCapture *capture = [[InertAudioCapture alloc] init];
    ASSERT_EQ([capture startCaptureWithSampleRate:48000 channels:2], 0);
    AudioStreamBasicDescription asbd = {48000, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 24, 1, 24, 6, 32, 0};
    CMAudioFormatDescriptionRef format = nullptr;
    ASSERT_EQ(CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nullptr, 0, nullptr, nullptr, &format), noErr);
    CMSampleBufferRef sample = nullptr;
    const auto created = CMSampleBufferCreate(kCFAllocatorDefault, nullptr, NO, nullptr, nullptr, format, 1, 0, nullptr, 0, nullptr, &sample);
    CFRelease(format);
    ASSERT_EQ(created, noErr);
    [capture stream:capture.stream didOutputSampleBuffer:sample ofType:SCStreamOutputTypeAudio];
    CFRelease(sample);
    EXPECT_FALSE(capture.isCapturing);
    uint32_t bytes = 123;
    TPCircularBufferTail([capture getAudioBuffer], &bytes);
    EXPECT_EQ(bytes, 0u);
    [capture stopCapture];
    EXPECT_EQ([capture getAudioBuffer]->buffer, nullptr);
  }
}

TEST(NativeMacAudioLifecycle, SoundTestReadsProductionCaptureOwnerAndReleasesInertStream) {
  @autoreleasepool {
    InertAudioCapture *capture = [[InertAudioCapture alloc] init];
    ASSERT_EQ([capture startCaptureWithSampleRate:48000 channels:2], 0);
    std::vector<float> delivered(960, 0.25f);
    ASSERT_TRUE(TPCircularBufferProduceBytes([capture getAudioBuffer], delivered.data(), delivered.size() * sizeof(float)));
    std::atomic_bool cancelled {false};
    struct ReadOnce: platf::mic_t {
      std::unique_ptr<platf::mic_t> source;
      std::atomic_bool &cancel;
      ReadOnce(std::unique_ptr<platf::mic_t> source, std::atomic_bool &cancel): source(std::move(source)), cancel(cancel) {}
      platf::capture_e sample(std::vector<float> &samples) override {
        auto state = source->sample(samples); cancel = true; return state;
      }
    };
    auto owner = std::make_unique<ReadOnce>(platf::macos::make_system_audio_microphone((__bridge void *)capture), cancelled);
    const auto result = platf::macos::probe_audio_source(*owner, cancelled);
    EXPECT_EQ(result.samples, delivered.size());
    EXPECT_FLOAT_EQ(result.peak, 0.25f);
    owner.reset();
    EXPECT_EQ(capture.lastStream.stopCount, 1);
    EXPECT_EQ(capture.stream, nil);
    EXPECT_EQ([capture getAudioBuffer]->buffer, nullptr);
  }
}

// AVFoundation input recovery uses real AVAudio storage and the production
// microphone owner. These boundaries never enumerate devices or start capture.
#import "src/platform/macos/av_audio.h"
#include <src/audio.h>
#include <src/globals.h>

@interface InertInputSession: NSObject
@property (nonatomic) BOOL running;
@property (nonatomic) int stopCount;
- (BOOL)isRunning;
- (void)stopRunning;
@end
@implementation InertInputSession
- (BOOL)isRunning { return self.running; }
- (void)stopRunning { ++_stopCount; self.running = NO; }
@end

@interface InertInputWait: NSCondition
@property (nonatomic) int waits;
@property (nonatomic, strong) InertInputSession *stopOnWait;
@end
@implementation InertInputWait
- (BOOL)waitUntilDate:(NSDate *)limit {
  ++_waits;
  self.stopOnWait.running = NO;
  return NO;
}
@end

namespace {
  AVAudio *inert_input(InertInputSession *session, InertInputWait *wait) {
    AVAudio *capture = [[AVAudio alloc] init];
    capture.audioCaptureSession = (AVCaptureSession *)session;
    capture.samplesArrivedSignal = wait;
    EXPECT_TRUE(TPCircularBufferInit(&capture->audioSampleBuffer, 4096));
    return capture;
  }
}

TEST(NativeMacInputAudioLifecycle, StoppedInputRejectsBufferedSamplesForReopen) {
  @autoreleasepool {
    InertInputSession *session = [[InertInputSession alloc] init];
    AVAudio *capture = inert_input(session, [[InertInputWait alloc] init]);
    const std::vector<float> oldSamples(8, 0.25f);
    ASSERT_TRUE(TPCircularBufferProduceBytes(&capture->audioSampleBuffer, oldSamples.data(), oldSamples.size() * sizeof(float)));
    auto owner = platf::macos::make_input_audio_microphone((__bridge void *)capture);
    std::vector<float> samples(oldSamples.size(), -1.0f);
    EXPECT_EQ(owner->sample(samples), platf::capture_e::reinit);
    EXPECT_EQ(samples, std::vector<float>(oldSamples.size(), -1.0f));
  }
}

TEST(NativeMacInputAudioLifecycle, RunningInputWithoutSamplesKeepsNormalTimeout) {
  @autoreleasepool {
    InertInputSession *session = [[InertInputSession alloc] init];
    session.running = YES;
    InertInputWait *wait = [[InertInputWait alloc] init];
    AVAudio *capture = inert_input(session, wait);
    auto owner = platf::macos::make_input_audio_microphone((__bridge void *)capture);
    std::vector<float> samples(8);
    EXPECT_EQ(owner->sample(samples), platf::capture_e::timeout);
    EXPECT_EQ(wait.waits, 6);
    EXPECT_TRUE(session.running);
    EXPECT_EQ(session.stopCount, 0);
  }
}

TEST(NativeMacInputAudioLifecycle, RunningInputDeliversSilenceWithoutReopen) {
  @autoreleasepool {
    InertInputSession *session = [[InertInputSession alloc] init];
    session.running = YES;
    InertInputWait *wait = [[InertInputWait alloc] init];
    AVAudio *capture = inert_input(session, wait);
    const std::vector<float> silence(8, 0.0f);
    ASSERT_TRUE(TPCircularBufferProduceBytes(&capture->audioSampleBuffer, silence.data(), silence.size() * sizeof(float)));
    auto owner = platf::macos::make_input_audio_microphone((__bridge void *)capture);
    std::vector<float> samples(silence.size(), -1.0f);
    EXPECT_EQ(owner->sample(samples), platf::capture_e::ok);
    EXPECT_EQ(samples, silence);
    EXPECT_EQ(wait.waits, 0);
  }
}

TEST(NativeMacInputAudioLifecycle, InputStoppedDuringWaitEntersReopenPath) {
  @autoreleasepool {
    InertInputSession *session = [[InertInputSession alloc] init];
    session.running = YES;
    InertInputWait *wait = [[InertInputWait alloc] init];
    wait.stopOnWait = session;
    AVAudio *capture = inert_input(session, wait);
    auto owner = platf::macos::make_input_audio_microphone((__bridge void *)capture);
    std::vector<float> samples(8);
    EXPECT_EQ(owner->sample(samples), platf::capture_e::reinit);
    EXPECT_EQ(wait.waits, 1);
  }
}

TEST(NativeMacInputAudioLifecycle, CaptureLoopReleasesStoppedInputAndDeliversReplacement) {
  using namespace std::chrono_literals;
  @autoreleasepool {
    auto context = std::make_shared<safe::mail_raw_t>();
    auto shutdown = context->event<bool>(mail::shutdown);
    InertInputSession *stopped = [[InertInputSession alloc] init];
    AVAudio *capture = inert_input(stopped, [[InertInputWait alloc] init]);
    __weak AVAudio *oldCapture = capture;
    // Bound the pre-fix timeout loop without touching the production dispatcher.
    struct BoundedInput: platf::mic_t {
      std::unique_ptr<platf::mic_t> source;
      safe::mail_raw_t::event_t<bool> shutdown;
      int reads = 0;
      BoundedInput(std::unique_ptr<platf::mic_t> source, safe::mail_raw_t::event_t<bool> shutdown):
          source(std::move(source)), shutdown(shutdown) {}
      platf::capture_e sample(std::vector<float> &samples) override {
        auto result = source->sample(samples);
        if (++reads == 2) { shutdown->raise(true); }
        return result;
      }
    };
    auto owner = std::make_unique<BoundedInput>(platf::macos::make_input_audio_microphone((__bridge void *)capture), shutdown);
    capture = nil;
    int opens = 0, deliveries = 0;
    const std::vector<float> replacementSamples(8, 0.5f);
    audio::capture_samples(std::move(owner), [&]() -> std::unique_ptr<platf::mic_t> {
      ++opens;
      EXPECT_EQ(oldCapture, nil);
      EXPECT_EQ(stopped.stopCount, 1);
      InertInputSession *session = [[InertInputSession alloc] init];
      session.running = YES;
      AVAudio *replacement = inert_input(session, [[InertInputWait alloc] init]);
      EXPECT_TRUE(TPCircularBufferProduceBytes(&replacement->audioSampleBuffer, replacementSamples.data(), replacementSamples.size() * sizeof(float)));
      return platf::macos::make_input_audio_microphone((__bridge void *)replacement);
    }, [&](std::vector<float> samples) {
      ++deliveries;
      EXPECT_EQ(samples, replacementSamples);
      shutdown->raise(true);
    }, shutdown, replacementSamples.size(), 1ms);
    EXPECT_EQ(opens, 1);
    EXPECT_EQ(deliveries, 1);
  }
}
