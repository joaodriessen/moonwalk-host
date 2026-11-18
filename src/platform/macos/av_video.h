/**
 * @file src/platform/macos/av_video.h
 * @brief Declarations for video capture on macOS.
 */
#pragma once

// platform includes
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>

struct CaptureSession {
  AVCaptureVideoDataOutput *output;
  NSCondition *captureStopped;
};

@interface AVVideo: NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

#define kMaxDisplays 32

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) CMTime minFrameDuration;
@property (nonatomic, assign) OSType pixelFormat;
@property (nonatomic, assign) int frameWidth;
@property (nonatomic, assign) int frameHeight;

typedef bool (^FrameCallbackBlock)(CMSampleBufferRef);

// session/videoOutputs/captureCallbacks/captureSignals are all owned by this
// instance for its whole lifetime (alloc'd in -initWithDisplay:frameRate:,
// manually released in -dealloc under MRC). `strong` is required for correct
// ARC teardown; under the prior `assign` MRC code `session` itself was never
// explicitly released — a pre-existing leak that `strong` also closes.
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) NSMapTable<AVCaptureConnection *, AVCaptureVideoDataOutput *> *videoOutputs;
@property (nonatomic, strong) NSMapTable<AVCaptureConnection *, FrameCallbackBlock> *captureCallbacks;
@property (nonatomic, strong) NSMapTable<AVCaptureConnection *, dispatch_semaphore_t> *captureSignals;

+ (NSArray<NSDictionary *> *)displayNames;
+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID;

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate;

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight;
- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback;
- (void)stopCapture;

@end
