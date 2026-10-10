// SPDX-License-Identifier: MIT
#ifndef DCP_SCANNER_H
#define DCP_SCANNER_H
#include <stddef.h>

// Each call owns its connection. No global state, files, UI or CUPS dependency.
// Callbacks execute synchronously on the calling thread; UI callers should use
// a worker thread. A cancellation callback must be safe for that thread to read.
typedef enum { DCP_SCAN_GRAY = 0, DCP_SCAN_COLOUR = 1 } dcp_scan_mode;
typedef struct {
  unsigned dpi;                    // 100, 150 or 300
  unsigned x, y, width, height;     // pixels; zero width/height means remaining bed
  dcp_scan_mode mode;               // zero-initialisation preserves grayscale
} dcp_scan_options;
typedef struct {
  unsigned x_dpi, y_dpi, source, width_mm, width_pixels, height_mm, height_pixels;
} dcp_scan_capabilities;
typedef struct {
  void *context;
  int (*cancelled)(void *context);
  void (*progress)(void *context, unsigned rows, unsigned maximum_rows);
} dcp_scan_callbacks;
typedef struct {
  unsigned char *pixels;
  // One grayscale channel, or three interleaved RGB channels, eight bits each.
  unsigned width, height, dpi, channels;
  size_t stride;
} dcp_scan_image;
// Return 1 on success, 0 on error with a caller-owned explanation. Failed
// acquisition leaves image empty; only the device's page-end completes a scan.
// Pass an empty image, or call dcp_scan_free before reusing an acquired image.
int dcp_scan_query(const char *ipv4, const dcp_scan_options *options,
                   dcp_scan_capabilities *caps, const dcp_scan_callbacks *callbacks,
                   char *error, size_t error_size);
int dcp_scan_acquire(const char *ipv4, const dcp_scan_options *options,
                     dcp_scan_image *image, const dcp_scan_callbacks *callbacks,
                     char *error, size_t error_size);
void dcp_scan_free(dcp_scan_image *image);
#endif
