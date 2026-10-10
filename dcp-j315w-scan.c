// SPDX-License-Identifier: MIT
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#endif
#include "src/scanner.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#endif

static volatile sig_atomic_t interrupted;
static void stop(int n) { (void)n; interrupted = 1; }
static int cancelled(void *context) { (void)context; return interrupted != 0; }
static void progress(void *context, unsigned rows, unsigned maximum) {
  (void)context;
  if (rows == 1 || rows % 500 == 0) fprintf(stderr, "Received %u / at most %u rows.\n", rows, maximum);
}
static int number(const char *text, unsigned *value) {
  if (!text || *text < '0' || *text > '9') return 0;
  char *end; errno = 0;
  unsigned long v = strtoul(text, &end, 10);
  if (errno || *end || v > UINT_MAX) return 0;
  *value = (unsigned)v; return 1;
}
#ifdef __APPLE__
static int write_png(const char *path, const dcp_scan_image *image) {
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
  CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
  CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, image->pixels, image->stride * image->height, NULL);
  CGImageRef bitmap = provider && space ? CGImageCreate(image->width, image->height, 8, 8,
    image->stride, space, kCGImageAlphaNone, provider, NULL, false, kCGRenderingIntentDefault) : NULL;
  CGImageDestinationRef output = url ? CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL) : NULL;
  double dpi = image->dpi;
  CFNumberRef resolution = CFNumberCreate(NULL, kCFNumberDoubleType, &dpi);
  const void *keys[] = {kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight};
  const void *values[] = {resolution, resolution};
  CFDictionaryRef properties = resolution ? CFDictionaryCreate(NULL, keys, values, 2,
    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) : NULL;
  int ok = bitmap && output && properties;
  if (ok) { CGImageDestinationAddImage(output, bitmap, properties); ok = CGImageDestinationFinalize(output); }
  if (properties) CFRelease(properties);
  if (resolution) CFRelease(resolution);
  if (output) CFRelease(output);
  if (bitmap) CGImageRelease(bitmap);
  if (provider) CGDataProviderRelease(provider);
  if (space) CGColorSpaceRelease(space);
  if (url) CFRelease(url);
  if (!ok) errno = EIO;
  return ok;
}
#endif
static int save_image(const char *path, const dcp_scan_image *image, int png) {
  // Build in the destination directory, then atomically publish without replace.
  size_t size = strlen(path) + 20;
  char *temp = malloc(size);
  if (!temp) return 0;
  snprintf(temp, size, "%s.partial.XXXXXX", path);
  // ImageIO can replace its target file and reset its mode. A private staging
  // directory protects the data throughout encoding, including that replacement.
  if (!mkdtemp(temp)) { free(temp); return 0; }
  char *staged = malloc(size + 8);
  if (!staged) { rmdir(temp); free(temp); return 0; }
  snprintf(staged, size + 8, "%s/image", temp);
  int fd = open(staged, O_WRONLY | O_CREAT | O_EXCL, 0600), ok = 0;
  if (fd < 0) { rmdir(temp); free(staged); free(temp); return 0; }
  if (png) {
    close(fd);
#ifdef __APPLE__
    ok = write_png(staged, image);
#else
    errno = ENOTSUP;
#endif
  } else {
    FILE *out = fdopen(fd, "wb");
    if (out) {
      ok = fprintf(out, "P5\n# DCP-J315W network scan, %u dpi\n%u %u\n255\n",
                   image->dpi, image->width, image->height) > 0;
      if (ok) ok = fwrite(image->pixels, image->stride, image->height, out) == image->height;
      if (fclose(out)) ok = 0;
    } else close(fd);
  }
  if (ok) ok = chmod(staged, 0600) == 0;
  if (ok) ok = link(staged, path) == 0;
  int saved = errno;
  unlink(staged); rmdir(temp); free(staged); free(temp); errno = saved;
  return ok;
}
static void usage(const char *program) {
  fprintf(stderr, "Usage: %s --info PRINTER_IPV4 [--dpi 100|150|300]\n"
    "       %s --scan PRINTER_IPV4 OUTPUT.pgm|OUTPUT.png [--dpi 100|150|300]\n"
    "          [--area X,Y,WIDTH,HEIGHT]\n"
    "Area values are pixels; X and WIDTH must be multiples of 16. PNG requires macOS.\n",
    program, program);
}
int main(int argc, char **argv) {
  if (argc < 3 || (strcmp(argv[1], "--info") && strcmp(argv[1], "--scan"))) {
    usage(argv[0]); return 2;
  }
  int scanning = !strcmp(argv[1], "--scan"), png = 0;
  if (scanning && argc < 4) { usage(argv[0]); return 2; }
  dcp_scan_options options = {.dpi = 100};
  for (int i = scanning ? 4 : 3; i < argc; i += 2) {
    if (i + 1 >= argc) { usage(argv[0]); return 2; }
    if (!strcmp(argv[i], "--dpi")) {
      if (!number(argv[i+1], &options.dpi)) { usage(argv[0]); return 2; }
    } else if (!strcmp(argv[i], "--area") && scanning) {
      char *area = strdup(argv[i+1]), *p = area;
      unsigned *fields[] = {&options.x, &options.y, &options.width, &options.height};
      int valid = area != NULL;
      for (unsigned n = 0; valid && n < 4; ++n) {
        char *comma = strchr(p, ',');
        if (n < 3 ? comma == NULL : comma != NULL) { valid = 0; break; }
        if (comma) *comma = '\0';
        valid = number(p, fields[n]);
        if (comma) p = comma + 1;
      }
      free(area);
      if (!valid) { usage(argv[0]); return 2; }
    } else { usage(argv[0]); return 2; }
  }
  if ((options.dpi != 100 && options.dpi != 150 && options.dpi != 300) ||
      options.x % 16 || options.width % 16) { usage(argv[0]); return 2; }
  if (scanning) {
    const char *extension = strrchr(argv[3], '.');
    if (!extension || (strcmp(extension, ".pgm") && strcmp(extension, ".png"))) {
      usage(argv[0]); return 2;
    }
    png = !strcmp(extension, ".png");
#ifndef __APPLE__
    if (png) { fprintf(stderr, "PNG export currently requires macOS.\n"); return 2; }
#endif
    struct stat st;
    if (!lstat(argv[3], &st)) { fprintf(stderr, "Output already exists; no scan started.\n"); return 1; }
    if (errno != ENOENT) { perror("Cannot check output"); return 1; }
  }
  struct sigaction action = {0}; action.sa_handler = stop;
  sigemptyset(&action.sa_mask);
  sigaction(SIGINT, &action, NULL); sigaction(SIGTERM, &action, NULL);
  dcp_scan_callbacks callbacks = {.cancelled = cancelled, .progress = progress};
  char error[256]; int ok;
  if (scanning) {
    dcp_scan_image image = {0};
    fprintf(stderr, "Scanning grayscale at %u dpi.\n", options.dpi);
    ok = dcp_scan_acquire(argv[2], &options, &image, &callbacks, error, sizeof(error));
    if (!ok) fprintf(stderr, "%s; no image saved.\n", error);
    if (ok) {
      ok = save_image(argv[3], &image, png);
      if (!ok) perror("Cannot save scan");
      else printf("Saved %s: %u x %u pixels at %u dpi; device page-end confirmed.\n",
                  argv[3], image.width, image.height, image.dpi);
    }
    dcp_scan_free(&image);
  } else {
    dcp_scan_capabilities caps;
    ok = dcp_scan_query(argv[2], &options, &caps, &callbacks, error, sizeof(error));
    if (!ok) fprintf(stderr, "%s\n", error);
    else printf("Flatbed grayscale: %u dpi, reported maximum %u x %u pixels (%u x %u mm)\n",
                caps.x_dpi, caps.width_pixels, caps.height_pixels, caps.width_mm, caps.height_mm);
  }
  return ok ? 0 : 1;
}
