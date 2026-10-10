# Scanner core and macOS integration

## Core boundary

`src/scanner.c` implements the network session, capability query, request geometry
and raw grayscale/colour acquisition. Its public interface is `src/scanner.h`.

- `dcp_scan_query` opens a short-lived session and returns validated capabilities.
- `dcp_scan_acquire` opens one session, queries capabilities for the chosen mode,
  validates the requested rectangle and acquires a complete image into memory.
- `dcp_scan_free` releases the image. An acquisition argument must be an empty
  image; free a previous result before reusing it.

An image has dimensions, DPI, channels and byte stride. Channels is 1 for grayscale or 3 for interleaved RGB. Each sample is an
unsigned eight-bit value. Colour acquisition requires all three planes of every
row in order, and converts a complete row to RGB before reporting progress. A
page-end marker between planes is an error; a partial row is never returned.
The returned height is observed, not assumed from the advertised maximum.

Each call owns its connection and state. Calls block and must run on a worker
thread when integrated with an application/device module. Progress and cancellation
callbacks execute on that same thread. Shared cancellation flags must use proper
synchronisation (for example a C11 atomic); the CLI uses `sig_atomic_t` for signals.
There are no global scanner variables or files in the core.

Capabilities limit width and height to 4096 pixels each, bounding image memory
to 16 MiB for grayscale or 48 MiB for RGB, plus a bounded three-plane row buffer.
Connections and queries have five-second deadlines, acquisition has a
180-second overall deadline, and cancellation checks occur between reads and at
most every 250 milliseconds while waiting. A cancelled/failed request gets a
bounded attempt to send the scanner's reset command, followed by up to 1.5 seconds
of draining/discarding pending data to avoid an immediate TCP reset. Failed
acquisition exposes no partial image. A synchronous progress callback must return promptly.

The CLI owns command parsing, signal handling and output encoding. It writes a
temporary image inside a private staging directory beside the destination, then
uses an exclusive hard link to publish a complete file. An existing destination is never replaced, even
if another process creates it while the scanner is running. The temporary file
and staging directory are removed on normal error paths. ImageIO can recreate
the temporary image with a broader file mode, so directory permissions protect
it during encoding and the final image is explicitly set to mode 0600 before
publication. Abrupt process termination may leave a private `.partial` directory,
which should not be interpreted as a completed scan.

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

## Colour conversion

The observed uncompressed colour records carry three full-width planes. The
verified channel order is Cr (0x44), Y (0x48), Cb (0x4c), interpreted as full-range
eight-bit samples with chroma centred at 128. Colour assignment was checked against
the digital original of the scanned artwork at 100 and 300 dpi. The independently implemented RGB inverse uses the
standard coefficients in [ITU-T T.871 section 7](https://www.itu.int/rec/T-REC-T.871),
rounded to six decimal places; values are rounded and clamped to 0..255. Integer
arithmetic produces the same conversion on Intel and ARM. This scanner stream is
not a JPEG file; only the standard colour matrix is used.

The PNG encoder uses the sRGB output convention. This is not a measured device
profile or vendor-equivalent calibration. No gamma/tone table, saturation boost,
white balance or sharpening is applied. The user confirmed the scan colours appear accurate against the printed canvas.
A measured calibration and subtle channel/row registration are not yet verified.
