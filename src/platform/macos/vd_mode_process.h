/** Bounded fresh-exec mode handshake. No display enumeration or mutation here. */
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <objc/objc.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "vd_geometry.h"
extern char **environ;

static double monotonicSeconds(void) {
  struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
  return now.tv_sec + now.tv_nsec / 1e9;
}

static BOOL freshModeBefore(const char *executable, CGDirectDisplayID display, int width, int height,
                       int fps, int scale, BOOL selectMode, vd_geometry_t *geometry, double deadline) {
  if (monotonicSeconds() >= deadline) return NO;
  int pipefd[2]; if (pipe(pipefd)) return NO;
  char id[16], w[16], h[16], rate[16], factor[16], set[2];
  snprintf(id,sizeof(id),"%u",display); snprintf(w,sizeof(w),"%d",width); snprintf(h,sizeof(h),"%d",height);
  snprintf(rate,sizeof(rate),"%d",fps); snprintf(factor,sizeof(factor),"%d",scale); snprintf(set,sizeof(set),"%d",selectMode ? 1 : 0);
  char command[] = "--mode";
  char *argv[] = {(char *)executable, command, id, w, h, rate, factor, set, NULL};
  posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
  posix_spawn_file_actions_addclose(&actions, pipefd[0]); posix_spawn_file_actions_addclose(&actions, pipefd[1]);
  pid_t child; int error = posix_spawn(&child, executable, &actions, NULL, argv, environ);
  posix_spawn_file_actions_destroy(&actions); close(pipefd[1]);
  if (error) { close(pipefd[0]); return NO; }
  fcntl(pipefd[0], F_SETFL, fcntl(pipefd[0], F_GETFL) | O_NONBLOCK);
  char reply[128] = {0}; size_t used = 0;
  int status = 0; BOOL reaped = NO;
  while (monotonicSeconds() < deadline) {
    ssize_t got = read(pipefd[0], reply + used, sizeof(reply) - 1 - used);
    if (got > 0) { used += (size_t)got; reply[used] = '\0'; }
    if (used == sizeof(reply) - 1) break;
    pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) { reaped = YES; break; }
    if (result < 0 && errno != EINTR) break;
    struct pollfd pollfd = {pipefd[0], POLLIN, 0}; poll(&pollfd, 1, 20);
  }
  // Drain the final atomic record after observing exit, without another wait.
  ssize_t got = read(pipefd[0], reply + used, sizeof(reply) - 1 - used);
  if (got > 0) { used += (size_t)got; reply[used] = '\0'; }
  close(pipefd[0]);
  if (!reaped) {
    kill(child, SIGKILL);
    double reapDeadline = monotonicSeconds() + 1.0;
    while (monotonicSeconds() < reapDeadline) {
      pid_t result = waitpid(child, &status, WNOHANG);
      if (result == child || (result < 0 && errno == ECHILD)) break;
      usleep(10000);
    }
    return NO;
  }
  if (selectMode) {
    BOOL applied = WIFEXITED(status) && WEXITSTATUS(status) == 0 && !strcmp(reply, "MODE_APPLIED\n");
    fprintf(stderr, "Fresh VD mode mutation: display=%u exited=%d status=%d acknowledged=%d\n",
        display, WIFEXITED(status), WIFEXITED(status) ? WEXITSTATUS(status) : -1, applied);
    // Both execs share the original three-second budget. The reader starts only
    // after successful setter exit/reap, so neither its cache nor lifetime can
    // masquerade as a persistent mode change.
    return applied && freshModeBefore(executable, display, width, height, fps, scale, NO, geometry, deadline);
  }
  vd_reply_t decoded = vd_parse_reply(reply, geometry);
  fprintf(stderr, "Fresh VD mode reply: display=%u exited=%d status=%d decoded=%d bytes=%zu record=%s",
      display, WIFEXITED(status), WIFEXITED(status) ? WEXITSTATUS(status) : -1, decoded, used, reply);
  return WIFEXITED(status) && WEXITSTATUS(status) == 0 && decoded == VD_REPLY_READY &&
      geometry->display == display && (width == 0 || skylight_desktop_mode_matches(width, height, scale,
      geometry->logical_width, geometry->logical_height, true, geometry->pixel_width, geometry->pixel_height));
}

static BOOL freshMode(const char *executable, CGDirectDisplayID display, int width, int height,
                       int fps, int scale, BOOL selectMode, vd_geometry_t *geometry) {
  return freshModeBefore(executable, display, width, height, fps, scale, selectMode, geometry, monotonicSeconds() + 3.0);
}

// One owner keeps the existing activity alive through mode selection and flip.
// Remember the attempt separately from its ID: a failed declaration must not
// cause a second activity request on the ordinary flip path.
static void ensureConfigurationWake(BOOL alreadyMain, BOOL *attempted, IOPMAssertionID *assertion) {
  if (alreadyMain || *attempted) return;
  *attempted = YES;
  IOReturn error = IOPMAssertionDeclareUserActivity(CFSTR("Moonwalk Host VD primary flip"),
      kIOPMUserActiveLocal, assertion);
  fprintf(stderr, "[vd_helper] Pre-configuration wake: IOPMAssertionDeclareUserActivity = %d\n", error);
  usleep(500000);  // Same existing settle, never duplicated for a single preparation.
}

// The existing normal primary-flip wake belongs before BOTH mode and origin
// transactions. A fresh main bit preserves the already-main/headless skip.
// All preinspection, existing wake/settle, mutation and post-exit verification
// share the original three-second phase; no additional retry budget is added.
static BOOL prepareDesktopMode(const char *executable, CGDirectDisplayID display, int width, int height,
                              int fps, int scale, vd_geometry_t *geometry, IOPMAssertionID *wakeAssertion, BOOL *wakeAttempted) {
  const double deadline = monotonicSeconds() + 3.0;
  vd_geometry_t prior = {0};
  if (!freshModeBefore(executable, display, 0, 0, 0, 0, NO, &prior, deadline)) return NO;
  if (!prior.is_main) {
    if (monotonicSeconds() + 0.5 >= deadline) return NO;
    ensureConfigurationWake(NO, wakeAttempted, wakeAssertion);
  }
  return freshModeBefore(executable, display, width, height, fps, scale, YES, geometry, deadline);
}
