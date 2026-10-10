# Scanner core and macOS integration

## Core boundary

`src/scanner.c` implements the network session, capability query, request geometry
and raw grayscale acquisition. Its public interface is `src/scanner.h`.

- `dcp_scan_query` opens a short-lived session and returns validated capabilities.
- `dcp_scan_acquire` opens one session, queries capabilities for the chosen mode,
  validates the requested rectangle and acquires a complete image into memory.
- `dcp_scan_free` releases the image. An acquisition argument must be an empty
  image; free a previous result before reusing it.

An image has dimensions, DPI, channels and byte stride. Currently channels is 1
and each sample is an unsigned eight-bit grayscale value. The returned height is
observed, not assumed from the advertised maximum.

Each call owns its connection and state. Calls block and must run on a worker
thread when integrated with an application/device module. Progress and cancellation
callbacks execute on that same thread. Shared cancellation flags must use proper
synchronisation (for example a C11 atomic); the CLI uses `sig_atomic_t` for signals.
There are no global scanner variables or files in the core.

Capabilities limit width and height to 4096 pixels each, bounding grayscale memory
to 16 MiB. Connections and queries have five-second deadlines, acquisition has a
180-second overall deadline, and cancellation checks occur between reads and at
most every 250 milliseconds while waiting. A cancelled/failed request gets a
bounded attempt to send the scanner's reset command, followed by up to 1.5 seconds
of draining/discarding pending data to avoid an immediate TCP reset. Failed acquisition exposes
no partial image. A synchronous progress callback must return promptly.

The CLI owns command parsing, signal handling and output encoding. It writes a
private temporary file in the destination directory, then uses an exclusive hard
link to publish a complete file. An existing destination is never replaced, even
if another process creates it while the scanner is running. The temporary file
is removed on normal error paths. Abrupt process termination may leave a private
`.partial` file, which should not be interpreted as a completed scan.

## Planned native adapter

Image Capture integration will wrap the core in an ICA scanner device module,
with a separate adapter for discovery, sessions, capabilities, selected scan area,
preview and image-data delivery. PDF assembly should be left to the scanning
application. The reusable core can later also serve a SANE backend on Linux.

The locally installed macOS SDK contains `ICADevices.framework`, including
`ICD_ScannerCalls.h`, scanner session/parameter/start callbacks,
`ICD_ScannerMain` and TCP/IP device connection functions. The SDK's library
exports those entry points. This establishes available build interfaces, **not**
proof that our device module is recognised or works in current Image Capture.
The callback dictionaries, device registration, image notifications, signing and
actual UI integration still need implementation and verification.

No scanner module is installed by this prototype, and no printing queue or CUPS
source is changed.
