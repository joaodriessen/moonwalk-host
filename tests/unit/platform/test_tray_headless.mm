#import <AppKit/AppKit.h>
#include <gtest/gtest.h>

// Run the actual tray initialization/event pump against an inert application.
// No NSApplication singleton, real status item, activation or user event is used.
@interface InertSkylightTrayApplication: NSObject
@property (nonatomic) NSInteger activationCount;
@property (nonatomic) NSInteger eventPollCount;
@property (nonatomic) NSApplicationActivationPolicy recordedPolicy;
@property (nonatomic, strong) id recordedDelegate;
+ (instancetype)sharedApplication;
- (void)setDelegate:(id)delegate;
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy;
- (void)activateIgnoringOtherApps:(BOOL)ignore;
- (NSEvent *)nextEventMatchingMask:(NSEventMask)mask untilDate:(NSDate *)date inMode:(NSRunLoopMode)mode dequeue:(BOOL)dequeue;
- (void)sendEvent:(NSEvent *)event;
- (void)postEvent:(NSEvent *)event atStart:(BOOL)atStart;
@end
@implementation InertSkylightTrayApplication
+ (instancetype)sharedApplication {
  static InertSkylightTrayApplication *instance;
  if (!instance) instance = [[self alloc] init];
  return instance;
}
- (void)setDelegate:(id)delegate { self.recordedDelegate = delegate; }
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy { self.recordedPolicy = policy; return YES; }
- (void)activateIgnoringOtherApps:(BOOL)ignore { ++self.activationCount; }
- (NSEvent *)nextEventMatchingMask:(NSEventMask)mask untilDate:(NSDate *)date inMode:(NSRunLoopMode)mode dequeue:(BOOL)dequeue {
  ++self.eventPollCount;
  return nil;
}
- (void)sendEvent:(NSEvent *)event {}
- (void)postEvent:(NSEvent *)event atStart:(BOOL)atStart {}
@end

// The vendored implementation is C/Objective-C; its void* menu callback needs
// a typed selector only in this Objective-C++ test translation unit.
struct tray_menu;
@interface NSValue (InertSkylightTrayPointer)
- (struct tray_menu *)skylightInertTrayPointer;
@end
@implementation NSValue (InertSkylightTrayPointer)
- (struct tray_menu *)skylightInertTrayPointer { return static_cast<struct tray_menu *>([self pointerValue]); }
@end

// Own copy of the production implementation isolates module statics and symbols
// from the linked tray library; only the AppKit application boundary is replaced.
#define pointerValue skylightInertTrayPointer
#define NSApplication InertSkylightTrayApplication
#define AppDelegate InertSkylightTrayDelegate
#define tray_set_headless skylight_inert_tray_set_headless
#define tray_init skylight_inert_tray_init
#define tray_loop skylight_inert_tray_loop
#define tray_update skylight_inert_tray_update
#define tray_exit skylight_inert_tray_exit
#include "../../../third-party/tray/src/tray_darwin.m"
#undef pointerValue
#undef NSApplication
#undef AppDelegate
#undef tray_set_headless
#undef tray_init
#undef tray_loop
#undef tray_update
#undef tray_exit

TEST(NativeMacHeadlessTray, InitializesAccessoryPumpWithoutActivatingAnotherApplication) {
  @autoreleasepool {
    InertSkylightTrayApplication *application = [InertSkylightTrayApplication sharedApplication];
    application.activationCount = 0;
    application.eventPollCount = 0;
    application.recordedPolicy = NSApplicationActivationPolicyRegular;
    skylight_inert_tray_set_headless(1);
    struct tray value = {};
    ASSERT_EQ(skylight_inert_tray_init(&value), 0);
    EXPECT_EQ(application.recordedPolicy, NSApplicationActivationPolicyAccessory);
    EXPECT_NE(application.recordedDelegate, nil);
    EXPECT_EQ(application.activationCount, 0);
    EXPECT_EQ(skylight_inert_tray_loop(0), 0);
    EXPECT_EQ(application.eventPollCount, 1);
    EXPECT_EQ(application.activationCount, 0);
    skylight_inert_tray_set_headless(0);
  }
}
