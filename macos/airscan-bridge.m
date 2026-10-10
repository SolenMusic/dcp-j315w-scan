// SPDX-License-Identifier: MIT
// Local-only AirScan adapter around the independent Brother network core.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dns_sd.h>
#include <arpa/inet.h>
#include <stdatomic.h>
#include <signal.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include "../src/scanner.h"

static NSString *printerAddress, *uuid, *capsXML;
static unsigned port;
static NSLock *jobsLock;
static dispatch_semaphore_t connections;
static volatile sig_atomic_t stopping;
static int listenSocket = -1;
static void idleSource(void *context) { (void)context; }
static void stop(int n) { (void)n; stopping = 1; }
static void trace(NSString *s) { fprintf(stderr, "AirScan: %s\n", s.UTF8String); }
@interface DCPJob : NSObject {
@public atomic_bool cancelled;
}
@property(nonatomic) dcp_scan_options options;
@property(nonatomic) unsigned cropLeft;
@property(nonatomic) unsigned cropWidth;
@property(nonatomic) BOOL oneBit;
@property(nonatomic, copy) NSString *mime;
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *state;
@property(nonatomic, strong) NSData *image;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL delivered;
@property(nonatomic, strong) NSDate *created;
@end
@implementation DCPJob
- (instancetype)init {
  if ((self = [super init])) {
    atomic_init(&cancelled, false); _condition = [NSCondition new];
    _identifier = NSUUID.UUID.UUIDString; _state = @"Processing"; _created = NSDate.date;
  }
  return self;
}
@end
static DCPJob *activeJob;
@interface DCPSettings : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableDictionary *values;
@property(nonatomic, strong) NSMutableString *text;
@property(nonatomic) NSUInteger regions;
@property(nonatomic) BOOL invalid;
@property(nonatomic) BOOL rootSeen;
@end
@implementation DCPSettings
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)a {
  (void)q; (void)a;
  if (!_rootSeen) {
    _rootSeen = YES;
    if (![name isEqualToString:@"ScanSettings"] || ![ns isEqualToString:@"http://schemas.hp.com/imaging/escl/2011/05/03"]) {
      _invalid = YES; [p abortParsing]; return;
    }
  }
  if ([name isEqualToString:@"ScanRegion"]) ++_regions;
  _text = [NSMutableString new];
  if (_regions > 1) { _invalid = YES; [p abortParsing]; }
}
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)text { (void)p; [_text appendString:text]; }
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
  (void)p; (void)ns; (void)q;
  NSSet *keys = [NSSet setWithArray:@[@"Width", @"Height", @"XOffset", @"YOffset", @"XResolution", @"YResolution", @"ColorMode", @"InputSource", @"DocumentFormat", @"DocumentFormatExt", @"ContentRegionUnits"]];
  if ([keys containsObject:name]) {
    if (_values[name]) _invalid = YES;
    _values[name] = [_text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  }
  _text = [NSMutableString new];
}
@end
static BOOL number(NSString *s, unsigned *result) {
  if (!s.length) return NO;
  for (const char *p = s.UTF8String; *p; ++p) if (*p < '0' || *p > '9') return NO;
  errno = 0;
  unsigned long long v = strtoull(s.UTF8String, NULL, 10);
  if (errno || v > 100000) return NO;
  *result = (unsigned)v; return YES;
}
static BOOL settings(NSData *body, dcp_scan_options *o, unsigned *cropLeft, unsigned *cropWidth, BOOL *oneBit, NSString **mime) {
  NSString *xml = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
  if (!xml || [xml rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location != NSNotFound ||
      [xml rangeOfString:@"<!ENTITY" options:NSCaseInsensitiveSearch].location != NSNotFound) return NO;
  DCPSettings *delegate = [DCPSettings new]; delegate.values = [NSMutableDictionary new];
  NSXMLParser *parser = [[NSXMLParser alloc] initWithData:body];
  parser.shouldProcessNamespaces = YES; parser.shouldResolveExternalEntities = NO; parser.delegate = delegate;
  if (![parser parse] || delegate.invalid || delegate.regions > 1) return NO;
  NSDictionary *v = delegate.values;
  unsigned dpi = 100, ydpi = 100, x = 0, y = 0, w = 2480, h = 3435;
  if ((v[@"XResolution"] && !number(v[@"XResolution"], &dpi)) ||
      (v[@"YResolution"] && !number(v[@"YResolution"], &ydpi)) ||
      (!!v[@"XResolution"] != !!v[@"YResolution"]) || dpi != ydpi || (dpi != 100 && dpi != 300) ||
      (delegate.regions && (!number(v[@"Width"], &w) || !number(v[@"Height"], &h))) ||
      (v[@"XOffset"] && !number(v[@"XOffset"], &x)) || (v[@"YOffset"] && !number(v[@"YOffset"], &y)) ||
      x >= 2480 || y >= 3435 || w < 48 || h < 3 || w > 2480 - x || h > 3435 - y) return NO;
  if (v[@"InputSource"] && ![v[@"InputSource"] isEqualToString:@"Platen"]) return NO;
  for (NSString *key in @[@"DocumentFormat", @"DocumentFormatExt"])
    if (v[key] && ![v[key] isEqualToString:@"image/png"] && ![v[key] isEqualToString:@"image/jpeg"]) return NO;
  if (v[@"DocumentFormat"] && v[@"DocumentFormatExt"] && ![v[@"DocumentFormat"] isEqualToString:v[@"DocumentFormatExt"]]) return NO;
  *mime = v[@"DocumentFormatExt"] ?: v[@"DocumentFormat"] ?: @"image/jpeg";
  if (v[@"ContentRegionUnits"] && ![v[@"ContentRegionUnits"] hasSuffix:@"ThreeHundredthsOfInches"]) return NO;
  NSString *mode = v[@"ColorMode"] ?: @"RGB24";
  *oneBit = [mode isEqualToString:@"BlackAndWhite1"];
  if (![mode isEqualToString:@"RGB24"] && ![mode isEqualToString:@"Grayscale8"] && !*oneBit) return NO;
  // The core currently needs 16-pixel X alignment. Keep the requested rectangle
  // inside the actual acquired rectangle; crop to exact client bounds later.
  unsigned left = x * dpi / 300, right = (x + w) * dpi / 300;
  unsigned top = y * dpi / 300, bottom = (y + h) * dpi / 300;
  unsigned alignedLeft = left / 16 * 16, alignedRight = (right + 15) / 16 * 16;
  unsigned maxWidth = dpi == 100 ? 816 : 2480;
  if (alignedRight > maxWidth) alignedRight = maxWidth;
  if (alignedRight <= left || bottom <= top) return NO;
  *o = (dcp_scan_options){.dpi = dpi, .x = alignedLeft, .y = top,
    .width = alignedRight - alignedLeft, .height = bottom - top,
    .mode = [mode isEqualToString:@"RGB24"] ? DCP_SCAN_COLOUR : DCP_SCAN_GRAY};
  *cropLeft = left - alignedLeft;
  *cropWidth = MIN(right, alignedRight) - left;
  return YES;
}
static NSData *encode(const dcp_scan_image *image, BOOL oneBit, NSString *mime) {
  BOOL jpeg = [mime isEqualToString:@"image/jpeg"];
  if (oneBit && image->channels != 1) return nil;
  size_t stride = oneBit ? (jpeg ? image->width : (image->width + 7) / 8) : image->stride;
  unsigned char *packed = oneBit ? calloc(stride, image->height) : NULL;
  if (oneBit && !packed) return nil;
  if (oneBit) for (unsigned y = 0; y < image->height; ++y) for (unsigned x = 0; x < image->width; ++x)
    if (image->pixels[y * image->stride + x] >= 128) {
      if (jpeg) packed[y * stride + x] = 255;
      else packed[y * stride + x / 8] |= 0x80 >> (x % 8);
    }
  CGColorSpaceRef space = image->channels == 3 ? CGColorSpaceCreateWithName(kCGColorSpaceSRGB) : CGColorSpaceCreateDeviceGray();
  CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, oneBit ? packed : image->pixels, stride * image->height, NULL);
  BOOL packedBits = oneBit && !jpeg;
  CGImageRef bitmap = provider && space ? CGImageCreate(image->width, image->height, packedBits ? 1 : 8, packedBits ? 1 : image->channels * 8,
    stride, space, (CGBitmapInfo)kCGImageAlphaNone, provider, NULL, false, kCGRenderingIntentDefault) : NULL;
  NSMutableData *data = [NSMutableData new];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, jpeg ? CFSTR("public.jpeg") : CFSTR("public.png"), 1, NULL);
  BOOL ok = bitmap && dest;
  if (ok) {
    NSDictionary *properties = @{ (__bridge NSString *)kCGImagePropertyDPIWidth: @(image->dpi),
                                  (__bridge NSString *)kCGImagePropertyDPIHeight: @(image->dpi),
                                  (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @1.0 };
    CGImageDestinationAddImage(dest, bitmap, (__bridge CFDictionaryRef)properties);
    ok = CGImageDestinationFinalize(dest);
  }
  if (dest) CFRelease(dest); if (bitmap) CGImageRelease(bitmap);
  if (provider) CGDataProviderRelease(provider); if (space) CGColorSpaceRelease(space);
  free(packed);
  return ok ? data : nil;
}
static int cancelled(void *context) { return atomic_load(&((__bridge DCPJob *)context)->cancelled); }
static void acquire(DCPJob *job) {
  @autoreleasepool {
    dcp_scan_image image = {0}; char error[256];
    dcp_scan_options o = job.options;
    dcp_scan_callbacks callbacks = {.context = (__bridge void *)job, .cancelled = cancelled};
    trace([NSString stringWithFormat:@"acquiring %@ at %u dpi", o.mode == DCP_SCAN_COLOUR ? @"colour" : @"grayscale", o.dpi]);
    int ok = dcp_scan_acquire(printerAddress.UTF8String, &o, &image, &callbacks, error, sizeof(error));
    if (ok && (job.cropLeft || job.cropWidth != image.width)) {
      size_t stride = (size_t)job.cropWidth * image.channels;
      for (unsigned row = 0; row < image.height; ++row)
        memmove(image.pixels + row * stride, image.pixels + row * image.stride + job.cropLeft * image.channels, stride);
      image.width = job.cropWidth; image.stride = stride;
    }
    NSData *png = ok && !cancelled((__bridge void *)job) ? encode(&image, job.oneBit, job.mime) : nil;
    dcp_scan_free(&image);
    [job.condition lock];
    job.finished = YES;
    job.state = cancelled((__bridge void *)job) ? @"Canceled" : (png ? @"Processing" : @"Aborted");
    if (!cancelled((__bridge void *)job)) job.image = png;
    [job.condition broadcast]; [job.condition unlock];
    trace(png ? @"complete image ready for native client" : [NSString stringWithFormat:@"acquisition failed: %s", ok ? "image export/cancellation" : error]);
  }
}
static BOOL sendAll(int fd, NSData *data) {
  const unsigned char *p = data.bytes; size_t left = data.length;
  while (left) {
    ssize_t n = send(fd, p, left, 0);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return NO;
    p += n; left -= (size_t)n;
  }
  return YES;
}
static BOOL response(int fd, unsigned status, NSString *type, NSData *body, NSDictionary *extra) {
  NSDictionary *reasons = @{@200:@"OK", @201:@"Created", @202:@"Accepted", @400:@"Bad Request", @403:@"Forbidden", @404:@"Not Found", @405:@"Method Not Allowed", @408:@"Request Timeout", @409:@"Conflict", @413:@"Payload Too Large", @415:@"Unsupported Media Type", @500:@"Internal Server Error", @503:@"Service Unavailable"};
  body = body ?: [NSData data];
  NSMutableString *header = [NSMutableString stringWithFormat:@"HTTP/1.1 %u %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\n", status, reasons[@(status)] ?: @"Error", type ?: @"text/plain", (unsigned long)body.length];
  for (NSString *key in extra) [header appendFormat:@"%@: %@\r\n", key, extra[key]];
  [header appendString:@"\r\n"];
  return sendAll(fd, [header dataUsingEncoding:NSUTF8StringEncoding]) && sendAll(fd, body);
}
static NSData *xmlData(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
static NSString *jobXML(DCPJob *job) {
  [job.condition lock];
  NSString *text = [NSString stringWithFormat:@"<scan:JobInfo><pwg:JobUri>http://127.0.0.1:%u/eSCL/ScanJobs/%@</pwg:JobUri><pwg:JobUuid>urn:uuid:%@</pwg:JobUuid><scan:Age>%u</scan:Age><pwg:JobState>%@</pwg:JobState><pwg:ImagesCompleted>%u</pwg:ImagesCompleted><pwg:JobStateReasons><pwg:JobStateReason>None</pwg:JobStateReason></pwg:JobStateReasons></scan:JobInfo>",
    port, job.identifier, job.identifier, (unsigned)MAX(0, -job.created.timeIntervalSinceNow), job.state, job.finished && (job.image || job.delivered) ? 1 : 0];
  [job.condition unlock]; return text;
}
static void route(int fd, NSString *method, NSString *path, NSData *body) {
  if (![path isEqualToString:@"/eSCL/ScannerStatus"]) trace([NSString stringWithFormat:@"%@ %@", method, path]);
  if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/eSCL/ScannerCapabilities"]) {
    response(fd, 200, @"text/xml", xmlData(capsXML), nil); return;
  }
  [jobsLock lock]; DCPJob *job = activeJob; [jobsLock unlock];
  if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/eSCL/ScannerStatus"]) {
    [job.condition lock]; BOOL processing = job && !job.finished; [job.condition unlock];
    NSString *xml = [NSString stringWithFormat:@"<?xml version=\"1.0\"?><scan:ScannerStatus xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\"><pwg:Version>2.0</pwg:Version><pwg:State>%@</pwg:State><pwg:StateReasons><pwg:StateReason>None</pwg:StateReason></pwg:StateReasons><scan:Jobs>%@</scan:Jobs></scan:ScannerStatus>", processing ? @"Processing" : @"Idle", job ? jobXML(job) : @""];
    response(fd, 200, @"text/xml", xmlData(xml), nil); return;
  }
  if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/eSCL/ScanJobs"]) {
    dcp_scan_options o; unsigned cropLeft, cropWidth; BOOL oneBit; NSString *mime = nil;
    if (!settings(body, &o, &cropLeft, &cropWidth, &oneBit, &mime)) {
      trace(@"unsupported scan settings");
      response(fd, 400, nil, nil, nil); return;
    }
    [jobsLock lock];
    [activeJob.condition lock];
    BOOL expired = activeJob && !activeJob.started && -activeJob.created.timeIntervalSinceNow > 30;
    if (expired) { activeJob.finished = YES; activeJob.state = @"Aborted"; }
    BOOL busy = activeJob && (!activeJob.finished || (activeJob.image && !activeJob.delivered && -activeJob.created.timeIntervalSinceNow < 300));
    [activeJob.condition unlock];
    if (busy) { [jobsLock unlock]; response(fd, 503, nil, nil, @{@"Retry-After":@"3"}); return; }
    DCPJob *next = [DCPJob new]; next.options = o; next.cropLeft = cropLeft; next.cropWidth = cropWidth; next.oneBit = oneBit; next.mime = mime; activeJob = next;
    [jobsLock unlock];
    NSString *location = [NSString stringWithFormat:@"http://127.0.0.1:%u/eSCL/ScanJobs/%@", port, next.identifier];
    response(fd, 201, nil, nil, @{@"Location":location}); return;
  }
  NSString *base = job ? [@"/eSCL/ScanJobs/" stringByAppendingString:job.identifier] : nil;
  if (base && [method isEqualToString:@"DELETE"] && [path isEqualToString:base]) {
    atomic_store(&job->cancelled, true);
    [job.condition lock]; job.image = nil; job.state = @"Canceled";
    if (!job.started) job.finished = YES;
    [job.condition broadcast]; [job.condition unlock];
    response(fd, 200, nil, nil, nil); return;
  }
  if (base && [method isEqualToString:@"GET"] && [path isEqualToString:[base stringByAppendingString:@"/NextDocument"]]) {
    [job.condition lock];
    if (!job.started && !atomic_load(&job->cancelled)) {
      job.started = YES;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ acquire(job); });
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!job.finished && !atomic_load(&job->cancelled))
      if (![job.condition waitUntilDate:deadline]) break;
    BOOL cancelledJob = atomic_load(&job->cancelled), finished = job.finished;
    NSData *png = cancelledJob ? nil : job.image;
    // Never consume a page before transmission succeeds. Limit readiness waits
    // so native clients can retry without leaving timed-out requests queued.
    BOOL sent = response(fd, png ? 200 : cancelledJob || finished ? 404 : 503,
      png ? job.mime : nil, png, !png && !cancelledJob && !finished ? @{@"Retry-After":@"1"} : nil);
    if (png && sent) { job.delivered = YES; job.image = nil; job.state = @"Completed"; }
    [job.condition unlock]; return;
  }
  response(fd, 404, nil, nil, nil);
}
static void client(int fd) {
  @autoreleasepool {
    // On macOS accept inherits the listener's nonblocking flag. Each request
    // worker uses bounded blocking I/O, so restore that mode before reading.
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)) {
      close(fd); dispatch_semaphore_signal(connections); return;
    }
    struct timeval timeout = {10, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    timeout.tv_sec = 30; setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    NSMutableData *request = [NSMutableData new];
    NSData *marker = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange split = {NSNotFound, 0}; unsigned char buffer[4096];
    NSString *header = nil, *contentType = nil; NSArray *lines = nil, *first = nil;
    while (request.length < 32768 && split.location == NSNotFound) {
      ssize_t n = recv(fd, buffer, sizeof(buffer), 0); if (n <= 0) goto end;
      [request appendBytes:buffer length:(NSUInteger)n];
      split = [request rangeOfData:marker options:0 range:NSMakeRange(0, request.length)];
    }
    if (split.location == NSNotFound) { response(fd, 413, nil, nil, nil); goto end; }
    header = [[NSString alloc] initWithData:[request subdataWithRange:NSMakeRange(0, split.location)] encoding:NSASCIIStringEncoding];
    lines = [header componentsSeparatedByString:@"\r\n"]; first = [lines.firstObject componentsSeparatedByString:@" "];
    if (!header || first.count != 3) { response(fd, 400, nil, nil, nil); goto end; }
    unsigned length = 0; BOOL hasLength = NO;
    for (NSUInteger i = 1; i < lines.count; ++i) {
      NSRange colon = [lines[i] rangeOfString:@":"];
      if (colon.location == NSNotFound) { response(fd, 400, nil, nil, nil); goto end; }
      NSString *key = [[lines[i] substringToIndex:colon.location] lowercaseString];
      NSString *v = [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if ([key isEqualToString:@"origin"]) { response(fd, 403, nil, nil, nil); goto end; }
      if ([key isEqualToString:@"content-type"]) contentType = [[v componentsSeparatedByString:@";"][0] lowercaseString];
      if ([key isEqualToString:@"transfer-encoding"]) { response(fd, 400, nil, nil, nil); goto end; }
      if ([key isEqualToString:@"content-length"]) {
        if (hasLength || !number(v, &length) || length > 65536) { response(fd, 413, nil, nil, nil); goto end; }
        hasLength = YES;
      }
      if ([key isEqualToString:@"expect"] && [v.lowercaseString isEqualToString:@"100-continue"])
        (void)sendAll(fd, [@"HTTP/1.1 100 Continue\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding]);
    }
    NSUInteger offset = NSMaxRange(split);
    if ([first[0] isEqualToString:@"POST"] && ![contentType isEqualToString:@"text/xml"] && ![contentType isEqualToString:@"application/xml"]) {
      response(fd, 415, nil, nil, nil); goto end;
    }
    while (request.length < offset + length) {
      ssize_t n = recv(fd, buffer, MIN(sizeof(buffer), offset + length - request.length), 0);
      if (n <= 0) goto end;
      [request appendBytes:buffer length:(NSUInteger)n];
    }
    route(fd, first[0], first[1], [request subdataWithRange:NSMakeRange(offset, length)]);
end:
    close(fd); dispatch_semaphore_signal(connections);
  }
}
static void serviceReply(DNSServiceRef service, DNSServiceFlags flags, DNSServiceErrorType error, const char *name, const char *type, const char *domain, void *context) {
  (void)service; (void)flags; (void)type; (void)domain; (void)context;
  trace([NSString stringWithFormat:@"local discovery registration %@, status %d", [NSString stringWithUTF8String:name ?: ""], error]);
}
static void addressReply(DNSServiceRef service, DNSRecordRef record, DNSServiceFlags flags, DNSServiceErrorType error, void *context) {
  (void)service; (void)record; (void)flags; (void)context;
  trace([NSString stringWithFormat:@"loopback hostname registration status %d", error]);
}
int main(int argc, char **argv) {
  @autoreleasepool {
    BOOL discovery = argc == 3;
    if ((argc != 3 && argc != 4) || strcmp(argv[1], "--address") ||
        (argc == 4 && strcmp(argv[3], "--no-discovery"))) {
      fprintf(stderr, "Usage: %s --address PRINTER_IPV4 [--no-discovery]\n", argv[0]); return 2;
    }
    struct in_addr ip; if (inet_pton(AF_INET, argv[2], &ip) != 1) return 2;
    printerAddress = [NSString stringWithUTF8String:argv[2]];
    uuid = [NSString stringWithFormat:@"d315d315-5492-5100-8000-0000%08x", ntohl(ip.s_addr)];
    signal(SIGPIPE, SIG_IGN); signal(SIGINT, stop); signal(SIGTERM, stop);
    listenSocket = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {0}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (listenSocket < 0 || bind(listenSocket, (struct sockaddr *)&address, sizeof(address)) || listen(listenSocket, 8)) { perror("Loopback listener"); return 1; }
    int flags = fcntl(listenSocket, F_GETFL);
    if (flags < 0 || fcntl(listenSocket, F_SETFL, flags | O_NONBLOCK)) return 1;
    socklen_t size = sizeof(address); getsockname(listenSocket, (struct sockaddr *)&address, &size); port = ntohs(address.sin_port);
    NSString *path = [NSBundle.mainBundle pathForResource:@"ScannerCapabilities" ofType:@"xml"];
    capsXML = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!capsXML) { fprintf(stderr, "Missing ScannerCapabilities.xml resource\n"); return 1; }
    capsXML = [[capsXML stringByReplacingOccurrencesOfString:@"__UUID__" withString:uuid] stringByReplacingOccurrencesOfString:@"__PORT__" withString:[NSString stringWithFormat:@"%u",port]];
    jobsLock = [NSLock new]; connections = dispatch_semaphore_create(8);
    DNSServiceRef connection = NULL, service = NULL; DNSRecordRef record = NULL;
    uint32_t loopback = htonl(INADDR_LOOPBACK);
    const char *host = "dcp-j315w-open-scanner.local.";
    DNSServiceErrorType e = discovery ? DNSServiceCreateConnection(&connection) : 0;
    if (discovery && !e) e = DNSServiceRegisterRecord(connection, &record, kDNSServiceFlagsUnique,
      kDNSServiceInterfaceIndexLocalOnly, host, kDNSServiceType_A, kDNSServiceClass_IN,
      sizeof(loopback), &loopback, 60, addressReply, NULL);
    TXTRecordRef txt; TXTRecordCreate(&txt, 0, NULL);
    NSDictionary *values = @{@"txtvers":@"1", @"ty":@"DCP-J315W Open Scanner", @"rs":@"eSCL", @"pdl":@"image/jpeg,image/png", @"cs":@"color,grayscale,binary", @"is":@"platen", @"UUID":uuid};
    for (NSString *key in values) { NSData *v = [values[key] dataUsingEncoding:NSUTF8StringEncoding]; TXTRecordSetValue(&txt,key.UTF8String,(uint8_t)v.length,v.bytes); }
    if (discovery && !e) e = DNSServiceRegister(&service, 0, kDNSServiceInterfaceIndexLocalOnly, "DCP-J315W Open Scanner", "_uscan._tcp.", "local.", host, htons((uint16_t)port), TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), serviceReply, NULL);
    TXTRecordDeallocate(&txt);
    if (e) { fprintf(stderr, "Local Bonjour registration failed: %d\n", e); return 1; }
    dispatch_queue_t discoveryQueue = dispatch_queue_create("org.dcpj315w.scan.discovery", DISPATCH_QUEUE_SERIAL);
    DNSServiceErrorType ce = discovery ? DNSServiceSetDispatchQueue(connection, discoveryQueue) : 0;
    DNSServiceErrorType se = discovery ? DNSServiceSetDispatchQueue(service, discoveryQueue) : 0;
    trace([NSString stringWithFormat:@"Bonjour queue setup: %d, %d", ce, se]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      while (!stopping) {
        struct pollfd ready = {listenSocket, POLLIN, 0};
        int available = poll(&ready, 1, 250);
        if (!available || (available < 0 && errno == EINTR)) continue;
        if (available < 0) break;
        int fd = accept(listenSocket, NULL, NULL);
        if (fd < 0) { if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue; break; }
        if (dispatch_semaphore_wait(connections, DISPATCH_TIME_NOW)) { close(fd); continue; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ client(fd); });
      }
      CFRunLoopStop(CFRunLoopGetMain());
    });
    trace([NSString stringWithFormat:@"listening only on 127.0.0.1:%u; Bonjour %@", port, discovery ? @"local-only" : @"disabled"]);
    CFRunLoopSourceContext idle = {0}; idle.perform = idleSource;
    CFRunLoopSourceRef keepAlive = CFRunLoopSourceCreate(NULL, 0, &idle);
    CFRunLoopAddSource(CFRunLoopGetMain(), keepAlive, kCFRunLoopDefaultMode);
    CFRunLoopRun();
    CFRunLoopRemoveSource(CFRunLoopGetMain(), keepAlive, kCFRunLoopDefaultMode); CFRelease(keepAlive);
    [jobsLock lock]; DCPJob *last = activeJob;
    if (last) atomic_store(&last->cancelled,true);
    [jobsLock unlock];
    // Let the acquisition worker send the device reset before process exit.
    [last.condition lock]; NSDate *shutdownDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (last && last.started && !last.finished) if (![last.condition waitUntilDate:shutdownDeadline]) break;
    [last.condition unlock];
    if (service) DNSServiceRefDeallocate(service);
    if (connection) DNSServiceRefDeallocate(connection);
    close(listenSocket);
    return 0;
  }
}
