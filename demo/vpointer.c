// vpointer: a scripted pointer for the demo session.
//
// Reads commands from stdin and plays them through the wlr virtual-pointer
// protocol on $WAYLAND_DISPLAY, so it only ever moves the pointer of the
// compositor it connects to (the nested demo), never the real one.
//
//   size W H                 output size the coordinates are in (required first)
//   move X Y                 jump there
//   glide X Y MS             ease from the current position to X Y over MS
//   click [left|right]       press and release
//   scroll DY                vertical scroll, in wheel steps
//   sleep MS
//
// Build: demo/build-vpointer (wayland-scanner + gcc, no other deps).

#define _POSIX_C_SOURCE 200809L
#include <linux/input-event-codes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>

#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwlr_virtual_pointer_manager_v1 *manager;
static struct zwlr_virtual_pointer_v1 *pointer;
static struct wl_display *display;
static double cur_x, cur_y;
static unsigned width = 1920, height = 1080;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
  (void)data;
  if (strcmp(interface, wl_seat_interface.name) == 0 && !seat)
    seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
  else if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0)
    manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, version < 2 ? version : 2);
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
  (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = { global, global_remove };

static uint32_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void sleep_ms(long ms) {
  struct timespec ts = { ms / 1000, (ms % 1000) * 1000000 };
  nanosleep(&ts, NULL);
}

static void move_to(double x, double y) {
  cur_x = x;
  cur_y = y;
  zwlr_virtual_pointer_v1_motion_absolute(pointer, now_ms(), (uint32_t)lround(x), (uint32_t)lround(y), width, height);
  zwlr_virtual_pointer_v1_frame(pointer);
  wl_display_flush(display);
}

// Ease-in-out, ~60 steps a second: reads as a hand on a mouse, not a teleport.
static void glide(double x, double y, long ms) {
  double x0 = cur_x, y0 = cur_y;
  long steps = ms / 16;
  if (steps < 1) steps = 1;
  for (long i = 1; i <= steps; i++) {
    double t = (double)i / steps;
    double e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2;
    move_to(x0 + (x - x0) * e, y0 + (y - y0) * e);
    sleep_ms(16);
  }
}

static void click(uint32_t button) {
  zwlr_virtual_pointer_v1_button(pointer, now_ms(), button, WL_POINTER_BUTTON_STATE_PRESSED);
  zwlr_virtual_pointer_v1_frame(pointer);
  wl_display_flush(display);
  sleep_ms(70);
  zwlr_virtual_pointer_v1_button(pointer, now_ms(), button, WL_POINTER_BUTTON_STATE_RELEASED);
  zwlr_virtual_pointer_v1_frame(pointer);
  wl_display_flush(display);
}

static void scroll(double steps) {
  zwlr_virtual_pointer_v1_axis_source(pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
  zwlr_virtual_pointer_v1_axis_discrete(pointer, now_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL,
                                        wl_fixed_from_double(steps * 15), (int32_t)steps);
  zwlr_virtual_pointer_v1_frame(pointer);
  wl_display_flush(display);
}

int main(void) {
  display = wl_display_connect(NULL);
  if (!display) { fprintf(stderr, "vpointer: no Wayland display\n"); return 1; }
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!manager) { fprintf(stderr, "vpointer: compositor has no virtual pointer support\n"); return 1; }
  pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);

  char line[256], cmd[32], arg[32];
  double a, b, c;
  while (fgets(line, sizeof line, stdin)) {
    if (line[0] == '#' || sscanf(line, "%31s", cmd) != 1) continue;
    if (strcmp(cmd, "size") == 0 && sscanf(line, "%*s %lf %lf", &a, &b) == 2) { width = (unsigned)a; height = (unsigned)b; }
    else if (strcmp(cmd, "move") == 0 && sscanf(line, "%*s %lf %lf", &a, &b) == 2) move_to(a, b);
    else if (strcmp(cmd, "glide") == 0 && sscanf(line, "%*s %lf %lf %lf", &a, &b, &c) == 3) glide(a, b, (long)c);
    else if (strcmp(cmd, "click") == 0) {
      arg[0] = 0;
      sscanf(line, "%*s %31s", arg);
      click(strcmp(arg, "right") == 0 ? BTN_RIGHT : BTN_LEFT);
    }
    else if (strcmp(cmd, "scroll") == 0 && sscanf(line, "%*s %lf", &a) == 1) scroll(a);
    else if (strcmp(cmd, "sleep") == 0 && sscanf(line, "%*s %lf", &a) == 1) sleep_ms((long)a);
    else fprintf(stderr, "vpointer: ignored: %s", line);
  }
  wl_display_roundtrip(display);
  zwlr_virtual_pointer_v1_destroy(pointer);
  wl_display_disconnect(display);
  return 0;
}
