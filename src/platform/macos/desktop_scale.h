#pragma once

#include <stdbool.h>

// Shared with the Objective-C helper so its selected logical mode agrees with
// launch validation. Explicit 2x requires an exactly representable backing size.
static inline int skylight_desktop_scale(int width, int height, int requested) {
  if (requested < 0 || requested > 2 || width <= 0 || height <= 0) return -1;
  if (requested == 2 && ((width % 2) || (height % 2))) return -1;
  if (requested != 0) return requested;
  return (!(width % 2) && !(height % 2) && width >= 2560) ? 2 : 1;
}

// CG mode APIs may return NULL for a virtual display. Fresh logical bounds are
// still required; when a pixel mode exists its backing size must agree too.
static inline bool skylight_desktop_mode_matches(int width, int height, int scale,
                                                 double logical_width, double logical_height,
                                                 bool has_pixel_mode, int pixel_width, int pixel_height) {
  const int effective = skylight_desktop_scale(width, height, scale);
  return effective > 0 && logical_width == width / effective && logical_height == height / effective &&
      (!has_pixel_mode || (pixel_width == width && pixel_height == height));
}
