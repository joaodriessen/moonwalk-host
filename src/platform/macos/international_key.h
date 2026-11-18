#pragma once

namespace platf::macos {
  // The protocol shares 0xe2 between the ISO extra key and the non-normalized
  // JIS Ro key. Carbon Events.h values; this helper never posts an input event.
  inline int international_key(unsigned key, unsigned flags) {
    if (key != 0xe2) return -1;
    return (flags & 1) ? 0x5e /* kVK_JIS_Underscore */ : 0x0a /* kVK_ISO_Section */;
  }
}
