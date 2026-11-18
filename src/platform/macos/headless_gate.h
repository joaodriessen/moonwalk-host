/**
 * @file src/platform/macos/headless_gate.h
 * @brief Pure predicate deciding whether a real, active physical display is present -- i.e.
 *        whether `create_virtual_display` should engage the VD-headless workaround at all
 *        (P3 Option A, `docs/design/2026-07-12-p3-asleep-external-capture.md` §1.2, §3.1).
 * @details No CoreGraphics/ObjC dependency here -- the CG-enumeration side lives in
 *          `platf::has_active_physical_display()` (misc.mm), which just builds a
 *          `DisplayDescriptor` list from `CGGetActiveDisplayList` and hands it to the predicate
 *          below, so the decision itself is exercisable from a plain C++ unit test (same
 *          separation `black_frame_detector.h` uses for the Mode-4 net).
 *
 *          Root cause this closes: a VD was created even when a real (but powered-off/parked)
 *          external monitor was present, so `create_virtual_display` minted a second, EMPTY
 *          desktop and capture bound to it -- an "empty extend," not a true black frame. The
 *          existing capture selector (`display.mm`'s `display()` factory) already falls back to
 *          `CGMainDisplayID()` whenever no VD exists, so simply not creating the VD when a
 *          physical is active is the whole fix -- no selector change needed.
 *
 *          Per the doc's live evidence (§1.2): `CGGetActiveDisplayList` already excludes a
 *          parked/asleep external (`active=0`) -- it is present in `CGGetOnlineDisplayList` but
 *          not here. So this predicate needs no separate asleep/online check of its own; it only
 *          has to filter the active list down to "a real physical," excluding the builtin display
 *          and our own virtual display (vendor `0xF0F0`, `vd_helper.m`'s descriptor signature).
 */
#pragma once

#include <cstdint>
#include <vector>

namespace platf::macos {

  // Vendor signature Skylight's own virtual display reports (vd_helper.m, and the ghost-signature
  // check in virtual_display.m/vd_helper.m) -- an active display carrying this vendor id is OUR
  // virtual display, never a real physical one, and must never count toward "physical present."
  constexpr std::uint32_t kVirtualDisplayVendorNumber = 0xF0F0;

  struct DisplayDescriptor {
    std::uint32_t id {0};
    std::uint32_t vendor_number {0};
    bool is_builtin {false};
  };

  // True iff `active_displays` (the caller passes exactly what CGGetActiveDisplayList reported)
  // contains at least one entry that is neither the builtin display nor our own virtual display
  // -- i.e. a real external physical display is actively driving content right now, and
  // `create_virtual_display` must skip VD creation and let capture fall through to it instead.
  // False (headless) covers both "list is empty" and "list contains only builtin/VD entries" --
  // a stale/draining VD entry alongside a real physical still correctly returns true (the
  // physical wins; the VD entry is simply ignored either way).
  inline bool has_active_physical_display(const std::vector<DisplayDescriptor> &active_displays) {
    for (const auto &display : active_displays) {
      if (!display.is_builtin && display.vendor_number != kVirtualDisplayVendorNumber) {
        return true;
      }
    }
    return false;
  }

}  // namespace platf::macos
