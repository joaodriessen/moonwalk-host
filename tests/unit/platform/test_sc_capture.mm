#import "src/platform/macos/sc_capture.h"
#include <gtest/gtest.h>
#include <src/platform/macos/capture_health.h>
#include <mach/mach_time.h>

// Real production delegate/outcome code, inert framework boundary; no content
// enumeration, SCStream construction, display state or capture permission calls.
@interface InertVideoStream: NSObject
@property(nonatomic) NSInteger stopCount;
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completion;
@end
@implementation InertVideoStream
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completion { ++_stopCount; completion(nil); }
@end

static SCCapture *inertCapture() {
  SCCapture *capture=[[SCCapture alloc] init];
  capture.stream=(SCStream*)[[InertVideoStream alloc] init];
  capture.captureSignal=dispatch_semaphore_create(0);
  capture.captureOutcome=SCCaptureOutcomeRunning;
  capture.healthGeneration=platf::macos::screen_capture_health().begin();
  capture.videoCallback=^bool(CMSampleBufferRef sample, BOOL cached) { return true; };
  return capture;
}
TEST(NativeMacVideoRecovery, RuntimeInterruptionHasTypedReinitOutcome) {
  @autoreleasepool {
    SCCapture *capture=inertCapture();
    [capture stream:capture.stream didStopWithError:[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorInternalError userInfo:nil]];
    EXPECT_EQ([capture captureResult],SCCaptureOutcomeRecoverable);
    EXPECT_EQ(dispatch_semaphore_wait(capture.captureSignal,DISPATCH_TIME_NOW),0);
    [capture stopCapture];
    EXPECT_EQ([capture captureResult],SCCaptureOutcomeRecoverable);
  }
}
TEST(NativeMacVideoRecovery, PermanentPermissionOrUserStopDoesNotRetry) {
  @autoreleasepool {
    for (NSInteger code : {SCStreamErrorUserDeclined,SCStreamErrorMissingEntitlements,SCStreamErrorInvalidParameter,SCStreamErrorUserStopped}) {
      SCCapture *capture=inertCapture();
      [capture stream:capture.stream didStopWithError:[NSError errorWithDomain:SCStreamErrorDomain code:code userInfo:nil]];
      EXPECT_EQ([capture captureResult],SCCaptureOutcomeFatal);
      [capture stopCapture];
    }
  }
}
TEST(NativeMacVideoRecovery, SupersededStreamCannotFinishReplacement) {
  @autoreleasepool {
    SCCapture *capture=inertCapture();
    SCStream *old=capture.stream;
    capture.stream=(SCStream*)[[InertVideoStream alloc] init];
    [capture stream:old didStopWithError:[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorInternalError userInfo:nil]];
    EXPECT_EQ([capture captureResult],SCCaptureOutcomeRunning);
    EXPECT_NE(dispatch_semaphore_wait(capture.captureSignal,DISPATCH_TIME_NOW),0);
    [capture stopCapture];
    EXPECT_EQ([capture captureResult],SCCaptureOutcomeStopped);
  }
}

#include <src/platform/common.h>
#include <future>
namespace platf {
  capture_e test_capture_video_bridge(SCCapture*,int*);
  void test_capture_video_geometry(SCCapture*,uint32_t,uint32_t,int,int);
}

TEST(NativeMacVideoGeometry, VirtualBackingIsSeededBeforeConfigurationAndLateEncoderCallback) {
  @autoreleasepool {
    SCCapture *capture = [[SCCapture alloc] init];
    capture.frameRate = 60;
    [capture setFrameWidth:1440 frameHeight:900]; // A missing CGDisplayMode can report points.
    platf::test_capture_video_geometry(capture, 999, 999, 2880, 1800);
    // Capture may start before the parallel encoder calls setResolution.
    SCStreamConfiguration *initial = [capture newStreamConfiguration];
    EXPECT_EQ(initial.width, 2880u);
    EXPECT_EQ(initial.height, 1800u);
    [capture setFrameWidth:2880 frameHeight:1800]; // The later encoder callback is idempotent.
    EXPECT_EQ(initial.width, 2880u);
    EXPECT_EQ(initial.height, 1800u);
    SCStreamConfiguration *later = [capture newStreamConfiguration];
    EXPECT_EQ(later.width, initial.width);
    EXPECT_EQ(later.height, initial.height);
  }
}

TEST(NativeMacVideoGeometry, PhysicalCaptureKeepsNativeGeometry) {
  @autoreleasepool {
    SCCapture *capture = [[SCCapture alloc] init];
    capture.frameRate = 60;
    [capture setFrameWidth:1920 frameHeight:1080];
    platf::test_capture_video_geometry(capture, 3, 999, 2880, 1800);
    SCStreamConfiguration *config = [capture newStreamConfiguration];
    EXPECT_EQ(config.width, 1920u);
    EXPECT_EQ(config.height, 1080u);
    platf::test_capture_video_geometry(capture, 3, 0, 2880, 1800);
    EXPECT_EQ(capture.frameWidth, 1920);
    EXPECT_EQ(capture.frameHeight, 1080);
  }
}

@interface InertLifecycleVideoCapture: SCCapture
@property(nonatomic,strong) dispatch_semaphore_t started;
- (SCDisplay*)findDisplayWithIDRetrying:(CGDirectDisplayID)displayID;
- (BOOL)startCaptureStreamForDisplay:(SCDisplay*)display;
@end
@implementation InertLifecycleVideoCapture
- (SCDisplay*)findDisplayWithIDRetrying:(CGDirectDisplayID)displayID { return (SCDisplay*)[[NSObject alloc] init]; }
- (BOOL)startCaptureStreamForDisplay:(SCDisplay*)display {
  self.stream=(SCStream*)[[InertVideoStream alloc] init]; return YES;
}
- (dispatch_semaphore_t)captureVideo:(VideoFrameCallbackBlock)video audioCallback:(AudioSampleCallbackBlock)audio {
  dispatch_semaphore_t result=[super captureVideo:video audioCallback:audio];
  dispatch_semaphore_signal(self.started); return result;
}
@end

@interface SCCapture (NativeRetryTesting)
- (void)retryStartAfterTransientRaceForDisplay:(CGDirectDisplayID)displayID;
@end

@interface InertRetryVideoCapture: InertLifecycleVideoCapture
@property(nonatomic,strong) dispatch_semaphore_t replaced;
- (void)retryStartAfterTransientRaceForDisplay:(CGDirectDisplayID)displayID;
@end
@implementation InertRetryVideoCapture
- (void)retryStartAfterTransientRaceForDisplay:(CGDirectDisplayID)displayID {
  [super retryStartAfterTransientRaceForDisplay:displayID];
  dispatch_semaphore_signal(self.replaced);
}
@end

static void emitSyntheticVideoFrame(SCCapture *capture, NSInteger status=SCFrameStatusComplete,
                                    SCStream *source=nil, bool invalidate=false) {
  CVPixelBufferRef pixels=nullptr;
  ASSERT_EQ(CVPixelBufferCreate(kCFAllocatorDefault,320,180,kCVPixelFormatType_32BGRA,nullptr,&pixels),kCVReturnSuccess);
  CVPixelBufferLockBaseAddress(pixels,0);
  memset(CVPixelBufferGetBaseAddress(pixels),0,CVPixelBufferGetBytesPerRow(pixels)*180);
  CVPixelBufferUnlockBaseAddress(pixels,0);
  CMVideoFormatDescriptionRef format=nullptr;
  ASSERT_EQ(CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,pixels,&format),noErr);
  CMSampleTimingInfo timing={kCMTimeInvalid,kCMTimeInvalid,kCMTimeInvalid};
  CMSampleBufferRef sample=nullptr;
  ASSERT_EQ(CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,pixels,YES,nullptr,nullptr,format,&timing,&sample),noErr);
  CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample, true);
  NSMutableDictionary *info=(__bridge NSMutableDictionary *)CFArrayGetValueAtIndex(attachments, 0);
  if (status >= 0) info[SCStreamFrameInfoStatus]=@(status);
  if (invalidate) CMSampleBufferInvalidate(sample);
  [capture stream:source ?: capture.stream didOutputSampleBuffer:sample ofType:SCStreamOutputTypeScreen];
  CFRelease(sample); CFRelease(format); CFRelease(pixels);
}

TEST(NativeMacCaptureHealth, TransientStreamReplacementNeedsItsOwnCompleteFrame) {
  @autoreleasepool {
    InertRetryVideoCapture *capture=[[InertRetryVideoCapture alloc] init];
    capture.started=dispatch_semaphore_create(0);
    capture.replaced=dispatch_semaphore_create(0);
    __block int real=0, cached=0;
    VideoFrameCallbackBlock callback=^bool(CMSampleBufferRef sample, BOOL wasCached) {
      if (wasCached) ++cached; else ++real;
      return true;
    };
    ASSERT_NE([capture captureVideo:callback audioCallback:nil],nil);
    emitSyntheticVideoFrame(capture);
    const auto first=platf::macos::screen_capture_health().snapshot();
    ASSERT_TRUE(first.ready());
    SCStream *old=capture.stream;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double now=(double)mach_absolute_time()*timebase.numer/timebase.denom/1e9;
    [capture setValue:@(now) forKey:@"captureStartHostTime"];
    [capture stream:old didStopWithError:[NSError errorWithDomain:SCStreamErrorDomain
        code:SCStreamErrorInternalError userInfo:@{NSLocalizedDescriptionKey:@"Failed to find any displays or windows to capture"}]];
    ASSERT_EQ(dispatch_semaphore_wait(capture.replaced,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)),0);
    ASSERT_NE(capture.stream,old);
    EXPECT_NE(capture.healthGeneration,first.generation);
    EXPECT_EQ(capture.lastValidSampleBuffer,nullptr);
    emitSyntheticVideoFrame(capture,SCFrameStatusIdle);
    const auto idle=platf::macos::screen_capture_health().snapshot();
    EXPECT_EQ(idle.frames,0u);
    EXPECT_EQ(idle.cached_frames,0u);
    EXPECT_FALSE(idle.ready());
    EXPECT_EQ(real,1);
    EXPECT_EQ(cached,0);
    // A late complete callback from the replaced SCStream cannot certify it.
    emitSyntheticVideoFrame(capture,SCFrameStatusComplete,old);
    EXPECT_FALSE(platf::macos::screen_capture_health().snapshot().ready());
    emitSyntheticVideoFrame(capture);
    EXPECT_TRUE(platf::macos::screen_capture_health().snapshot().ready());
    EXPECT_EQ(platf::macos::screen_capture_health().snapshot().frames,1u);
    EXPECT_EQ(real,2);
    [capture stopCapture];
  }
}

TEST(NativeMacCaptureHealth, SupersededCallbackCannotStopReplacementAfterReturningFalse) {
  @autoreleasepool {
    SCCapture *capture=inertCapture();
    SCStream *replacement=(SCStream*)[[InertVideoStream alloc] init];
    __block int replacementFrames=0;
    __weak SCCapture *weakCapture=capture;
    capture.videoCallback=^bool(CMSampleBufferRef sample, BOOL cached) {
      SCCapture *owner=weakCapture;
      owner.stream=replacement;
      owner.videoCallback=^bool(CMSampleBufferRef next, BOOL nextCached) {
        ++replacementFrames;
        return true;
      };
      return false;
    };
    emitSyntheticVideoFrame(capture);
    EXPECT_EQ(capture.stream,replacement);
    EXPECT_FALSE(capture.stopping);
    EXPECT_EQ(platf::macos::screen_capture_health().snapshot().state,platf::macos::capture_state::starting);
    EXPECT_EQ(platf::macos::screen_capture_health().snapshot().frames,0u);
    EXPECT_EQ(replacementFrames,0);
    emitSyntheticVideoFrame(capture);
    EXPECT_EQ(replacementFrames,1);
    EXPECT_TRUE(platf::macos::screen_capture_health().snapshot().ready());
    [capture stopCapture];
  }
}

TEST(NativeMacCaptureHealth, CachedCallbackKeepsSampleAliveAndCannotCreditReplacement) {
  @autoreleasepool {
    SCCapture *capture=inertCapture();
    emitSyntheticVideoFrame(capture);
    CMSampleBufferRef original=capture.lastValidSampleBuffer;
    ASSERT_NE(original,nullptr);
    const CFIndex originalRetains=CFGetRetainCount(original);
    __block bool retained=false, readable=false;
    __weak SCCapture *weakCapture=capture;
    SCStream *replacement=(SCStream*)[[InertVideoStream alloc] init];
    capture.videoCallback=^bool(CMSampleBufferRef sample, BOOL cached) {
      if (!cached) return true;
      // Check the retain before replacement to avoid a test-induced UAF on RED.
      retained=CFGetRetainCount(sample)>originalRetains;
      SCCapture *owner=weakCapture;
      owner.stream=replacement;
      if (retained) readable=CMSampleBufferDataIsReady(sample) && CMSampleBufferGetImageBuffer(sample)!=nullptr;
      return true;
    };
    emitSyntheticVideoFrame(capture,SCFrameStatusIdle);
    EXPECT_TRUE(retained);
    EXPECT_TRUE(readable);
    EXPECT_EQ(capture.stream,replacement);
    const auto current=platf::macos::screen_capture_health().snapshot();
    EXPECT_EQ(current.state,platf::macos::capture_state::starting);
    EXPECT_EQ(current.frames,0u);
    EXPECT_EQ(current.cached_frames,0u);
    EXPECT_FALSE(current.ready());
    [capture stopCapture];
  }
}

TEST(NativeMacCaptureHealth, DelegateDistinguishesCompleteIdleAndUnavailableSource) {
  @autoreleasepool {
    SCCapture *capture=inertCapture();
    __block int real=0, cached=0;
    capture.videoCallback=^bool(CMSampleBufferRef sample, BOOL wasCached) {
      if (wasCached) ++cached; else ++real;
      return true;
    };
    emitSyntheticVideoFrame(capture);
    EXPECT_EQ(real,1);
    EXPECT_TRUE(platf::macos::screen_capture_health().snapshot().ready());
    emitSyntheticVideoFrame(capture,SCFrameStatusIdle);
    EXPECT_TRUE(platf::macos::screen_capture_health().snapshot().ready());
    for (NSInteger status : {SCFrameStatusBlank, SCFrameStatusSuspended}) {
      emitSyntheticVideoFrame(capture,status);
      EXPECT_FALSE(platf::macos::screen_capture_health().snapshot().ready());
      EXPECT_EQ([capture captureResult],SCCaptureOutcomeRunning);
    }
    emitSyntheticVideoFrame(capture,-1); // absent metadata never certifies capture
    EXPECT_FALSE(platf::macos::screen_capture_health().snapshot().ready());
    EXPECT_EQ(real,1);
    EXPECT_EQ(cached,4);
    EXPECT_EQ(platf::macos::screen_capture_health().snapshot().frames,1u);
    EXPECT_EQ(platf::macos::screen_capture_health().snapshot().cached_frames,4u);
    [capture stopCapture];
  }
}

TEST(NativeMacCaptureHealth, LateSupersededOrInvalidSourceCannotCertifyCapture) {
  @autoreleasepool {
    SCCapture *capture=inertCapture();
    SCStream *old=capture.stream;
    capture.stream=(SCStream*)[[InertVideoStream alloc] init];
    emitSyntheticVideoFrame(capture,SCFrameStatusComplete,old);
    emitSyntheticVideoFrame(capture,SCFrameStatusComplete,nil,true);
    EXPECT_EQ(platf::macos::screen_capture_health().snapshot().frames,0u);
    EXPECT_EQ(platf::macos::screen_capture_health().snapshot().cached_frames,0u);
    EXPECT_FALSE(platf::macos::screen_capture_health().snapshot().ready());
    emitSyntheticVideoFrame(capture,SCFrameStatusStopped);
    EXPECT_EQ([capture captureResult],SCCaptureOutcomeRecoverable);
    EXPECT_EQ(dispatch_semaphore_wait(capture.captureSignal,DISPATCH_TIME_NOW),0);
    EXPECT_EQ(platf::macos::screen_capture_health().snapshot().state,platf::macos::capture_state::stopped);
    [capture stopCapture];
  }
}

TEST(NativeMacCaptureHealth, ReusingCaptureOwnerClearsPreviousGenerationAndCachedPixels) {
  @autoreleasepool {
    InertLifecycleVideoCapture *capture=[[InertLifecycleVideoCapture alloc] init];
    capture.started=dispatch_semaphore_create(0);
    VideoFrameCallbackBlock callback=^bool(CMSampleBufferRef sample, BOOL cached) { return true; };
    ASSERT_NE([capture captureVideo:callback audioCallback:nil],nil);
    emitSyntheticVideoFrame(capture);
    const auto first=platf::macos::screen_capture_health().snapshot();
    EXPECT_TRUE(first.ready());
    [capture stopCapture];
    ASSERT_NE([capture captureVideo:callback audioCallback:nil],nil);
    emitSyntheticVideoFrame(capture,SCFrameStatusIdle);
    const auto next=platf::macos::screen_capture_health().snapshot();
    EXPECT_NE(first.generation,next.generation);
    EXPECT_FALSE(next.ready());
    EXPECT_EQ(next.frames,0u);
    EXPECT_EQ(next.cached_frames,0u);
    EXPECT_EQ(capture.lastValidSampleBuffer,nullptr);
    [capture stopCapture];
  }
}
TEST(NativeMacVideoRecovery, RealBridgeReinitializesAndDeliversFramesAgainWithoutGlobalDarkRecovery) {
  @autoreleasepool {
    InertLifecycleVideoCapture *capture=[[InertLifecycleVideoCapture alloc] init];
    for(int cycle=0;cycle<2;++cycle) {
      capture.started=dispatch_semaphore_create(0);
      int frames=0;
      auto result=std::async(std::launch::async,[capture,&frames] { return platf::test_capture_video_bridge(capture,&frames); });
      ASSERT_EQ(dispatch_semaphore_wait(capture.started,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)),0);
      // Fifteen genuinely dark BGRA frames cross the old automatic-global-cure
      // threshold. Production now only logs a diagnostic; no power API is called.
      for(int frame=0;frame<15;++frame) emitSyntheticVideoFrame(capture);
      [capture stream:capture.stream didStopWithError:[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorInternalError userInfo:nil]];
      ASSERT_EQ(result.wait_for(std::chrono::seconds(2)),std::future_status::ready);
      EXPECT_EQ(result.get(),platf::capture_e::reinit);
      EXPECT_EQ(frames,15);
    }
  }
}
