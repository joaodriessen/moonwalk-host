#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "desktop_scale.h"

typedef struct {
  uint32_t display, generation;
  int x, y, logical_width, logical_height, pixel_width, pixel_height;
  bool is_main;
} vd_geometry_t;

typedef enum { VD_REPLY_INVALID, VD_REPLY_NOT_READY, VD_REPLY_MODE_ERROR, VD_REPLY_READY } vd_reply_t;

static inline bool vd_geometry_valid(const vd_geometry_t *g) {
  return g && g->display && g->logical_width > 0 && g->logical_height > 0 &&
      g->pixel_width > 0 && g->pixel_height > 0 && g->pixel_width <= 8192 && g->pixel_height <= 8192 &&
      g->logical_width <= g->pixel_width && g->logical_height <= g->pixel_height;
}

static inline vd_reply_t vd_parse_reply(const char *line, vd_geometry_t *out) {
  if (!out) return VD_REPLY_INVALID;
  memset(out, 0, sizeof(*out));
  if (!line) return VD_REPLY_INVALID;
  if (!strcmp(line, "MODE_ERROR\n")) return VD_REPLY_MODE_ERROR;
  if (!strcmp(line, "0\n")) return VD_REPLY_NOT_READY;
  if (strncmp(line, "VDG1 ", 5)) return VD_REPLY_INVALID;
  long long values[8]; const char *p = line + 5;
  for (int i = 0; i < 8; ++i) {
    if (!(*p == '-' || (*p >= '0' && *p <= '9'))) return VD_REPLY_INVALID;
    char *end; errno = 0; values[i] = strtoll(p, &end, 10);
    if (errno || end == p || *end != (i == 7 ? '\n' : ' ')) return VD_REPLY_INVALID;
    p = end + 1;
  }
  if (*p || values[0] <= 0 || values[0] > UINT32_MAX || (values[7] != 0 && values[7] != 1)) return VD_REPLY_INVALID;
  for (int i = 1; i < 7; ++i) if (values[i] < INT32_MIN || values[i] > INT32_MAX) return VD_REPLY_INVALID;
  vd_geometry_t g = {(uint32_t)values[0], 0, (int)values[1], (int)values[2], (int)values[3],
                     (int)values[4], (int)values[5], (int)values[6], values[7] != 0};
  if (!vd_geometry_valid(&g)) return VD_REPLY_INVALID;
  *out = g; return VD_REPLY_READY;
}

static inline bool vd_mode_rate_matches(int requested, double actual) { return actual == 0 || (actual > requested - 0.5 && actual < requested + 0.5); }

static inline bool vd_reply_allows_global_cure(vd_reply_t reply) { return reply == VD_REPLY_NOT_READY; }
static inline bool vd_geometry_matches_request(const vd_geometry_t *g, int width, int height, int scale) {
  return vd_geometry_valid(g) && skylight_desktop_mode_matches(width, height, scale,
      g->logical_width, g->logical_height, true, g->pixel_width, g->pixel_height);
}
static inline bool vd_geometry_can_publish(const vd_geometry_t *g, int width, int height, int scale) {
  return vd_geometry_matches_request(g, width, height, scale) && g->is_main;
}
static inline bool vd_flip_allows_publish(bool already_main, bool verified_flip, bool post_main) {
  return post_main && (already_main || verified_flip);
}

static inline void vd_write_geometry(FILE *stream, const vd_geometry_t *g) {
  fprintf(stream, "VDG1 %u %d %d %d %d %d %d %d\n", g->display, g->x, g->y,
          g->logical_width, g->logical_height, g->pixel_width, g->pixel_height, g->is_main ? 1 : 0);
  fflush(stream);
}
