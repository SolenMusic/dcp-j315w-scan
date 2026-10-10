// Independent scanner transport, using observed DCP-J315W wire data.
#define _POSIX_C_SOURCE 200809L
#include "scanner.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef struct {
  const dcp_scan_callbacks *callbacks;
} session;
static int cancelled(session *s) {
  return s->callbacks && s->callbacks->cancelled &&
    s->callbacks->cancelled(s->callbacks->context);
}
static int64_t now_ms(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0;
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int ready(session *s, int fd, short events, int64_t deadline) {
  while (!cancelled(s)) {
    int64_t left = deadline - now_ms();
    if (left <= 0) { errno = ETIMEDOUT; return 0; }
    struct pollfd p = {fd, events, 0};
    int result = poll(&p, 1, left > 250 ? 250 : (int)left);
    if (result < 0 && errno == EINTR) continue;
    if (result < 0) return 0;
    if (result) {
      if (p.revents & (events | POLLHUP)) return 1;
      errno = EIO; return 0;
    }
  }
  errno = EINTR; return 0;
}
static int receive_exact(session *s, int fd, void *buffer, size_t count, int64_t deadline) {
  unsigned char *p = buffer;
  while (count) {
    if (!ready(s, fd, POLLIN, deadline)) return 0;
    ssize_t n = recv(fd, p, count, 0);
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
    if (n <= 0) { if (!n) errno = ECONNRESET; return 0; }
    p += n; count -= (size_t)n;
  }
  return 1;
}
static int transmit(session *s, int fd, const void *buffer, size_t count, int64_t deadline) {
  const unsigned char *p = buffer;
  while (count) {
    if (!ready(s, fd, POLLOUT, deadline)) return 0;
    ssize_t n = send(fd, p, count,
#ifdef MSG_NOSIGNAL
                     MSG_NOSIGNAL
#else
                     0
#endif
    );
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
    if (n <= 0) return 0;
    p += n; count -= (size_t)n;
  }
  return 1;
}
static int open_scanner(session *s, const char *host) {
  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET; addr.sin_port = htons(54921);
  if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
    errno = EINVAL; return -1;
  }
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
#ifdef SO_NOSIGPIPE
  int suppress = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppress, sizeof(suppress))) {
    close(fd); return -1;
  }
#endif
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { close(fd); return -1; }
  int64_t deadline = now_ms() + 5000;
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    if (errno != EINPROGRESS || !ready(s, fd, POLLOUT, deadline)) { close(fd); return -1; }
    int error = 0; socklen_t size = sizeof(error);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) || error) {
      if (error) errno = error;
      close(fd); return -1;
    }
  }
  unsigned char greeting[9];
  if (!receive_exact(s, fd, greeting, sizeof(greeting), deadline)) {
    int saved = errno; close(fd); errno = saved; return -1;
  }
  if (memcmp(greeting, "+OK 200\r\n", sizeof(greeting))) {
    errno = EPROTO;
    close(fd); return -1;
  }
  return fd;
}

static int valid_options(const dcp_scan_options *o) {
  if (!o || (o->dpi != 100 && o->dpi != 150 && o->dpi != 300) ||
      (o->mode != DCP_SCAN_GRAY && o->mode != DCP_SCAN_COLOUR) ||
      o->x % 16 || (o->width && o->width % 16)) {
    errno = EINVAL; return 0;
  }
  return 1;
}
static int fail(char *error, size_t size, const char *operation) {
  if (error && size) snprintf(error, size, "%s: %s", operation, strerror(errno));
  return 0;
}
static const char *wire_mode(const dcp_scan_options *o) {
  return o->mode == DCP_SCAN_COLOUR ? "CGRAY" : "GRAY256";
}
static int query(session *s, int fd, const dcp_scan_options *o, dcp_scan_capabilities *caps) {
  unsigned dpi = o->dpi;
  char request[80];
  int length = snprintf(request, sizeof(request), "\x1bI\nR=%u,%u\nM=%s\n\x80", dpi, dpi, wire_mode(o));
  int64_t deadline = now_ms() + 5000;
  unsigned char header[3]; char text[256];
  if (!transmit(s, fd, request, (size_t)length, deadline) ||
      !receive_exact(s, fd, header, sizeof(header), deadline)) return 0;
  unsigned size = header[1] | (unsigned)header[2] << 8;
  if (header[0] || !size || size >= sizeof(text)) { errno = EPROTO; return 0; }
  if (!receive_exact(s, fd, text, size, deadline)) return 0;
  text[size] = '\0';
  unsigned values[7]; char *p = text;
  for (unsigned i = 0; i < 7; ++i) {
    if (*p < '0' || *p > '9') { errno = EPROTO; return 0; }
    char *end; errno = 0;
    unsigned long v = strtoul(p, &end, 10);
    if (errno || v > UINT_MAX || (i < 6 ? *end != ',' : end != text + size)) {
      errno = EPROTO; return 0;
    }
    values[i] = (unsigned)v; p = end + (i < 6);
  }
  if (values[0] != dpi || values[1] != dpi || values[2] != 2 ||
      !values[3] || values[3] > 220 || values[4] < 16 || values[4] > 4096 ||
      !values[5] || values[5] > 310 || !values[6] || values[6] > 4096) {
    errno = EPROTO; return 0;
  }
  *caps = (dcp_scan_capabilities){values[0], values[1], values[2], values[3],
                                values[4], values[5], values[6]};
  return 1;
}
int dcp_scan_query(const char *host, const dcp_scan_options *o,
                   dcp_scan_capabilities *caps, const dcp_scan_callbacks *callbacks,
                   char *error, size_t error_size) {
  if (!caps || !host) { errno = EINVAL; return fail(error, error_size, "Invalid query"); }
  memset(caps, 0, sizeof(*caps));
  if (!valid_options(o)) return fail(error, error_size, "Invalid scan options");
  session s = {callbacks};
  int fd = open_scanner(&s, host);
  if (fd < 0) return fail(error, error_size, "Cannot open scanner");
  int ok = query(&s, fd, o, caps);
  int saved = errno; close(fd); errno = saved;
  return ok ? 1 : fail(error, error_size, "Cannot query scanner");
}
void dcp_scan_free(dcp_scan_image *image) {
  if (image) { free(image->pixels); memset(image, 0, sizeof(*image)); }
}
static unsigned char sample(int scaled) {
  if (scaled <= 0) return 0;
  if (scaled >= 255000000) return 255;
  return (unsigned char)((scaled + 500000) / 1000000);
}
static void colour_row(unsigned char *rgb, const unsigned char *planes, unsigned width) {
  // Full-range YCbCr inverse (ITU-T T.871 section 7). Wire planes are Cr,Y,Cb.
  // Fixed decimal coefficients make rounding identical across CPU targets.
  // This is a standard matrix, not a vendor decoder or calibration table.
  for (unsigned x = 0; x < width; ++x) {
    int cr = (int)planes[x] - 128;
    int y = (int)planes[width + x] * 1000000;
    int cb = (int)planes[width * 2 + x] - 128;
    rgb[x * 3] = sample(y + 1402000 * cr);
    rgb[x * 3 + 1] = sample(y - 344136 * cb - 714136 * cr);
    rgb[x * 3 + 2] = sample(y + 1772000 * cb);
  }
}
int dcp_scan_acquire(const char *host, const dcp_scan_options *o,
                     dcp_scan_image *image, const dcp_scan_callbacks *callbacks,
                     char *error, size_t error_size) {
  if (!image || !host) { errno = EINVAL; return fail(error, error_size, "Invalid acquisition"); }
  memset(image, 0, sizeof(*image));
  if (!valid_options(o)) return fail(error, error_size, "Invalid scan options");
  session s = {callbacks};
  int fd = open_scanner(&s, host);
  if (fd < 0) return fail(error, error_size, "Cannot open scanner");
  dcp_scan_capabilities caps;
  unsigned char *pixels = NULL;
  unsigned char *planes = NULL;
  unsigned channels = o->mode == DCP_SCAN_COLOUR ? 3 : 1;
  unsigned rows = 0, width = 0, height = 0;
  int completed = 0, sent = 0;
  const char *operation = "Cannot query scanner";
  if (!query(&s, fd, o, &caps)) goto end;
  operation = "Invalid scan area";
  if (o->x >= caps.width_pixels || o->y >= caps.height_pixels) { errno = EINVAL; goto end; }
  width = o->width ? o->width : (caps.width_pixels - o->x) / 16 * 16;
  height = o->height ? o->height : caps.height_pixels - o->y;
  if (!width || !height || width > caps.width_pixels - o->x || height > caps.height_pixels - o->y) {
    errno = EINVAL; goto end;
  }
  operation = "Cannot allocate image";
  pixels = malloc((size_t)width * height * channels);
  if (!pixels) goto end;
  if (channels == 3) {
    planes = malloc((size_t)width * 3);
    if (!planes) goto end;
  }
  char request[256];
  int length = snprintf(request, sizeof(request),
    "\x1bX\nR=%u,%u\nM=%s\nC=NONE\nB=50\nN=50\nU=OFF\nP=OFF\nA=%u,%u,%u,%u\n\x80",
    o->dpi, o->dpi, wire_mode(o), o->x, o->y, o->x + width, o->y + height);
  int64_t deadline = now_ms() + 180000;
  operation = "Cannot send scan request";
  if (length < 0 || length >= (int)sizeof(request)) { errno = EOVERFLOW; goto end; }
  // Even a partially transmitted request may have activated the scanner.
  sent = 1;
  if (!transmit(&s, fd, request, (size_t)length, deadline)) goto end;
  operation = "Scan incomplete";
  while (!cancelled(&s)) {
    unsigned char tag, size[2];
    if (!receive_exact(&s, fd, &tag, 1, deadline)) break;
    if (tag == 0x80) {
      if (rows) completed = 1; else errno = EPROTO;
      break;
    }
    if (rows >= height) { errno = EPROTO; break; }
    int row_ok = 1;
    for (unsigned plane = 0; plane < channels; ++plane) {
      unsigned expected = channels == 1 ? 0x40 : 0x44 + plane * 4;
      if (plane && !receive_exact(&s, fd, &tag, 1, deadline)) { row_ok = 0; break; }
      if (tag != expected) { errno = EPROTO; row_ok = 0; break; }
      if (!receive_exact(&s, fd, size, sizeof(size), deadline)) { row_ok = 0; break; }
      unsigned count = size[0] | (unsigned)size[1] << 8;
      if (count != width) { errno = EPROTO; row_ok = 0; break; }
      unsigned char *target = channels == 1 ? pixels + (size_t)rows * width : planes + plane * width;
      if (!receive_exact(&s, fd, target, width, deadline)) { row_ok = 0; break; }
    }
    if (!row_ok) break;
    if (channels == 3) colour_row(pixels + (size_t)rows * width * 3, planes, width);
    ++rows;
    if (callbacks && callbacks->progress) callbacks->progress(callbacks->context, rows, height);
  }
  if (cancelled(&s)) { completed = 0; errno = EINTR; }
end:;
  int saved = errno;
  if (!completed && sent) {
    // A fresh short deadline permits cancellation after the callback fired.
    session cleanup = {NULL};
    (void)transmit(&cleanup, fd, "\x1bR", 2, now_ms() + 500);
    // Closing a TCP socket with unread scan data can generate a reset. Give
    // the printer a bounded opportunity to consume cancellation and finish
    // its connection instead. Discarded bytes never become a partial image.
    (void)shutdown(fd, SHUT_WR);
    unsigned char discard[8192];
    int64_t drain_deadline = now_ms() + 1500;
    while (ready(&cleanup, fd, POLLIN, drain_deadline)) {
      ssize_t n = recv(fd, discard, sizeof(discard), 0);
      if (n <= 0) {
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        break;
      }
    }
  }
  close(fd); errno = saved;
  free(planes);
  if (!completed) { free(pixels); return fail(error, error_size, operation); }
  *image = (dcp_scan_image){pixels, width, rows, o->dpi, channels, (size_t)width * channels};
  return 1;
}
