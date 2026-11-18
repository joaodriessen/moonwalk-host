#import <Foundation/Foundation.h>
#include <initializer_list>
#include <src/platform/macos/virtual_display_mode.h>

#ifdef SKYLIGHT_VD_MODE_STANDALONE
#include <cstdio>
static int failures;
#define TEST(suite, name) static void suite##_##name()
#define EXPECT_TRUE(a) do { if (!(a)) { ++failures; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #a); } } while (0)
#define EXPECT_FALSE(a) EXPECT_TRUE(!(a))
#define EXPECT_EQ(a, b) EXPECT_TRUE((a) == (b))
#else
#include <gtest/gtest.h>
#endif

@interface InertVDMode : NSObject <SkylightVirtualMode>
@property(nonatomic) unsigned int width;
@property(nonatomic) unsigned int height;
@end
@implementation InertVDMode
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)fps {
  self = [super init];
  if (self) { self.width = width; self.height = height; }
  return self;
}
@end

@interface InertVDSettings : NSObject <SkylightVirtualSettings>
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray *modes;
@end
@implementation InertVDSettings
@end

@interface InertVDTarget : NSObject <SkylightVirtualSettingsTarget>
@property(nonatomic) BOOL rejectsSettings;
@property(nonatomic) int applyCount;
@end
@implementation InertVDTarget
- (BOOL)applySettings:(id)settings { ++_applyCount; return !_rejectsSettings; }
@end

TEST(NativeMacVirtualMode, HiDpiAdvertisesOneLogicalModeWithinBackingLimit) {
  @autoreleasepool {
    InertVDSettings *settings = skylight_virtual_display_settings(
        InertVDSettings.class, InertVDMode.class, 2880, 1800, 60, 2);
    EXPECT_EQ(settings.hiDPI, 1u);
    EXPECT_EQ(settings.modes.count, 1u);
    InertVDMode *mode = settings.modes.firstObject;
    EXPECT_EQ(mode.width, 1440u);
    EXPECT_EQ(mode.height, 900u);
    EXPECT_EQ(mode.width * 2, 2880u);
    EXPECT_EQ(mode.height * 2, 1800u);
  }
}

TEST(NativeMacVirtualMode, NativeScaleDoesNotAdvertiseRetinaModes) {
  @autoreleasepool {
    InertVDSettings *settings = skylight_virtual_display_settings(
        InertVDSettings.class, InertVDMode.class, 2880, 1800, 60, 1);
    EXPECT_EQ(settings.hiDPI, 0u);
    EXPECT_EQ(settings.modes.count, 1u);
    InertVDMode *mode = settings.modes.firstObject;
    EXPECT_EQ(mode.width, 2880u);
    EXPECT_EQ(mode.height, 1800u);
  }
}

TEST(NativeMacVirtualMode, ApplyFailureCannotPublishDisplay) {
  @autoreleasepool {
    InertVDTarget *display = [[InertVDTarget alloc] init];
    InertVDSettings *settings = [[InertVDSettings alloc] init];
    display.rejectsSettings = YES;
    EXPECT_EQ(skylight_virtual_display_apply(display, settings), nil);
    EXPECT_EQ(display.applyCount, 1);
    display.rejectsSettings = NO;
    EXPECT_EQ(skylight_virtual_display_apply(display, settings), display);
    EXPECT_EQ(display.applyCount, 2);
  }
}

TEST(NativeMacVirtualMode, AutomaticAndExplicitConstructionRespectBackingSize) {
  @autoreleasepool {
    struct Case { int width, height, requested, scale; };
    for (const Case c : {Case{2880,1800,0,2}, Case{1920,1080,0,1},
                         Case{2880,1800,1,1}, Case{1920,1080,2,2}, Case{2881,1801,0,1}}) {
      InertVDSettings *settings = skylight_virtual_display_settings(
          InertVDSettings.class, InertVDMode.class, c.width, c.height, 60, c.requested);
      InertVDMode *mode = settings.modes.firstObject;
      EXPECT_EQ(mode.width * c.scale, (unsigned)c.width);
      EXPECT_EQ(mode.height * c.scale, (unsigned)c.height);
      EXPECT_EQ(settings.hiDPI, c.scale == 2 ? 1u : 0u);
      EXPECT_EQ(settings.modes.count, 1u);
    }
    EXPECT_EQ(skylight_virtual_display_settings(InertVDSettings.class, InertVDMode.class,
                                                2881,1800,60,2), nil);
  }
}

TEST(NativeMacVirtualMode, NullModeApiStillRequiresCorrectLogicalBounds) {
  EXPECT_TRUE(skylight_desktop_mode_matches(2880,1800,0,1440,900,false,0,0));
  EXPECT_TRUE(skylight_desktop_mode_matches(2880,1800,2,1440,900,false,0,0));
  EXPECT_TRUE(skylight_desktop_mode_matches(2880,1800,1,2880,1800,false,0,0));
  // Actual owner failure: factory-default 1920x1200 was silently published.
  EXPECT_FALSE(skylight_desktop_mode_matches(2880,1800,0,1920,1200,false,0,0));
  EXPECT_FALSE(skylight_desktop_mode_matches(2880,1800,2,1920,1200,false,0,0));
  EXPECT_TRUE(skylight_desktop_mode_matches(2880,1800,2,1440,900,true,2880,1800));
  EXPECT_FALSE(skylight_desktop_mode_matches(2880,1800,2,1440,900,true,3840,2400));
  EXPECT_TRUE(skylight_desktop_mode_matches(2881,1801,0,2881,1801,false,0,0));
  EXPECT_FALSE(skylight_desktop_mode_matches(2881,1800,2,1440,900,false,0,0));
}

#ifdef SKYLIGHT_VD_MODE_STANDALONE
int main() {
  NativeMacVirtualMode_HiDpiAdvertisesOneLogicalModeWithinBackingLimit();
  NativeMacVirtualMode_NativeScaleDoesNotAdvertiseRetinaModes();
  NativeMacVirtualMode_ApplyFailureCannotPublishDisplay();
  NativeMacVirtualMode_AutomaticAndExplicitConstructionRespectBackingSize();
  NativeMacVirtualMode_NullModeApiStillRequiresCorrectLogicalBounds();
  printf("5 native inert mode construction/apply/bounds cases; failures=%d\n", failures);
  return failures ? 1 : 0;
}
#endif
