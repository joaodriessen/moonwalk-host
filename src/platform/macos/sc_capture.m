/**
 * @file src/platform/macos/sc_capture.m
 * @brief ScreenCaptureKit-based capture implementation for macOS 12.3+.
 * @details Captures both video AND system audio using Apple's ScreenCaptureKit API.
 */
#import "sc_capture.h"
#import "perf_trace.h"
#import "sc_capture_retry.h"
#include "capture_health.h"

#import <mach/mach_time.h>

// Monotonic host time in seconds, used by the steady_frame_delivery timer's deadline-reset
// (docs/design/pipeline-overhaul.md §3A) and the real/backfilled-frame stamps that feed it.
// mach_absolute_time() (not CFAbsoluteTimeGetCurrent()) so this can't jump on wall-clock/NTP
// adjustment -- mach/mach_time.h is part of libSystem, no additional framework link needed.
static double sc_capture_now_seconds(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&timebase);
    });
    uint64_t ticks = mach_absolute_time();
    return ((double) ticks * (double) timebase.numer / (double) timebase.denom) / 1e9;
}

static NSString *sc_capture_display_id_list(SCShareableContent *content) {
    NSMutableArray<NSString *> *displayIDs = [NSMutableArray array];
    for (SCDisplay *display in content.displays) {
        [displayIDs addObject:[NSString stringWithFormat:@"%u", display.displayID]];
    }
    return [displayIDs componentsJoinedByString:@","];
}

// ── P2 crash-proofing (docs/design/2026-07-12-black-screen-permanent-fix.md §3 "Fix for Mode 2 —
// SCK race must never kill the daemon") ─────────────────────────────────────────────────────────
// SCK is observed, live, to intermittently log "Capture started successfully" and then ~21ms
// later fail with "Failed to find any displays or windows to capture" -- its OWN enumeration
// lagging the just-applied display transaction, not a real failure (a healthy session on the same
// display proves it's capturable). Before this fix that error reached didStopWithError: (or an
// escaping exception reached the SCK callback thread directly) with nothing catching it there,
// which is a DIFFERENT thread/stack than video::captureThread's own try/catch
// (src/video.cpp ~1458) -- so that existing catch never saw it and the process called
// std::terminate. The fix below is entirely local to this file: catch at the actual SCK callback
// origin, gate re-starts on SCK actually being able to enumerate the display, and bound a
// transparent retry so the transient race self-heals instead of crashing.

// Bounds BOTH retry paths below: (a) the synchronous retry in captureVideo:audioCallback: when
// startCaptureWithCompletionHandler's completion itself reports failure outright, and (b) the
// asynchronous retry in didStopWithError: when a successful start is undone moments later by the
// transient race. "3" per the design doc's example.
static const NSInteger kSCCaptureMaxStartRetries = 3;

// Window after a successful start during which a stop-with-error is treated as "the race", not a
// real mid-session failure. Set well above the ~21ms observed live timing for margin.
static const NSTimeInterval kSCCaptureStartGraceSeconds = 0.5;

// Backoff between bounded start-retry attempts.
static const NSTimeInterval kSCCaptureStartRetryBackoffSeconds = 0.2;

// One-shot guard for the P0 test hook (maybeFireForceSCKRaceTestHookForStream: below): a forced
// race should only fire once per process, so the *next* real attempt is free to succeed normally
// and prove the catch+retry path actually recovers (rather than fighting itself forever).
static BOOL sSCCaptureForceRaceHookFired = NO;

@interface SCCapture ()

// Monotonic host-time stamp (sc_capture_now_seconds()) of the most recent successful
// startCaptureWithCompletionHandler completion; 0 until the first successful start ever. Used only
// to bound the "just started" grace window for the Mode-2 retry in didStopWithError:.
@property (nonatomic, assign) double captureStartHostTime;

// Bounded start-retry counter for the CURRENT captureVideo: cycle -- reset to 0 at the top of each
// fresh captureVideo:audioCallback: call (i.e. each new connect). Shared by the synchronous retry
// loop in captureVideo:audioCallback: and the asynchronous retry in didStopWithError:, so the two
// together never exceed kSCCaptureMaxStartRetries attempts for one connect.
@property (nonatomic, assign) NSInteger startRetryCount;

// Builds a fresh SCContentFilter+SCStream for `display`, wires up the outputs, and attempts
// startCaptureWithCompletionHandler once (waiting up to 5s). Returns YES iff the completion
// handler reported success. Must be called with @synchronized(self) already held by the caller.
- (BOOL)startCaptureStreamForDisplay:(SCDisplay *)display;

// Bounded, backing-off retry loop run after didStopWithError: detects the transient race; resumes
// capture transparently on success (captureSignal untouched) or, once retries are exhausted,
// signals captureSignal so the caller's poll loop treats this as an ended (not crashed) session.
- (void)retryStartAfterTransientRaceForDisplay:(CGDirectDisplayID)displayID;

// See src/platform/macos/sc_capture_retry.h -- the actual (ObjC/Foundation-free, unit-testable)
// predicate lives there; this just adapts the NSError.
- (BOOL)isTransientEnumerationError:(NSError *)error;

// P0 test hook (docs/design/2026-07-12-black-screen-permanent-fix.md Phase 0): env-gated, off by
// default. See its implementation below for the exact contract.
- (void)maybeFireForceSCKRaceTestHookForStream:(SCStream *)stream;

// F1 fix (2026-07-17 concurrency audit): the actual timer-backfill delivery, dispatched onto
// self.videoQueue by frameDeliveryTimerFired (which itself runs on the distinct deliveryQueue).
// Must only ever be invoked that way -- see its own doc comment for the full serialization
// argument.
- (void)deliverTimerBackfillFrame;

@end

API_AVAILABLE(macos(12.3))
@implementation SCCapture

@synthesize stream = _stream;

// Every new SCStream is a new source, including a transparent start-race retry
// inside the same captureVideo call. Reset under the same owner lock used by
// delegate/cache delivery so old pixels cannot certify a replacement's idle.
- (void)setStream:(SCStream *)stream {
    @synchronized(self) {
        if (_stream == stream) return;
        _stream = stream;
        if (stream) {
            self.healthGeneration = platf::macos::screen_capture_health().begin();
            if (self.lastValidSampleBuffer) {
                CFRelease(self.lastValidSampleBuffer);
                self.lastValidSampleBuffer = NULL;
            }
            self.lastDeliveryHostTime = sc_capture_now_seconds();
        }
    }
}

+ (BOOL)isAvailable {
    if (@available(macOS 12.3, *)) {
        return YES;
    }
    return NO;
}

+ (NSArray<NSDictionary *> *)displayNames {
    CGDirectDisplayID displays[kMaxDisplays];
    uint32_t count;
    if (CGGetActiveDisplayList(kMaxDisplays, displays, &count) != kCGErrorSuccess) {
        return [NSArray array];
    }

    NSMutableArray *result = [NSMutableArray array];

    for (uint32_t i = 0; i < count; i++) {
        [result addObject:@{
            @"id": [NSNumber numberWithUnsignedInt:displays[i]],
            @"name": [NSString stringWithFormat:@"%d", displays[i]],
            @"displayName": [self getDisplayName:displays[i]] ?: @"Unknown Display",
        }];
    }

    return [NSArray arrayWithArray:result];
}

+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID {
    for (NSScreen *screen in [NSScreen screens]) {
        if ([screen.deviceDescription[@"NSScreenNumber"] isEqualToNumber:[NSNumber numberWithUnsignedInt:displayID]]) {
            return screen.localizedName;
        }
    }
    return nil;
}

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
                      frameRate:(int)frameRate
                   captureAudio:(BOOL)captureAudio {
    self = [super init];
    if (self) {
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);

        self.displayID = displayID;
        self.frameRate = frameRate;
        self.pixelFormat = kCVPixelFormatType_32BGRA;
        self.captureAudio = captureAudio;
        self.showsCursor = YES;  // matches the prior hardcoded default; callers may override before captureVideo: starts

        if (mode) {
            self.frameWidth = (int)CGDisplayModeGetPixelWidth(mode);
            self.frameHeight = (int)CGDisplayModeGetPixelHeight(mode);
            CFRelease(mode);
        } else {
            // Virtual displays may not have a CGDisplayMode
            self.frameWidth = (int)CGDisplayPixelsWide(displayID);
            self.frameHeight = (int)CGDisplayPixelsHigh(displayID);
        }

        // Create dispatch queues for video and audio processing.
        // QOS_CLASS_USER_INTERACTIVE (latency program H1 finding): this is where the real
        // per-frame capture-delivery work happens (didOutputSampleBuffer:ofType:, including
        // process_frame() and the push into the encode pipeline) -- it was previously one QoS
        // tier below the C++ "capture" thread's QOS_CLASS_USER_INTERACTIVE badge (misc.mm), a
        // mismatch between the thread labeled critical and the thread actually doing
        // latency-critical work. Raised to match so this hot path gets scheduler priority
        // under real CPU contention, not just when the system is otherwise idle.
        dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, DISPATCH_QUEUE_PRIORITY_HIGH);
        self.videoQueue = dispatch_queue_create("dev.lizardbyte.sunshine.videoQueue", qos);
        self.audioQueue = dispatch_queue_create("dev.lizardbyte.sunshine.audioQueue", qos);
        self.deliveryQueue = dispatch_queue_create("dev.lizardbyte.sunshine.deliveryQueue", qos);

        // Initialize ScreenCaptureKit
        dispatch_semaphore_t initSemaphore = dispatch_semaphore_create(0);
        __block BOOL initSuccess = NO;

        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
            if (error) {
                NSLog(@"[SCCapture] Failed to get shareable content: %@", error.localizedDescription);
            } else {
                NSLog(@"[SCCapture] Initial SCShareableContent display IDs: [%@]", sc_capture_display_id_list(content));
                self.shareableContent = content;
                initSuccess = YES;
            }
            dispatch_semaphore_signal(initSemaphore);
        }];

        dispatch_semaphore_wait(initSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

        if (!initSuccess) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self stopCapture];
    // Under ARC, this method's remaining ivars/properties are __strong and are
    // released automatically once this method returns; [super dealloc] is
    // illegal to call explicitly under ARC and is no longer needed.
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
    self.frameWidth = frameWidth;
    self.frameHeight = frameHeight;
}

- (SCStreamConfiguration *)newStreamConfiguration {
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];  // __strong, ARC-owned
    config.width = self.frameWidth;
    config.height = self.frameHeight;
    // A little under the frame interval, not equal to it. Measured from the last delivery,
    // an interval equal to the display's refresh turns any scheduling slip into a delay for
    // the next frame too: delivery slid about 0.5 ms later each frame until ScreenCaptureKit
    // skipped a whole frame to catch up, about 2.6 times a second at 60 Hz.
    config.minimumFrameInterval = CMTimeMake(9, self.frameRate * 10);
    config.pixelFormat = self.pixelFormat;
    // queueDepth on THIS pipeline is not just latency headroom: it sizes the SCK IOSurface
    // pool, and this consumer is zero-copy + retain-heavy (av_img_t CFRetains the sample
    // buffer through capture->encode; lastValidSampleBuffer holds one more permanently for
    // the steady_frame_delivery gap-filler). At 3, one encode hiccup can exhaust the pool
    // and SCK stops delivering -- the frozen/black-stream class. Keep 5 (judged 2026-07-13,
    // latency-program: lowering it requires a live under-encode-load soak first).
    config.queueDepth = 5;
    config.showsCursor = self.showsCursor;

    // Enable audio capture - this is the key feature!
    if (self.captureAudio) {
        config.capturesAudio = YES;
        config.excludesCurrentProcessAudio = YES;  // Don't capture our own audio
        config.sampleRate = 48000;
        config.channelCount = 2;
    }

    return config;
}

- (void)updateCursorVisibility:(BOOL)visible {
    // @synchronized matches captureVideo:/stopCapture: below, guarding against
    // self.stream flipping to nil concurrently (this is called from the
    // per-frame video callback, off the lock those hold).
    @synchronized(self) {
        self.showsCursor = visible;

        if (!self.stream) {
            // Not currently streaming — self.showsCursor is picked up by
            // newStreamConfiguration the next time captureVideo: starts a stream.
            return;
        }

        SCStreamConfiguration *config = [self newStreamConfiguration];  // __strong local
        [self.stream updateConfiguration:config completionHandler:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"[SCCapture] Failed to update cursor visibility: %@", error.localizedDescription);
            }
        }];
        // Under ARC, config (a __strong local) is released automatically when it
        // goes out of scope; updateConfiguration: does not retain it past the call.
    }
}

- (SCDisplay *)findDisplayWithID:(CGDirectDisplayID)displayID {
    for (SCDisplay *display in self.shareableContent.displays) {
        if (display.displayID == displayID) {
            return display;
        }
    }
    return nil;
}

- (SCDisplay *)findDisplayWithIDRetrying:(CGDirectDisplayID)displayID {
    // First try with cached content
    SCDisplay *display = [self findDisplayWithID:displayID];
    if (display) return display;

    // Virtual displays may not appear immediately — retry with fresh content
    for (int attempt = 1; attempt <= 3; attempt++) {
        NSLog(@"[SCCapture] Display %u not found in SCShareableContent, refreshing (attempt %d/3)", displayID, attempt);
        [NSThread sleepForTimeInterval:1.0];

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL success = NO;

        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
            if (!error && content) {
                NSLog(@"[SCCapture] Refresh %d/3 SCShareableContent display IDs: [%@]", attempt, sc_capture_display_id_list(content));
                self.shareableContent = content;
                success = YES;
            }
            dispatch_semaphore_signal(sem);
        }];

        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

        if (success) {
            display = [self findDisplayWithID:displayID];
            if (display) {
                NSLog(@"[SCCapture] Found display %u after refresh", displayID);
                return display;
            }
        }
    }

    return nil;
}

- (dispatch_semaphore_t)captureVideo:(VideoFrameCallbackBlock)videoCallback
                       audioCallback:(AudioSampleCallbackBlock)audioCallback {
    @synchronized(self) {
        // Stop any existing capture before starting a new one
        if (self.stream) {
            dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
            [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
                dispatch_semaphore_signal(stopSem);
            }];
            dispatch_semaphore_wait(stopSem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            self.stream = nil;
        }

        // A prior frameDeliveryTimer (from an earlier captureVideo: call on this same instance,
        // e.g. a reconnect) must not keep running alongside the one we're about to create below.
        if (self.frameDeliveryTimer) {
            dispatch_source_cancel(self.frameDeliveryTimer);
            self.frameDeliveryTimer = nil;
        }

        self.stopping = NO;  // Reset stopping flag for new capture cycle
        self.videoCallback = videoCallback;
        self.audioCallback = audioCallback;
        self.captureSignal = dispatch_semaphore_create(0);
        self.startRetryCount = 0;  // fresh connect -- bounded start-retry budget resets
        self.captureOutcome = SCCaptureOutcomeRunning;
        self.healthGeneration = platf::macos::screen_capture_health().begin();
        if (self.lastValidSampleBuffer) {
            CFRelease(self.lastValidSampleBuffer);
            self.lastValidSampleBuffer = NULL;
        }

        SCDisplay *display = [self findDisplayWithIDRetrying:self.displayID];
        if (!display) {
            NSLog(@"[SCCapture] Display not found after retries: %u", self.displayID);
            platf::macos::screen_capture_health().note(self.healthGeneration, platf::macos::capture_state::failed, false);
            return nil;
        }

        // Bounded start-retry (P2 fix #3, docs/design/2026-07-12-black-screen-permanent-fix.md §3
        // Mode 2): startCaptureStreamForDisplay: builds a fresh filter+stream+outputs and attempts
        // startCaptureWithCompletionHandler once. On the overwhelmingly common first-try success
        // this loop runs exactly once with no added log output or delay -- identical to the prior
        // inline code. It only iterates when the completion handler itself reports failure
        // outright; the "succeeds, then dies moments later" variant of the same race is handled
        // separately, asynchronously, by didStopWithError: below (that variant can't be caught
        // here without adding latency to every normal connect).
        BOOL started = NO;
        for (NSInteger attempt = 1; attempt <= kSCCaptureMaxStartRetries && !started; attempt++) {
            if (attempt > 1) {
                // Pre-start enumeration gate (P2 fix #2): re-resolve the display before retrying --
                // if SCK's enumeration is still lagging, findDisplayWithIDRetrying's own bounded
                // wait gives it more time before the next start attempt.
                display = [self findDisplayWithIDRetrying:self.displayID];
                self.startRetryCount = attempt - 1;
                if (!display) {
                    NSLog(@"[SCCapture] Display %u no longer enumerable on start-retry attempt %ld/%ld",
                          self.displayID, (long) attempt, (long) kSCCaptureMaxStartRetries);
                    [NSThread sleepForTimeInterval:kSCCaptureStartRetryBackoffSeconds];
                    continue;
                }
            }

            started = [self startCaptureStreamForDisplay:display];

            if (!started && attempt < kSCCaptureMaxStartRetries) {
                NSLog(@"[SCCapture] startCapture attempt %ld/%ld failed, retrying...",
                      (long) attempt, (long) kSCCaptureMaxStartRetries);
                [NSThread sleepForTimeInterval:kSCCaptureStartRetryBackoffSeconds];
            }
        }

        if (!started) {
            NSLog(@"[SCCapture] Failed to start capture after %ld attempt(s)", (long) kSCCaptureMaxStartRetries);
            platf::macos::screen_capture_health().note(self.healthGeneration, platf::macos::capture_state::failed, false);
            return nil;
        }

        // Phase-1A frameDeliveryTimer (docs/design/pipeline-overhaul.md §3A): only wired when
        // steadyFrameDelivery is enabled. This is v1 of the frame-departure gap-filler and is
        // shipped and LIVE in production (frame_departure_mode == 1, the default -- NOT dark;
        // see config::video.frame_departure_mode / display.mm's wiring). v2, an encode-side
        // phase-lock selectable via frame_departure_mode == 2, ships dark alongside it (see
        // docs/design/2026-07-13-cadence-phaselock.md); the two never run at once, since
        // display.mm only sets steadyFrameDelivery YES for mode 1. Fires every 1/frameRate
        // seconds on the dedicated deliveryQueue; frameDeliveryTimerFired is the deadline-reset
        // gap-filler.
        if (self.steadyFrameDelivery) {
            // Seed so the timer's first fire doesn't see a stale/zero stamp as "overdue".
            self.lastDeliveryHostTime = sc_capture_now_seconds();

            int64_t intervalNanos = (int64_t) (1.0 / (double) (self.frameRate > 0 ? self.frameRate : 60) * NSEC_PER_SEC);

            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.deliveryQueue);
            dispatch_source_set_timer(timer,
                dispatch_time(DISPATCH_TIME_NOW, intervalNanos),
                (uint64_t) intervalNanos,
                (uint64_t) (1 * NSEC_PER_MSEC));  // ~1ms leeway

            __weak SCCapture *weakSelf = self;
            dispatch_source_set_event_handler(timer, ^{
                [weakSelf frameDeliveryTimerFired];
            });

            self.frameDeliveryTimer = timer;
            dispatch_resume(timer);
        }

        return self.captureSignal;
    }
}

// Builds a fresh SCContentFilter+SCStream for `display`, wires up the video/audio outputs, and
// attempts startCaptureWithCompletionHandler once, waiting up to 5s for its completion. Returns
// YES iff the completion handler reported success (no NSError). Any existing self.stream is torn
// down first -- retries rebuild the stream from scratch rather than reusing a possibly-poisoned
// one. Must be called with @synchronized(self) already held by the caller (both
// captureVideo:audioCallback: and retryStartAfterTransientRaceForDisplay: take that lock before
// calling in); this method does not re-synchronize itself.
//
// P2 boundary catch (docs/design/2026-07-12-black-screen-permanent-fix.md §3 Mode 2, fix #1): the
// whole body -- including the ObjC calls into ScreenCaptureKit and the start completion block --
// is wrapped so any escaping exception is caught right here at the SCK boundary and converted into
// a clean NO, never an uncaught throw. This file compiles as Objective-C++
// (cmake/compile_definitions/macos.cmake), so the unified exception model means this @try/@catch
// catches both NSExceptions AND C++ exceptions (e.g. std::bad_function_call) escaping from
// anything called transitively from here.
- (BOOL)startCaptureStreamForDisplay:(SCDisplay *)display {
    @try {
        if (self.stream) {
            dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
            [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
                dispatch_semaphore_signal(stopSem);
            }];
            dispatch_semaphore_wait(stopSem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            self.stream = nil;
        }

        // Pre-start enumeration gate (P2 fix #2): the display was already confirmed moments ago
        // (in captureVideo:'s findDisplayWithIDRetrying, or in the retry path below); re-check the
        // cheap, non-retrying way right before start to close the remaining window as close to the
        // source as possible. Normally a no-op -- no log, no delay -- on the common path where
        // nothing changed in between.
        if (![self findDisplayWithID:display.displayID]) {
            NSLog(@"[SCCapture] Display %u no longer enumerable immediately before start, re-resolving...", display.displayID);
            SCDisplay *refreshed = [self findDisplayWithIDRetrying:display.displayID];
            if (!refreshed) {
                NSLog(@"[SCCapture] Display %u vanished before start could begin", display.displayID);
                return NO;
            }
        }

        // Create content filter for the display
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];

        // Configure the stream
        SCStreamConfiguration *config = [self newStreamConfiguration];  // __strong local, handed to SCStream below

        // Create and configure the stream. self.stream is a `strong` property; under ARC the
        // setter retains the new value and the +1 local from alloc/init is released automatically
        // once this scope ends.
        NSError *error = nil;
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];

        // filter/config (__strong locals) were only needed to construct the stream, which retains
        // what it needs; they release themselves automatically at end of scope.

        if (!self.stream) {
            NSLog(@"[SCCapture] Failed to create SCStream");
            return NO;
        }

        // Add video output
        if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.videoQueue error:&error]) {
            NSLog(@"[SCCapture] Failed to add video output: %@", error.localizedDescription);
            // Bug fix (bonus, latent in the prior MRC code too): a live SCStream was left
            // running/orphaned here since self.stream was never torn down on this failure path.
            // Stop and clear it so we don't leak a running capture the caller believes never
            // started (caller sees nil and treats this as a hard failure).
            [self.stream stopCaptureWithCompletionHandler:^(NSError *stopError) {}];
            self.stream = nil;
            return NO;
        }

        // Add audio output if enabled
        if (self.captureAudio) {
            if (![self.stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self.audioQueue error:&error]) {
                NSLog(@"[SCCapture] Failed to add audio output: %@", error.localizedDescription);
                // Continue without audio - video is more important
            } else {
                NSLog(@"[SCCapture] System audio capture enabled!");
            }
        }

        // Start capture
        dispatch_semaphore_t startSemaphore = dispatch_semaphore_create(0);
        __block BOOL startSuccess = NO;
        SCStream *startedStream = self.stream;  // captured now -- a later retry could reassign self.stream

        [self.stream startCaptureWithCompletionHandler:^(NSError *error) {
            @try {
                if (error) {
                    NSLog(@"[SCCapture] Failed to start capture: %@", error.localizedDescription);
                } else {
                    NSLog(@"[SCCapture] Capture started successfully with%@ audio", self.captureAudio ? @"" : @"out");
                    startSuccess = YES;
                }
            } @catch (NSException *exception) {
                NSLog(@"[SCCapture] Exception in start-capture completion handler: %@ -- treating as a failed start, not crashing", exception);
            } @catch (...) {
                NSLog(@"[SCCapture] Unknown exception in start-capture completion handler -- treating as a failed start, not crashing");
            }
            dispatch_semaphore_signal(startSemaphore);
        }];

        dispatch_semaphore_wait(startSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

        if (startSuccess) {
            self.captureStartHostTime = sc_capture_now_seconds();
            // P0 test hook -- see its own doc comment; env-gated, off by default, no-op otherwise.
            [self maybeFireForceSCKRaceTestHookForStream:startedStream];
        }

        return startSuccess;
    } @catch (NSException *exception) {
        NSLog(@"[SCCapture] Exception starting capture stream: %@ -- treating as a failed start, not crashing", exception);
        return NO;
    } @catch (...) {
        NSLog(@"[SCCapture] Unknown exception starting capture stream -- treating as a failed start, not crashing");
        return NO;
    }
}

// Bounded, backing-off retry loop invoked (on a background queue, never the SCK delegate thread
// itself) after didStopWithError: detects the transient Mode-2 race. Resumes capture transparently
// on success -- captureSignal is left untouched, so the caller (video::captureThread's poll loop
// in display.mm capture()) never observed a failure at all. Only once retries are exhausted (or
// the session is independently tearing down) does this signal captureSignal, so the session ends
// cleanly -- recoverable via P1's relaunch seatbelt if this were somehow a full daemon crash, but
// here it's just "this capture attempt didn't pan out," never a terminate.
- (void)retryStartAfterTransientRaceForDisplay:(CGDirectDisplayID)displayID {
    while (YES) {
        BOOL succeeded = NO;
        BOOL giveUp = NO;

        @synchronized(self) {
            if (self.stopping || !self.videoCallback) {
                giveUp = YES;  // session tearing down independently -- nothing to retry into
            } else if (self.startRetryCount >= kSCCaptureMaxStartRetries) {
                giveUp = YES;
            } else {
                self.startRetryCount++;
                SCDisplay *display = [self findDisplayWithIDRetrying:displayID];
                succeeded = display && [self startCaptureStreamForDisplay:display];
                if (succeeded) {
                    self.captureOutcome = SCCaptureOutcomeRunning;
                    NSLog(@"[SCCapture] Start-retry attempt %ld/%ld succeeded after transient SCK race -- capture resumed",
                          (long) self.startRetryCount, (long) kSCCaptureMaxStartRetries);
                } else {
                    NSLog(@"[SCCapture] Start-retry attempt %ld/%ld failed",
                          (long) self.startRetryCount, (long) kSCCaptureMaxStartRetries);
                }
            }
        }

        if (succeeded) {
            return;  // capture resumed transparently -- captureSignal untouched
        }
        if (giveUp) {
            break;
        }

        [NSThread sleepForTimeInterval:kSCCaptureStartRetryBackoffSeconds];
    }

    NSLog(@"[SCCapture] Start-retry exhausted (or session ending) -- failing this capture session cleanly, not crashing");
    self.captureOutcome = SCCaptureOutcomeFatal;
    @synchronized(self) {
        platf::macos::screen_capture_health().note(self.healthGeneration, platf::macos::capture_state::failed, false);
        if (self.captureSignal) {
            dispatch_semaphore_signal(self.captureSignal);
        }
    }
}

- (BOOL)isTransientEnumerationError:(NSError *)error {
    if (!error) {
        return NO;
    }
    NSString *description = error.localizedDescription ?: @"";
    return platf::macos::is_transient_sck_enumeration_race([description UTF8String] ?: "");
}

// P0 test hook (docs/design/2026-07-12-black-screen-permanent-fix.md Phase 0): when the
// SUNSHINE_TEST_FORCE_SCK_RACE environment variable is set (to any non-empty value),
// deterministically reproduces the Mode-2 race -- a synthetic didStopWithError: carrying the exact
// transient message, fired ~21ms after a real successful start (matching the observed live
// timing) -- so the catch+gate+retry path above can be exercised on demand instead of waiting for
// the real, rare SCK race. Fires at most once per process (a static flag) so the very next real
// start attempt is free to succeed normally and prove recovery. OFF by default: with the env var
// unset this is a single getenv() call and nothing else runs.
- (void)maybeFireForceSCKRaceTestHookForStream:(SCStream *)stream {
    if (sSCCaptureForceRaceHookFired) {
        return;
    }
    const char *envVal = getenv("SUNSHINE_TEST_FORCE_SCK_RACE");
    if (!envVal || envVal[0] == '\0') {
        return;
    }
    sSCCaptureForceRaceHookFired = YES;

    NSLog(@"[SCCapture] TEST HOOK: SUNSHINE_TEST_FORCE_SCK_RACE set -- scheduling synthetic Mode-2 race in ~21ms");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.021 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *fakeError = [NSError errorWithDomain:@"SCCaptureTestHook"
                                                      code:-1
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Failed to find any displays or windows to capture"}];
            [self stream:stream didStopWithError:fakeError];
        });
}

// Timer handler for steady_frame_delivery (docs/design/pipeline-overhaul.md §3A). Deadline-reset
// gap-filler: re-pushes lastValidSampleBuffer ONLY if no real or backfilled frame has gone out
// within the last interval, so it never fires in ADDITION to a real frame on the same tick (the
// 82fps-class over-delivery this design explicitly guards against, 4cb6511c).
//
// F1 fix (2026-07-17 concurrency audit -- cross-queue race on capture_ctxs/imgs): this handler
// runs on self.deliveryQueue, a queue DISTINCT from self.videoQueue. self.videoQueue is what SCK
// invokes -stream:didOutputSampleBuffer:ofType: on for SCStreamOutputTypeScreen (see
// captureVideo:audioCallback:'s addStreamOutput:...sampleHandlerQueue:self.videoQueue), which is
// where BOTH the real-frame path and the null-frame backfill path (inside that same delegate
// method, a few lines below in this file) invoke videoCallback. The real-frame path deliberately
// invokes videoCallback OUTSIDE @synchronized(self) (see its "Minimal critical section" comment)
// specifically to avoid a callback-wide lock that once starved SCK delivery and wedged
// WindowServer (WS2) -- so this timer's own @synchronized(self) was NEVER capable of excluding
// that path; the two could run the videoCallback block (which mutates std::vector capture_ctxs
// and std::list imgs with no C++-side lock) concurrently on two different threads.
//
// Fix: this method only does the cheap "does a backfill even look due" peek (still under
// @synchronized(self), consistent with the ivars it touches), and if so, dispatches the actual
// delivery onto self.videoQueue via -deliverTimerBackfillFrame, which re-checks everything there.
// That makes all three videoCallback call sites -- real frame, null-frame backfill, and this timer
// backfill -- serialize on the single videoQueue, with ZERO added lock scope around the real-frame
// hot path (it is untouched by this fix).
- (void)frameDeliveryTimerFired {
    BOOL maybeDue = NO;

    @synchronized(self) {
        // stopping/videoCallback-nil guard: stopCapture cancels+nils frameDeliveryTimer under
        // this same lock BEFORE tearing down the stream (see stopCapture below), so by the time
        // this handler can acquire the lock after a cancellation race, videoCallback is already
        // nil here and this is a safe no-op -- never pushes into a torn-down pipeline. Also bail
        // out here if there's nothing cached to backfill with yet.
        if (self.stopping || !self.videoCallback || !self.lastValidSampleBuffer) {
            return;
        }

        double interval = 1.0 / (double) (self.frameRate > 0 ? self.frameRate : 60);
        double now = sc_capture_now_seconds();
        maybeDue = (now - self.lastDeliveryHostTime) >= interval;
    }

    if (!maybeDue) {
        return;
    }

    // Lifetime: weakSelf avoids this pending block keeping SCCapture (and its videoQueue) alive
    // past its natural lifetime if the object is torn down before this fires; if self has been
    // deallocated by the time the block runs, messaging nil is a safe no-op. If self IS still
    // alive, the block captures it strongly for the duration of -deliverTimerBackfillFrame, so
    // nothing it touches (self, self.videoQueue, the ivars read inside) can be freed mid-call.
    __weak SCCapture *weakSelf = self;
    dispatch_async(self.videoQueue, ^{
        [weakSelf deliverTimerBackfillFrame];
    });
}

// Runs on self.videoQueue ONLY -- dispatched from frameDeliveryTimerFired above, which runs on the
// distinct deliveryQueue. Re-does the full due-check here (not just the peek in
// frameDeliveryTimerFired) because time passes between that peek and this block actually running
// on videoQueue; a real frame (or the null-frame backfill, both also on videoQueue, and thus now
// serialized against this very block) may have landed in that window and already covered this
// tick, in which case this is correctly a no-op -- never a double-delivery.
- (void)deliverTimerBackfillFrame {
    VideoFrameCallbackBlock videoCallback;
    CMSampleBufferRef sampleBufferToDeliver = NULL;

    @synchronized(self) {
        if (self.stopping || !self.videoCallback) {
            return;
        }

        double interval = 1.0 / (double) (self.frameRate > 0 ? self.frameRate : 60);
        double now = sc_capture_now_seconds();

        // Deadline-reset: a real or backfilled frame already covered this tick while this block
        // was in flight from deliveryQueue to videoQueue -- do nothing.
        if ((now - self.lastDeliveryHostTime) < interval) {
            return;
        }

        if (!self.lastValidSampleBuffer) {
            return;
        }

        // Retain to invoke OUTSIDE the lock below (minimal critical section, matching the
        // real-frame path's own discipline in didOutputSampleBuffer:ofType: just below in this
        // file -- a callback-wide lock previously starved SCK delivery and wedged WindowServer,
        // WS2). self.lastValidSampleBuffer can't be swapped from under us mid-section: the
        // real-frame path's cache-update @synchronized(self) block and this one are mutually
        // exclusive via the lock, and (post-fix) both also run on this same serial videoQueue.
        sampleBufferToDeliver = (CMSampleBufferRef) CFRetain(self.lastValidSampleBuffer);
        videoCallback = self.videoCallback;
        self.lastDeliveryHostTime = now;
        platf::macos::screen_capture_health().cached(self.healthGeneration);
    }

    // Return value deliberately ignored here, matching the pre-existing null-frame backfill path
    // a few lines below (its own comment: "Return value was never checked on this path before, so
    // that stays unchanged") -- only the real-frame path acts on shouldContinue.
    @try {
        videoCallback(sampleBufferToDeliver, YES);
    } @catch (NSException *exception) {
        NSLog(@"[SCCapture] Exception in videoCallback (timer backfill): %@ -- ignoring, not crashing", exception);
    } @catch (...) {
        NSLog(@"[SCCapture] Unknown exception in videoCallback (timer backfill) -- ignoring, not crashing");
    }
    CFRelease(sampleBufferToDeliver);
}

- (SCCaptureOutcome)captureResult {
    @synchronized(self) { return self.captureOutcome; }
}

- (void)stopCapture {
    @synchronized(self) {
        self.stopping = YES;
        platf::macos::screen_capture_health().note(self.healthGeneration, platf::macos::capture_state::stopped, false);
        if (self.captureOutcome == SCCaptureOutcomeRunning) self.captureOutcome = SCCaptureOutcomeStopped;
        // Cancel the frame delivery timer first
        if (self.frameDeliveryTimer) {
            dispatch_source_cancel(self.frameDeliveryTimer);
            self.frameDeliveryTimer = nil;
        }

        if (self.stream) {
            dispatch_semaphore_t stopSemaphore = dispatch_semaphore_create(0);

            [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
                if (error) {
                    NSLog(@"[SCCapture] Error stopping capture: %@", error.localizedDescription);
                }
                dispatch_semaphore_signal(stopSemaphore);
            }];

            dispatch_semaphore_wait(stopSemaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            self.stream = nil;
        }

        if (self.captureSignal) {
            dispatch_semaphore_signal(self.captureSignal);
            self.captureSignal = nil;
        }

        self.videoCallback = nil;
        self.audioCallback = nil;

        if (self.lastValidSampleBuffer) {
            CFRelease(self.lastValidSampleBuffer);
            self.lastValidSampleBuffer = NULL;
        }
    }
}

#pragma mark - SCStreamDelegate

// P2 boundary catch + retry trigger (docs/design/2026-07-12-black-screen-permanent-fix.md §3
// Mode 2). This delegate method fires on an SCK-internal callback thread/queue, NOT
// video::captureThread's own stack -- src/video.cpp's captureThread try/catch (~line 1458) never
// sees anything that happens here, which is exactly why the crash this fixes went uncaught before:
// the whole method body is now wrapped so nothing can escape this frame, and the specific
// "started successfully, then died within N ms" transient race is detected and handed off to a
// bounded, self-healing retry instead of tearing down the session (let alone the whole process).
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    @try {
        NSLog(@"[SCCapture] Stream stopped with error: %@", error.localizedDescription);

        BOOL shouldRetryAsync = NO;
        CGDirectDisplayID displayID = 0;

        @synchronized(self) {
            // An old stream may stop after its replacement starts. Its callback
            // cannot complete the replacement owner or trigger another recovery.
            if (stream != self.stream || self.stopping) return;
            double sinceStart = sc_capture_now_seconds() - self.captureStartHostTime;
            BOOL withinGraceWindow = self.captureStartHostTime > 0 && sinceStart >= 0 && sinceStart < kSCCaptureStartGraceSeconds;

            if (stream == self.stream
                && !self.stopping
                && self.videoCallback
                && withinGraceWindow
                && [self isTransientEnumerationError:error]
                && self.startRetryCount < kSCCaptureMaxStartRetries) {
                shouldRetryAsync = YES;
                displayID = self.displayID;
                self.captureOutcome = SCCaptureOutcomeRecoverable;
                platf::macos::screen_capture_health().note(self.healthGeneration, platf::macos::capture_state::recovering, false);
                NSLog(@"[SCCapture] Transient SCK enumeration race %.0f ms after start -- scheduling bounded start-retry",
                      sinceStart * 1000.0);
            }
        }

        if (shouldRetryAsync) {
            // Off the SCK delegate queue -- never block or retry SCK API calls from inside its own
            // callback. captureSignal is deliberately NOT signaled here: the caller keeps polling
            // and, if the retry below succeeds, never observes a failure at all.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [self retryStartAfterTransientRaceForDisplay:displayID];
            });
            return;
        }

        // Explicit user stop, denied permission, entitlement or invalid request
        // are permanent. Framework interruption/internal/enumeration errors use
        // the C++ owner's bounded capture reinit budget, not a whole-session exit.
        @synchronized(self) {
            if (stream != self.stream || self.stopping) return;
            const BOOL permanent = [error.domain isEqualToString:SCStreamErrorDomain] &&
                (error.code == SCStreamErrorUserDeclined || error.code == SCStreamErrorMissingEntitlements ||
                 error.code == SCStreamErrorInvalidParameter || error.code == SCStreamErrorUserStopped);
            self.captureOutcome = permanent ? SCCaptureOutcomeFatal : SCCaptureOutcomeRecoverable;
            platf::macos::screen_capture_health().note(self.healthGeneration,
                permanent ? platf::macos::capture_state::failed : platf::macos::capture_state::recovering, false);
            if (self.captureSignal) dispatch_semaphore_signal(self.captureSignal);
        }
    } @catch (NSException *exception) {
        self.captureOutcome = SCCaptureOutcomeFatal;
        platf::macos::screen_capture_health().note(self.healthGeneration, platf::macos::capture_state::failed, false);
        NSLog(@"[SCCapture] Exception in didStopWithError: %@ -- failing this capture session cleanly, not crashing", exception);
        if (self.captureSignal) {
            dispatch_semaphore_signal(self.captureSignal);
        }
    } @catch (...) {
        self.captureOutcome = SCCaptureOutcomeFatal;
        platf::macos::screen_capture_health().note(self.healthGeneration, platf::macos::capture_state::failed, false);
        NSLog(@"[SCCapture] Unknown exception in didStopWithError -- failing this capture session cleanly, not crashing");
        if (self.captureSignal) {
            dispatch_semaphore_signal(self.captureSignal);
        }
    }
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {

    if (type == SCStreamOutputTypeScreen) {
        using platf::macos::capture_state;
        // SCFrameStatus, rather than presence of an IOSurface, identifies new
        // content. Idle is healthy unchanged content; other statuses are kept
        // distinct even while cadence delivery uses the previous valid frame.
        capture_state state = capture_state::unknown;
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
            NSNumber *status = info[SCStreamFrameInfoStatus];
            if ([status isKindOfClass:[NSNumber class]]) {
                switch (status.integerValue) {
                    case SCFrameStatusComplete: state = capture_state::complete; break;
                    case SCFrameStatusIdle: state = capture_state::idle; break;
                    case SCFrameStatusBlank: state = capture_state::blank; break;
                    case SCFrameStatusSuspended: state = capture_state::suspended; break;
                    case SCFrameStatusStarted: state = capture_state::started; break;
                    case SCFrameStatusStopped: state = capture_state::stopped; break;
                    default: break;
                }
            }
        }
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        const BOOL validImage = pixelBuffer && CMSampleBufferIsValid(sampleBuffer) &&
            CMSampleBufferDataIsReady(sampleBuffer) && CVPixelBufferGetWidth(pixelBuffer) > 0 &&
            CVPixelBufferGetHeight(pixelBuffer) > 0;
        BOOL newFrame = NO;
        uint64_t sampleGeneration = 0;
        @synchronized(self) {
            if (stream != self.stream || self.stopping || self.captureOutcome != SCCaptureOutcomeRunning) return;
            sampleGeneration = self.healthGeneration;
            newFrame = platf::macos::screen_capture_health().note(self.healthGeneration, state, validImage);
            if (state == capture_state::stopped) {
                self.captureOutcome = SCCaptureOutcomeRecoverable;
                if (self.captureSignal) dispatch_semaphore_signal(self.captureSignal);
                return;
            }
        }
        if (!newFrame) {
            if (state == capture_state::idle) perf_trace_note_sck_idle();
            // Keep an independent sample/block alive across a reentrant callback
            // that may replace the stream or stop capture and clear the cache.
            CMSampleBufferRef cachedSample = NULL;
            VideoFrameCallbackBlock cachedCallback;
            @synchronized(self) {
                if (stream != self.stream || sampleGeneration != self.healthGeneration) return;
                if (self.lastValidSampleBuffer && !self.stopping && self.videoCallback) {
                    cachedSample = (CMSampleBufferRef)CFRetain(self.lastValidSampleBuffer);
                    cachedCallback = self.videoCallback;
                    platf::macos::screen_capture_health().cached(sampleGeneration);
                    self.lastDeliveryHostTime = sc_capture_now_seconds();
                }
            }
            if (!cachedSample) return;
            // As before, only complete-frame delivery acts on the return value.
            @try {
                cachedCallback(cachedSample, YES);
            } @catch (NSException *exception) {
                NSLog(@"[SCCapture] Exception in videoCallback (null-frame backfill): %@ -- ignoring, not crashing", exception);
            } @catch (...) {
                NSLog(@"[SCCapture] Unknown exception in videoCallback (null-frame backfill) -- ignoring, not crashing");
            }
            CFRelease(cachedSample);
            return;
        }

        perf_trace_note_sck_real();

        // Cache this valid frame for re-delivery during idle periods, and stamp the delivery
        // clock (same @synchronized(self) the timer handler uses for both fields).
        @synchronized(self) {
            if (stream != self.stream || sampleGeneration != self.healthGeneration || self.stopping) return;
            if (self.lastValidSampleBuffer) {
                CFRelease(self.lastValidSampleBuffer);
            }
            self.lastValidSampleBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);
            self.lastDeliveryHostTime = sc_capture_now_seconds();
        }

        // Minimal critical section: copy the stopping flag + block pointer under
        // the SAME @synchronized(self) lock -stopCapture uses to nil videoCallback
        // (see below), then invoke the copy OUTSIDE the lock. This closes the race
        // where stopCapture nils videoCallback while this callback is mid-read on
        // the (separate) video queue, WITHOUT holding the lock across the actual
        // encode/CG work in the callback -- a callback-wide lock previously
        // starved SCK delivery and wedged WindowServer (owner-session-runbook.md WS2).
        BOOL stopping;
        VideoFrameCallbackBlock videoCallback;
        @synchronized(self) {
            if (stream != self.stream || sampleGeneration != self.healthGeneration) return;
            stopping = self.stopping;
            videoCallback = self.videoCallback;
        }
        if (stopping) return;
        if (videoCallback) {
            // P2 boundary catch (fix #1): this is the exact call site the design doc's evidence
            // traces the uncaught std::bad_function_call / NSException to -- SCK invokes this
            // delegate method on its own callback queue, never captureThread's stack, so
            // video.cpp's existing captureThread try/catch cannot see an exception thrown here.
            // On no exception (the overwhelmingly common case) shouldContinue is exactly
            // videoCallback(sampleBuffer)'s real return value, so behavior is unchanged.
            BOOL shouldContinue = YES;
            @try {
                shouldContinue = videoCallback(sampleBuffer, NO);
            } @catch (NSException *exception) {
                NSLog(@"[SCCapture] Exception in videoCallback: %@ -- stopping this capture cleanly, not crashing", exception);
                shouldContinue = NO;
            } @catch (...) {
                NSLog(@"[SCCapture] Unknown exception in videoCallback -- stopping this capture cleanly, not crashing");
                shouldContinue = NO;
            }
            if (!shouldContinue) {
                @synchronized(self) {
                    if (stream != self.stream || sampleGeneration != self.healthGeneration) return;
                    self.stopping = YES;
                }
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    @synchronized(self) {
                        if (stream != self.stream || sampleGeneration != self.healthGeneration) return;
                        [self stopCapture];
                    }
                });
            }
        }
    } else if (type == SCStreamOutputTypeAudio) {
        AudioSampleCallbackBlock audioCallback;
        @synchronized(self) {
            audioCallback = self.audioCallback;
        }
        if (audioCallback) {
            @try {
                audioCallback(sampleBuffer);
            } @catch (NSException *exception) {
                NSLog(@"[SCCapture] Exception in audioCallback: %@ -- dropping this sample, not crashing", exception);
            } @catch (...) {
                NSLog(@"[SCCapture] Unknown exception in audioCallback -- dropping this sample, not crashing");
            }
        }
    }
}

@end
