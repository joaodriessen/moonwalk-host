#pragma once

#import <Foundation/Foundation.h>
#include "desktop_scale.h"

@protocol SkylightVirtualMode <NSObject>
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)fps;
@end
@protocol SkylightVirtualSettings <NSObject>
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray *modes;
@end
@protocol SkylightVirtualSettingsTarget <NSObject>
- (BOOL)applySettings:(id)settings;
@end

// Class arguments let native tests exercise the same mode construction with
// inert objects, without creating a display or contacting WindowServer.
static inline id skylight_virtual_display_settings(Class settingsClass, Class modeClass,
                                                    int width, int height, int fps, int scale) {
  const int effective = skylight_desktop_scale(width, height, scale);
  if (effective < 1 || fps <= 0) return nil;
  id<SkylightVirtualSettings> settings = [[settingsClass alloc] init];
  id<SkylightVirtualMode> mode = [(id<SkylightVirtualMode>)[modeClass alloc]
      initWithWidth:width / effective height:height / effective refreshRate:fps];
  if (!mode) return nil;
  // hiDPI modes are logical points, not backing pixels. Advertising the full
  // pixel size here asks for twice the descriptor's maximum backing size.
  settings.hiDPI = effective == 2;
  settings.modes = @[mode];
  return settings;
}

static inline id skylight_virtual_display_apply(id<SkylightVirtualSettingsTarget> display, id settings) {
  return display && settings && [display applySettings:settings] ? display : nil;
}
