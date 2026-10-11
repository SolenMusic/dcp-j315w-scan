// SPDX-License-Identifier: MIT
// Independent SANE adapter. Only the public SANE ABI is used.
#define _POSIX_C_SOURCE 200809L
#include <sane/sane.h>
#include "../src/scanner.h"
#include <arpa/inet.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if ATOMIC_INT_LOCK_FREE != 2
#error "Cancellation requires an always lock-free atomic int"
#endif
#define API __attribute__((visibility("default")))
#ifndef DCP_SANE_CONFIG_DIR
#define DCP_SANE_CONFIG_DIR "/etc/sane.d"
#endif
#define MAX_DEVICES 16
#define MODE_SIZE 16
enum { OPT_COUNT, OPT_MODE, OPT_RESOLUTION, OPT_SOURCE, OPT_PREVIEW,
       OPT_GEOMETRY, OPT_TLX, OPT_TLY, OPT_BRX, OPT_BRY, NUM_OPTIONS };
static const SANE_String_Const modes[] = {"Color", "Gray", "Lineart", NULL};
static const SANE_String_Const sources[] = {"Flatbed", NULL};
static const SANE_Word resolutions[] = {2, 100, 300};
static SANE_Device devices[MAX_DEVICES];
static char addresses[MAX_DEVICES][INET_ADDRSTRLEN];
static const SANE_Device *device_list[MAX_DEVICES + 1];
static unsigned device_count;
static atomic_flag hardware_busy = ATOMIC_FLAG_INIT;

typedef struct handle {
  struct handle *next;
  char address[INET_ADDRSTRLEN], mode[MODE_SIZE];
  SANE_Word resolution, preview, rectangle[4];
  SANE_Range x_range, y_range;
  SANE_Option_Descriptor options[NUM_OPTIONS];
  SANE_Parameters params;
  atomic_int cancelled;
  int acquiring, frame;
  unsigned char *data;
  size_t size, offset;
} handle;
static handle *handles;

static unsigned dpi_for(const handle *h) { return h->preview ? 100u : (unsigned)h->resolution; }
static unsigned max_width(unsigned dpi) { return dpi == 100 ? 816 : 2480; }
static unsigned max_height(unsigned dpi) { return dpi == 100 ? 1145 : 3435; }
static SANE_Word mm_for(unsigned pixels, unsigned dpi) {
  return (SANE_Word)((uint64_t)pixels * 254 * 65536 / (dpi * 10));
}
static unsigned pixels_for(SANE_Word mm, unsigned dpi) {
  return (unsigned)(((uint64_t)mm * dpi * 10 + 254 * 32768) / (254 * 65536));
}
static int valid_address(const char *s) {
  struct in_addr addr;
  return s && strlen(s) < INET_ADDRSTRLEN && inet_pton(AF_INET, s, &addr) == 1;
}
static void add_config(FILE *f) {
  char line[256];
  while (fgets(line, sizeof(line), f)) {
    // Ignore overlong lines in their entirety.
    if (!strchr(line, '\n') && !feof(f)) {
      int c; while ((c = fgetc(f)) != '\n' && c != EOF) {}
      continue;
    }
    char address[16], extra[2];
    char *comment = strchr(line, '#'); if (comment) *comment = 0;
    if (sscanf(line, " %15s %1s", address, extra) != 1 || !valid_address(address)) continue;
    unsigned i;
    for (i = 0; i < device_count; ++i) if (!strcmp(addresses[i], address)) break;
    if (i != device_count || device_count == MAX_DEVICES) continue;
    strcpy(addresses[i], address);
    devices[i] = (SANE_Device){addresses[i], "Brother", "DCP-J315W (Open Scanner)", "flatbed scanner"};
    device_list[i] = &devices[i]; ++device_count;
  }
}
static void load_config(void) {
  device_count = 0; memset(device_list, 0, sizeof(device_list));
  const char *env = getenv("SANE_CONFIG_DIR");
  // SANE_CONFIG_DIR replaces defaults; a trailing colon appends the default.
  const char *paths = env && *env ? env : DCP_SANE_CONFIG_DIR;
  char *copy = strdup(paths); if (!copy) return;
  char *p = copy;
  for (;;) {
    char *next = strchr(p, ':'); if (next) *next = 0;
    char path[4096];
    const char *dir = *p ? p : DCP_SANE_CONFIG_DIR;
    int n = snprintf(path, sizeof(path), "%s/dcpj315w.conf", dir);
    if (n > 0 && (size_t)n < sizeof(path)) {
      FILE *f = fopen(path, "r");
      if (f) { add_config(f); fclose(f); break; }
    }
    if (!next) break;
    p = next + 1;
  }
  free(copy);
}
static void ranges(handle *h) {
  SANE_Word old_x = h->x_range.max, old_y = h->y_range.max;
  unsigned dpi = dpi_for(h);
  h->x_range = (SANE_Range){0, mm_for(max_width(dpi), dpi), 0};
  h->y_range = (SANE_Range){0, mm_for(max_height(dpi), dpi), 0};
  if (!old_x || h->rectangle[2] == old_x) h->rectangle[2] = h->x_range.max;
  if (!old_y || h->rectangle[3] == old_y) h->rectangle[3] = h->y_range.max;
  for (unsigned i = 0; i < 4; ++i) {
    SANE_Word max = i % 2 ? h->y_range.max : h->x_range.max;
    if (h->rectangle[i] > max) h->rectangle[i] = max;
  }
}
static void describe(handle *h) {
  const int rw = SANE_CAP_SOFT_SELECT | SANE_CAP_SOFT_DETECT;
  h->options[OPT_COUNT] = (SANE_Option_Descriptor){.name="", .title="Number of options",
    .desc="Number of scanner options", .type=SANE_TYPE_INT, .size=sizeof(SANE_Word), .cap=SANE_CAP_SOFT_DETECT};
  h->options[OPT_MODE] = (SANE_Option_Descriptor){.name="mode", .title="Scan mode",
    .desc="Color, grayscale, or thresholded one-bit text", .type=SANE_TYPE_STRING,
    .size=MODE_SIZE, .cap=rw, .constraint_type=SANE_CONSTRAINT_STRING_LIST, .constraint.string_list=modes};
  h->options[OPT_RESOLUTION] = (SANE_Option_Descriptor){.name="resolution", .title="Resolution",
    .desc="Scan resolution; preview uses 100 dpi", .type=SANE_TYPE_INT, .unit=SANE_UNIT_DPI,
    .size=sizeof(SANE_Word), .cap=rw, .constraint_type=SANE_CONSTRAINT_WORD_LIST, .constraint.word_list=resolutions};
  h->options[OPT_SOURCE] = (SANE_Option_Descriptor){.name="source", .title="Scan source",
    .desc="Flatbed only", .type=SANE_TYPE_STRING, .size=MODE_SIZE, .cap=rw,
    .constraint_type=SANE_CONSTRAINT_STRING_LIST, .constraint.string_list=sources};
  h->options[OPT_PREVIEW] = (SANE_Option_Descriptor){.name="preview", .title="Preview",
    .desc="Acquire an overview at 100 dpi", .type=SANE_TYPE_BOOL, .size=sizeof(SANE_Word), .cap=rw};
  h->options[OPT_GEOMETRY] = (SANE_Option_Descriptor){.name="", .title="Scan area", .type=SANE_TYPE_GROUP};
  const char *names[] = {"tl-x", "tl-y", "br-x", "br-y"};
  const char *titles[] = {"Top-left x", "Top-left y", "Bottom-right x", "Bottom-right y"};
  for (unsigned i = 0; i < 4; ++i)
    h->options[OPT_TLX+i] = (SANE_Option_Descriptor){.name=names[i], .title=titles[i],
      .desc="Scan rectangle in millimetres", .type=SANE_TYPE_FIXED, .unit=SANE_UNIT_MM,
      .size=sizeof(SANE_Word), .cap=rw, .constraint_type=SANE_CONSTRAINT_RANGE,
      .constraint.range=i % 2 ? &h->y_range : &h->x_range};
}
static int geometry(handle *h, dcp_scan_options *o, unsigned *crop_x, unsigned *width) {
  unsigned dpi = dpi_for(h);
  if (h->rectangle[0] >= h->rectangle[2] || h->rectangle[1] >= h->rectangle[3]) return 0;
  unsigned x = pixels_for(h->rectangle[0], dpi), y = pixels_for(h->rectangle[1], dpi);
  unsigned right = pixels_for(h->rectangle[2], dpi), bottom = pixels_for(h->rectangle[3], dpi);
  if (right > max_width(dpi)) right = max_width(dpi);
  if (bottom > max_height(dpi)) bottom = max_height(dpi);
  if (right <= x || bottom <= y) return 0;
  unsigned left = x / 16 * 16, wire_right = (right + 15) / 16 * 16;
  if (wire_right > max_width(dpi)) wire_right = max_width(dpi);
  *o = (dcp_scan_options){dpi, left, y, wire_right-left, bottom-y,
    !strcmp(h->mode, "Color") ? DCP_SCAN_COLOUR : DCP_SCAN_GRAY};
  *crop_x = x-left; *width = right-x;
  return 1;
}
static int is_cancelled(void *context) { return atomic_load(&((handle *)context)->cancelled); }

API SANE_Status sane_dcpj315w_init(SANE_Int *version, SANE_Auth_Callback auth) {
  (void)auth; if (version) *version = SANE_VERSION_CODE(1, 0, 1);
  load_config(); return SANE_STATUS_GOOD;
}
API void sane_dcpj315w_cancel(SANE_Handle value) {
  // No locks, allocations, or I/O: callable from a frontend's signal handler.
  if (value) atomic_store(&((handle *)value)->cancelled, 1);
}
API void sane_dcpj315w_close(SANE_Handle value) {
  if (!value) return;
  handle *h = value;
  sane_dcpj315w_cancel(h);
  handle **p = &handles; while (*p && *p != h) p = &(*p)->next;
  if (*p) *p = h->next;
  free(h->data); free(h);
}
API void sane_dcpj315w_exit(void) {
  while (handles) sane_dcpj315w_close(handles);
  device_count = 0; memset(device_list, 0, sizeof(device_list));
}
API SANE_Status sane_dcpj315w_get_devices(const SANE_Device ***list, SANE_Bool local_only) {
  static const SANE_Device *empty[] = {NULL};
  if (!list) return SANE_STATUS_INVAL;
  *list = local_only ? empty : device_list; return SANE_STATUS_GOOD;
}
API SANE_Status sane_dcpj315w_open(SANE_String_Const name, SANE_Handle *value) {
  if (!value || !name) return SANE_STATUS_INVAL;
  *value = NULL;
  if (!strncmp(name, "dcpj315w:", 9)) name += 9;
  if (!*name && device_count) name = addresses[0];
  if (!valid_address(name)) return SANE_STATUS_INVAL;
  handle *h = calloc(1, sizeof(*h)); if (!h) return SANE_STATUS_NO_MEM;
  strcpy(h->address, name); strcpy(h->mode, "Color"); h->resolution = 300;
  atomic_init(&h->cancelled, 0); ranges(h); describe(h);
  h->next = handles; handles = h; *value = h;
  return SANE_STATUS_GOOD;
}
API const SANE_Option_Descriptor *sane_dcpj315w_get_option_descriptor(SANE_Handle value, SANE_Int option) {
  if (!value || option < 0 || option >= NUM_OPTIONS) return NULL;
  return &((handle *)value)->options[option];
}
API SANE_Status sane_dcpj315w_control_option(SANE_Handle value, SANE_Int option,
    SANE_Action action, void *data, SANE_Int *info) {
  if (info) *info = 0;
  if (!value || !data || option < 0 || option >= NUM_OPTIONS || option == OPT_GEOMETRY)
    return SANE_STATUS_INVAL;
  handle *h = value;
  if (action == SANE_ACTION_GET_VALUE) {
    switch (option) {
      case OPT_COUNT: *(SANE_Word *)data = NUM_OPTIONS; break;
      case OPT_MODE: strcpy(data, h->mode); break;
      case OPT_RESOLUTION: *(SANE_Word *)data = h->resolution; break;
      case OPT_SOURCE: strcpy(data, "Flatbed"); break;
      case OPT_PREVIEW: *(SANE_Word *)data = h->preview; break;
      default: *(SANE_Word *)data = h->rectangle[option-OPT_TLX];
    }
    return SANE_STATUS_GOOD;
  }
  if (action != SANE_ACTION_SET_VALUE || option == OPT_COUNT) return SANE_STATUS_INVAL;
  if (h->acquiring || (h->frame && !atomic_load(&h->cancelled))) return SANE_STATUS_DEVICE_BUSY;
  if (option == OPT_MODE || option == OPT_SOURCE) {
    // A SET string may be shorter than the descriptor's advertised buffer.
    if (strnlen(data, MODE_SIZE) == MODE_SIZE) return SANE_STATUS_INVAL;
    if (option == OPT_SOURCE) return strcmp(data, "Flatbed") ? SANE_STATUS_INVAL : SANE_STATUS_GOOD;
    unsigned i; for (i = 0; modes[i]; ++i) if (!strcmp(data, modes[i])) break;
    if (!modes[i]) return SANE_STATUS_INVAL;
    strcpy(h->mode, data);
  } else {
    SANE_Word v = *(SANE_Word *)data;
    if (option == OPT_RESOLUTION) {
      if (v != 100 && v != 300) return SANE_STATUS_INVAL;
      if (h->resolution == v) return SANE_STATUS_GOOD;
      h->resolution = v; ranges(h);
      if (info) *info |= SANE_INFO_RELOAD_OPTIONS;
    } else if (option == OPT_PREVIEW) {
      if (v != SANE_FALSE && v != SANE_TRUE) return SANE_STATUS_INVAL;
      if (h->preview == v) return SANE_STATUS_GOOD;
      h->preview = v; ranges(h);
      if (info) *info |= SANE_INFO_RELOAD_OPTIONS;
    } else {
      const SANE_Range *r = h->options[option].constraint.range;
      if (v < r->min) v = r->min;
      if (v > r->max) v = r->max;
      if (info && v != *(SANE_Word *)data) *info |= SANE_INFO_INEXACT;
      *(SANE_Word *)data = v; h->rectangle[option-OPT_TLX] = v;
    }
  }
  if (info) *info |= SANE_INFO_RELOAD_PARAMS;
  return SANE_STATUS_GOOD;
}
API SANE_Status sane_dcpj315w_get_parameters(SANE_Handle value, SANE_Parameters *params) {
  if (!value || !params) return SANE_STATUS_INVAL;
  handle *h = value;
  if (h->frame && !atomic_load(&h->cancelled)) { *params = h->params; return SANE_STATUS_GOOD; }
  dcp_scan_options o; unsigned crop, width;
  if (!geometry(h, &o, &crop, &width)) return SANE_STATUS_INVAL;
  int text = !strcmp(h->mode, "Lineart"), colour = o.mode == DCP_SCAN_COLOUR;
  *params = (SANE_Parameters){colour ? SANE_FRAME_RGB : SANE_FRAME_GRAY, SANE_TRUE,
    (int)(text ? (width+7)/8 : width*(colour ? 3 : 1)), (int)width, -1, text ? 1 : 8};
  return SANE_STATUS_GOOD;
}
API SANE_Status sane_dcpj315w_start(SANE_Handle value) {
  if (!value) return SANE_STATUS_INVAL;
  handle *h = value;
  if (h->acquiring || (h->frame && !atomic_load(&h->cancelled))) return SANE_STATUS_DEVICE_BUSY;
  dcp_scan_options o; unsigned crop, width;
  if (!geometry(h, &o, &crop, &width)) return SANE_STATUS_INVAL;
  if (atomic_flag_test_and_set(&hardware_busy)) return SANE_STATUS_DEVICE_BUSY;
  free(h->data); h->data = NULL; h->size = h->offset = 0; h->frame = 0;
  atomic_store(&h->cancelled, 0); h->acquiring = 1;
  dcp_scan_image image = {0}; char error[256];
  dcp_scan_callbacks callbacks = {h, is_cancelled, NULL};
  int ok = dcp_scan_acquire(h->address, &o, &image, &callbacks, error, sizeof(error));
  h->acquiring = 0; atomic_flag_clear(&hardware_busy);
  if (!ok || atomic_load(&h->cancelled)) {
    dcp_scan_free(&image);
    if (atomic_load(&h->cancelled)) return SANE_STATUS_CANCELLED;
    if (getenv("DCP_SCAN_DEBUG")) fprintf(stderr, "dcpj315w: %s\n", error);
    return SANE_STATUS_IO_ERROR;
  }
  if (crop + width > image.width) { dcp_scan_free(&image); return SANE_STATUS_IO_ERROR; }
  int text = !strcmp(h->mode, "Lineart");
  size_t stride = text ? (width+7)/8 : (size_t)width*image.channels;
  // Compact in place. Every destination row ends before the next source row.
  for (unsigned y = 0; y < image.height; ++y) {
    unsigned char *source = image.pixels + y*image.stride + crop*image.channels;
    unsigned char *dest = image.pixels + y*stride;
    if (text) {
      // SANE one-bit samples: 0 is white, 1 is black, most significant bit first.
      for (unsigned x = 0; x < width; x += 8) {
        unsigned char byte = 0;
        for (unsigned bit = 0; bit < 8 && x+bit < width; ++bit)
          if (source[x+bit] < 128) byte |= (unsigned char)(0x80 >> bit);
        dest[x/8] = byte;
      }
    } else memmove(dest, source, stride);
  }
  h->params = (SANE_Parameters){image.channels == 3 ? SANE_FRAME_RGB : SANE_FRAME_GRAY,
    SANE_TRUE, (int)stride, (int)width, (int)image.height, text ? 1 : 8};
  h->data = image.pixels; h->size = stride*image.height; h->frame = 1;
  return SANE_STATUS_GOOD;
}
API SANE_Status sane_dcpj315w_read(SANE_Handle value, SANE_Byte *data, SANE_Int max_length, SANE_Int *length) {
  if (length) *length = 0;
  if (!value || !data || !length || max_length <= 0) return SANE_STATUS_INVAL;
  handle *h = value;
  if (atomic_load(&h->cancelled)) return SANE_STATUS_CANCELLED;
  if (!h->frame || h->acquiring) return SANE_STATUS_INVAL;
  if (h->offset == h->size) { h->frame = 0; return SANE_STATUS_EOF; }
  size_t n = h->size-h->offset; if (n > (size_t)max_length) n = (size_t)max_length;
  memcpy(data, h->data+h->offset, n); h->offset += n; *length = (SANE_Int)n;
  return SANE_STATUS_GOOD;
}
API SANE_Status sane_dcpj315w_set_io_mode(SANE_Handle value, SANE_Bool non_blocking) {
  if (!value || !((handle *)value)->frame || atomic_load(&((handle *)value)->cancelled)) return SANE_STATUS_INVAL;
  return non_blocking ? SANE_STATUS_UNSUPPORTED : SANE_STATUS_GOOD;
}
API SANE_Status sane_dcpj315w_get_select_fd(SANE_Handle value, SANE_Int *fd) {
  (void)value; (void)fd; return SANE_STATUS_UNSUPPORTED;
}
