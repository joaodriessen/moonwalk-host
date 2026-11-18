/**
 * @file src/platform/macos/sc_capture.h
 * @brief Declarations for ScreenCaptureKit-based capture on macOS 12.3+.
 * @details This implementation captures both video AND system audio using ScreenCaptureKit.
 */
#pragma once

#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>

typedef NS_ENUM(NSInteger, SCCaptureOutcome) {
    SCCaptureOutcomeRunning, SCCaptureOutcomeStopped, SCCaptureOutcomeRecoverable, SCCaptureOutcomeFatal
};

API_AVAILABLE(macos(12.3))
@interface SCCapture : NSObject <SCStreamDelegate, SCStreamOutput>

#define kMaxDisplays 32

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) int frameRate;
@property (nonatomic, assign) OSType pixelFormat;
@property (nonatomic, assign) int frameWidth;
@property (nonatomic, assign) int frameHeight;
@property (nonatomic, assign) BOOL captureAudio;
@property (nonatomic, assign) BOOL showsCursor;  // mirrors platf::display_cursor; read by captureVideo:audioCallback: when (re)configuring the stream

@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) SCShareableContent *shareableContent;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) dispatch_queue_t audioQueue;

// Cached cadence delivery is not evidence that SCK generated a new frame.
typedef bool (^VideoFrameCallbackBlock)(CMSampleBufferRef, BOOL cached);
typedef void (^AudioSampleCallbackBlock)(CMSampleBufferRef);

@property (nonatomic, copy) VideoFrameCallbackBlock videoCallback;
@property (nonatomic, copy) AudioSampleCallbackBlock audioCallback;
@property (nonatomic, strong) dispatch_semaphore_t captureSignal;
@property (nonatomic, assign) BOOL stopping;
@property (nonatomic, assign) SCCaptureOutcome captureOutcome;
@property (nonatomic, assign) uint64_t healthGeneration;
- (SCCaptureOutcome)captureResult;
@property (nonatomic, assign) CMSampleBufferRef lastValidSampleBuffer;
@property (nonatomic, strong) dispatch_source_t frameDeliveryTimer;  // 60Hz timer for steady frame delivery
@property (nonatomic, strong) dispatch_queue_t deliveryQueue;        // queue for the timer

// Phase-1A steady_frame_delivery / v1 gap-filler (docs/design/pipeline-overhaul.md §3A). Set by
// the caller (display.mm) from config::video.frame_departure_mode -- YES only when mode == 1 (the
// default, shipped/live v1 behavior); NO for mode 0 (off) and mode 2 (v2-A encode-side phase-lock,
// docs/design/2026-07-13-cadence-phaselock.md, which never enables this capture-side timer). When
// NO, frameDeliveryTimer is never created and behavior is identical to today. When YES, the timer
// re-pushes lastValidSampleBuffer on a steady 1/frameRate cadence whenever SCK hasn't delivered a
// frame (real or backfilled) within the last interval -- a deadline-reset gap-filler, never an
// adder.
@property (nonatomic, assign) BOOL steadyFrameDelivery;

// Monotonic host-time stamp (seconds, see sc_capture_now_seconds() in sc_capture.m) of the most
// recent frame delivered via videoCallback -- updated on every real SCK frame, every SCK
// null-frame backfill, and every timer backfill. Touched only under @synchronized(self), same
// lock as lastValidSampleBuffer.
@property (nonatomic, assign) double lastDeliveryHostTime;

+ (NSArray<NSDictionary *> *)displayNames;
+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID;
+ (BOOL)isAvailable;

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
                      frameRate:(int)frameRate
                   captureAudio:(BOOL)captureAudio;

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight;
- (dispatch_semaphore_t)captureVideo:(VideoFrameCallbackBlock)videoCallback
                         audioCallback:(AudioSampleCallbackBlock)audioCallback;
- (void)stopCapture;

// Returns a new SCStreamConfiguration reflecting the receiver's current
// capture settings (including showsCursor). +1 — the caller owns it and
// must release it once handed off to SCStream.
- (SCStreamConfiguration *)newStreamConfiguration;

// Updates showsCursor and, if a stream is currently running, live-pushes the
// change via SCStream's updateConfiguration: (Apple-documented as supporting
// showsCursor changes without a stream restart). If no stream is running yet,
// the new value simply takes effect the next time captureVideo: starts one.
- (void)updateCursorVisibility:(BOOL)visible;

@end
