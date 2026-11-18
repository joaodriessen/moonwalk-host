/**
 * @file tests/unit/platform/test_headless_gate.cpp
 * @brief Test src/platform/macos/headless_gate.h -- the pure, CoreGraphics-free predicate deciding
 *        whether a real physical display is active (P3 Option A --
 *        docs/design/2026-07-12-p3-asleep-external-capture.md §3.1).
 * @details No CoreGraphics/ObjC dependency -- this header has zero macOS-API surface, so the
 *          decision is fully exercisable here even though `platf::has_active_physical_display()`
 *          (its only production caller, misc.mm) is macOS-only.
 */
#include "../../tests_common.h"

#include <src/platform/macos/headless_gate.h>

using namespace platf::macos;

TEST(HeadlessGate, EmptyListMeansNoPhysical) {
  // No active displays at all -- headless, create the VD.
  std::vector<DisplayDescriptor> active;
  EXPECT_FALSE(has_active_physical_display(active));
}

TEST(HeadlessGate, OnlyVirtualDisplayPresentMeansNoPhysical) {
  // A lingering/prior VD entry (vendor 0xF0F0) with nothing else active must not count as "a
  // physical is present" -- this is the "headless-ish" case the gate must still treat as
  // headless (create a fresh VD), never mistake our own VD for real content.
  std::vector<DisplayDescriptor> active {
    {.id = 41, .vendor_number = kVirtualDisplayVendorNumber, .is_builtin = false},
  };
  EXPECT_FALSE(has_active_physical_display(active));
}

TEST(HeadlessGate, OnePhysicalPresentMeansSkipVdCreation) {
  // A real external monitor (non-builtin, non-VD vendor) is active -- this is the Mode-1 root
  // cause case: skip VD creation so capture falls through to this physical instead of an empty
  // VD extend.
  std::vector<DisplayDescriptor> active {
    {.id = 40, .vendor_number = 0x1e6d /* e.g. LG */, .is_builtin = false},
  };
  EXPECT_TRUE(has_active_physical_display(active));
}

TEST(HeadlessGate, PhysicalPlusStaleVdStillMeansSkipVdCreation) {
  // A physical alongside a draining/stale VD entry (still visible for a few seconds post-release,
  // per virtual_display.m's ghost-drain grace) must still resolve to "physical present" -- the
  // real display wins regardless of a lingering VD entry.
  std::vector<DisplayDescriptor> active {
    {.id = 40, .vendor_number = 0x1e6d, .is_builtin = false},
    {.id = 41, .vendor_number = kVirtualDisplayVendorNumber, .is_builtin = false},
  };
  EXPECT_TRUE(has_active_physical_display(active));
}

TEST(HeadlessGate, BuiltinOnlyMeansNoPhysical) {
  // Per the design doc's exact predicate: a builtin display alone does not count as "an active
  // physical" for this gate -- only a non-builtin, non-VD entry does.
  std::vector<DisplayDescriptor> active {
    {.id = 1, .vendor_number = 0x0610 /* e.g. Apple built-in */, .is_builtin = true},
  };
  EXPECT_FALSE(has_active_physical_display(active));
}

TEST(HeadlessGate, BuiltinPlusExternalMeansPhysicalPresent) {
  // A builtin display alongside a real external -- the external still makes this "physical
  // present" (skip VD), since the predicate only needs ONE qualifying entry.
  std::vector<DisplayDescriptor> active {
    {.id = 1, .vendor_number = 0x0610, .is_builtin = true},
    {.id = 40, .vendor_number = 0x1e6d, .is_builtin = false},
  };
  EXPECT_TRUE(has_active_physical_display(active));
}
