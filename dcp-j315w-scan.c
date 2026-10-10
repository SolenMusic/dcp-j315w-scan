// Independent DCP-J315W network-scanner prototype, based on observed wire data.
// No CUPS, SANE, Brother binary or third-party decoder is linked.
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted;
static void stop(int signal_number) { (void)signal_number; interrupted = 1; }
static int64_t now_ms(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0;
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int ready(int fd, short events, int64_t deadline) {
  while (!interrupted) {
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
static int receive_exact(int fd, void *buffer, size_t count, int64_t deadline) {
  unsigned char *p = buffer;
  while (count) {
    if (!ready(fd, POLLIN, deadline)) return 0;
    ssize_t n = recv(fd, p, count, 0);
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
    if (n <= 0) { if (!n) errno = ECONNRESET; return 0; }
    p += n; count -= (size_t)n;
  }
  return 1;
}
static int transmit(int fd, const void *buffer, size_t count, int64_t deadline) {
  const unsigned char *p = buffer;
  while (count) {
    if (!ready(fd, POLLOUT, deadline)) return 0;
    ssize_t n = send(fd, p, count, 0);
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
    if (n <= 0) return 0;
    p += n; count -= (size_t)n;
  }
  return 1;
}
static int open_scanner(const char *host) {
  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET; addr.sin_port = htons(54921);
  if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
    fprintf(stderr, "Use a numeric IPv4 printer address.\n"); return -1;
  }
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { close(fd); return -1; }
  int64_t deadline = now_ms() + 5000;
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    if (errno != EINPROGRESS || !ready(fd, POLLOUT, deadline)) { close(fd); return -1; }
    int error = 0; socklen_t size = sizeof(error);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) || error) {
      if (error) errno = error;
      close(fd); return -1;
    }
  }
  unsigned char greeting[9];
  if (!receive_exact(fd, greeting, sizeof(greeting), deadline) ||
      memcmp(greeting, "+OK 200\r\n", sizeof(greeting))) {
    fprintf(stderr, "Scanner did not accept the network session.\n");
    close(fd); return -1;
  }
  return fd;
}
typedef struct {
  unsigned x_dpi, y_dpi, source, width_mm, width_pixels, height_mm, height_pixels;
} capabilities;
static int query(int fd, capabilities *caps) {
  static const unsigned char request[] = "\x1bI\nR=100,100\nM=GRAY256\n\x80";
  int64_t deadline = now_ms() + 5000;
  unsigned char header[3]; char text[256];
  if (!transmit(fd, request, sizeof(request) - 1, deadline) ||
      !receive_exact(fd, header, sizeof(header), deadline)) return 0;
  unsigned size = header[1] | (unsigned)header[2] << 8;
  if (header[0] || !size || size >= sizeof(text)) {
    fprintf(stderr, "Unsupported scanner information response.\n"); return 0;
  }
  if (!receive_exact(fd, text, size, deadline)) return 0;
  text[size] = '\0'; int consumed = 0;
  if (sscanf(text, "%u,%u,%u,%u,%u,%u,%u%n", &caps->x_dpi, &caps->y_dpi,
             &caps->source, &caps->width_mm, &caps->width_pixels,
             &caps->height_mm, &caps->height_pixels, &consumed) != 7 ||
      consumed != (int)size || caps->x_dpi != 100 || caps->y_dpi != 100 ||
      caps->source != 2 || caps->width_pixels < 16 || caps->width_pixels > 2048 ||
      !caps->height_pixels || caps->height_pixels > 4096) {
    fprintf(stderr, "Unsupported scan capabilities: %s\n", text); return 0;
  }
  printf("Flatbed grayscale: %u x %u dpi, reported maximum %u x %u pixels (%u x %u mm)\n",
         caps->x_dpi, caps->y_dpi, caps->width_pixels, caps->height_pixels,
         caps->width_mm, caps->height_mm);
  return 1;
}
static int save_image(const char *path, const unsigned char *pixels, unsigned width, unsigned height) {
  // A new file is required so a failed scan never overwrites an earlier result.
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
  if (fd < 0) { perror("Cannot create scan output"); return 0; }
  FILE *out = fdopen(fd, "wb");
  if (!out) { close(fd); unlink(path); return 0; }
  int ok = fprintf(out, "P5\n# DCP-J315W network scan, 100 dpi\n%u %u\n255\n", width, height) > 0;
  if (ok) ok = fwrite(pixels, width, height, out) == height;
  if (fclose(out)) ok = 0;
  if (!ok) { perror("Cannot finish scan output"); unlink(path); }
  return ok;
}
static int scan(int fd, const capabilities *caps, const char *path) {
  unsigned width = caps->width_pixels / 16 * 16;
  unsigned max_rows = caps->height_pixels;
  unsigned char *pixels = malloc((size_t)width * max_rows);
  if (!pixels) return 0;
  char request[256];
  int length = snprintf(request, sizeof(request),
    "\x1bX\nR=100,100\nM=GRAY256\nC=NONE\nB=50\nN=50\nU=OFF\nP=OFF\nA=0,0,%u,%u\n\x80",
    width, max_rows);
  int64_t deadline = now_ms() + 45000;
  unsigned rows = 0; int completed = 0, sent = 0;
  if (length < 0 || length >= (int)sizeof(request) ||
      !transmit(fd, request, (size_t)length, deadline)) goto end;
  sent = 1;
  fprintf(stderr, "Scanning at 100 dpi; waiting for the device's page-end marker.\n");
  while (!interrupted) {
    unsigned char tag, size[2];
    if (!receive_exact(fd, &tag, 1, deadline)) break;
    if (tag == 0x80) { completed = rows > 0; break; }
    if (tag != 0x40 || rows >= max_rows ||
        !receive_exact(fd, size, sizeof(size), deadline)) {
      fprintf(stderr, "Unsupported, truncated or oversized scan record (0x%02x).\n", tag);
      errno = EPROTO; break;
    }
    unsigned count = size[0] | (unsigned)size[1] << 8;
    if (count != width) {
      fprintf(stderr, "Unexpected scan row length %u, expected %u.\n", count, width); break;
    }
    if (!receive_exact(fd, pixels + (size_t)rows * width, width, deadline)) break;
    ++rows;
  }
end:
  if (!completed) {
    if (sent) {
      static const char cancel[] = "\x1bR";
      // Attempt cancellation even when the SIGINT flag stopped the read loop.
      (void)send(fd, cancel, sizeof(cancel) - 1, 0);
    }
    fprintf(stderr, "Scan incomplete after %u rows: %s; no image saved.\n",
            rows, interrupted ? "cancelled" : strerror(errno));
  } else {
    // The device ends this scan at 1145 rows despite advertising a maximum
    // of 1157 at 100 dpi. Save only rows actually returned with confirmed EOF.
    completed = save_image(path, pixels, width, rows);
    if (completed) printf("Saved %s: %u x %u pixels, device page-end confirmed.\n", path, width, rows);
  }
  free(pixels); return completed;
}
int main(int argc, char **argv) {
  if (argc < 3 || argc > 4 ||
      (strcmp(argv[1], "--info") && strcmp(argv[1], "--scan")) ||
      (!strcmp(argv[1], "--info") && argc != 3) ||
      (!strcmp(argv[1], "--scan") && argc != 4)) {
    fprintf(stderr, "Usage: %s --info PRINTER_IPV4\n       %s --scan PRINTER_IPV4 OUTPUT.pgm\n",
            argv[0], argv[0]); return 2;
  }
  struct sigaction action = {0}; action.sa_handler = stop;
  sigemptyset(&action.sa_mask);
  sigaction(SIGINT, &action, NULL); sigaction(SIGTERM, &action, NULL);
  signal(SIGPIPE, SIG_IGN);
  int fd = open_scanner(argv[2]);
  if (fd < 0) { perror("Cannot open scanner"); return 1; }
  capabilities caps = {0}; int ok = query(fd, &caps);
  if (ok && argc == 4) ok = scan(fd, &caps, argv[3]);
  close(fd); return ok ? 0 : 1;
}
