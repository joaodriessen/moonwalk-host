/**
 * @file src/platform/macos/virtual_display.h
 * @brief Declarations for CGVirtualDisplay-based virtual display management on macOS.
 */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include "vd_geometry.h"

/**
 * @brief Pure cooldown gate for the timeout-triggered VD-creation self-heal cure (see
 *        hunt-vd-exhaustion.md root cause verdict). Exposed here, separate from the ObjC-only
 *        vd_helper spawn/retry logic, so it is unit-testable from plain C++ without pulling in
 *        Foundation/AppKit.
 * @param last_cure_at Unix timestamp the cure last ran for this trigger (0 = never run yet).
 * @param now Current unix timestamp.
 * @param cooldown_sec Minimum seconds required between cure runs for this trigger.
 * @return true if a cure attempted right now would be suppressed by the cooldown.
 */
bool virtual_display_selfheal_cooldown_active(time_t last_cure_at, time_t now, time_t cooldown_sec);

/**
 * @brief Wait action for the vd_helper spawn watchdog (see spawn_vd_helper_and_read_output() in
 *        virtual_display.m). Not "keep waiting" -- the three hang classes the watchdog kills the
 *        helper for.
 */
typedef enum {
  VD_HELPER_WAIT_CONTINUE = 0,       // keep waiting
  VD_HELPER_WAIT_STARTUP_HANG = 1,   // phase 1: zero stdout/stderr bytes within startup_alive_sec
  VD_HELPER_WAIT_SILENCE_HANG = 2,   // phase 2: alive, but idle_silence_sec since the last byte
  VD_HELPER_WAIT_BACKSTOP_HANG = 3,  // phase 2: alive, hard_backstop_sec since spawn regardless
} vd_helper_wait_action_t;

/**
 * @brief Pure decision function for the vd_helper spawn watchdog (judge finding N1, 2026-08-14
 *        primary-flip rework). Phase 1 requires a first sign of life (any stdout/stderr byte)
 *        within startup_alive_sec of spawn -- silence through that whole window is the churned-
 *        WindowServer startup-hang fingerprint (docs/hunt-vd-exhaustion.md). Once alive, the
 *        deadline is IDLE-based rather than a flat total-from-spawn budget: vd_helper's Step-4
 *        primary flip now runs BEFORE it reports the displayID (see vd_helper.m's Step 4 doc
 *        comment), so a slow-but-progressing flip -- which logs a stderr line at every
 *        wake/attempt -- must not be mistaken for a hang purely because it pushed the total
 *        elapsed time up; only genuine silence (idle_silence_sec with no new byte) means wedged.
 *        A hard backstop (hard_backstop_sec, measured from spawn) still applies regardless of
 *        activity, so a helper that somehow kept producing periodic output forever without ever
 *        reaching the displayID line still dies eventually. Exposed here, separate from the
 *        ObjC-only select()/pipe plumbing that calls it, so it is unit-testable from plain C++.
 * @param alive Whether any stdout/stderr byte has been seen yet this spawn.
 * @param since_spawn_sec Seconds elapsed since the helper was spawned.
 * @param since_activity_sec Seconds elapsed since the most recent stdout/stderr byte. Ignored
 *        while !alive (there has been no activity yet).
 * @param startup_alive_sec Phase-1 budget: max seconds to wait for the first byte.
 * @param idle_silence_sec Phase-2 budget: max seconds of silence once alive before treating the
 *        helper as wedged.
 * @param hard_backstop_sec Phase-2 hard cap: max total seconds since spawn regardless of activity.
 * @return The wait action the caller should take.
 */
vd_helper_wait_action_t vd_helper_wait_decide_action(bool alive, double since_spawn_sec, double since_activity_sec,
                                                       int startup_alive_sec, int idle_silence_sec, int hard_backstop_sec);

/**
 * @brief Create a virtual display with the specified resolution and refresh rate.
 * @param width Display width in pixels.
 * @param height Display height in pixels.
 * @param fps Refresh rate in Hz.
 * @return The CGDirectDisplayID of the created display, or 0 on failure.
 */
// will_create runs after taking the registry lock and must not reenter it.
uint32_t virtual_display_create(int width, int height, int fps, int desktop_scale, void (*will_create)(void));

/**
 * @brief Destroy the currently active virtual display.
 */
void virtual_display_destroy(void);

/**
 * @brief Get the display ID of the currently active virtual display.
 * @return The CGDirectDisplayID, or 0 if no virtual display is active.
 */
uint32_t virtual_display_get_id(void);

// Pending HTTP launches own a generation, not a volatile/reusable display ID.
uint32_t virtual_display_get_generation(void);
bool virtual_display_get_geometry(uint32_t display, uint32_t generation, vd_geometry_t *geometry);
// Completion runs under the registry lock, before another create can reset the
// teardown gate. It must not call back into virtual-display registry functions.
bool virtual_display_destroy_generation(uint32_t generation, void (*released)(void));

#ifdef __cplusplus
}
#endif
