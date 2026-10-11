# Scanner core and platform integration

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

## Native macOS integration

The working adapter is `macos/airscan-bridge.m`, an independent eSCL/AirScan
provider. Apple's built-in AirScan scanner module recognises its local-only
Bonjour service and exposes it to Image Capture. There is no custom scanning UI.
The bridge owns protocol translation, job state, rectangular crops and transport
encoding; the native application owns output naming, PDF assembly and OCR.

A legacy ICA device-module draft was investigated using the installed SDK and
Apple's VirtualScanner sample. It built but its development launch did not
register successfully on this machine. That unverified draft remains in ignored
research files; it is not installed or part of the working adapter. No conclusion
is drawn about every possible ICA installation path.

The tested native client needs JPEG transport to construct usable scanning
settings and display previews; PNG-only advertising produced incomplete requests
and a blank preview. The bridge offers JPEG at quality 1.0 as well as lossless
PNG. JPEG is not mathematically lossless. The core always acquires uncompressed
scanner records. A one-bit text mode is implemented by thresholding eight-bit
gray samples at 128 in the adapter.

Scan job creation does not activate hardware. Acquisition begins on the first
NextDocument request, which lets Apple's default-settings probe create and
cancel a job harmlessly. While acquisition is pending, NextDocument returns a
bounded 503/Retry-After response; the tested native client retries. This avoids
queuing requests that time out during a long scan. An image is consumed only
after a successful send, and the next request then reports the end of the single
flatbed page. Failure or cancellation never delivers a partial image.

The listener binds only to loopback, advertises only on Bonjour's local-only
interface, limits headers/bodies/connections, rejects browser Origin requests,
requires XML job bodies, and disables XML external entities. The bridge keeps one
job and one encoded image at a time. Unstarted jobs expire after 30 seconds; old
completed images can be replaced after five minutes. Shutdown gives an active
worker up to five seconds to send cancellation before exiting.

The per-user Bash installer copies the universal app to Library/Application
Support/DCPJ315WScan, writes a private LaunchAgent and starts it at login. No root
authentication, CUPS source or printing queue changes are involved. The application
only exposes this computer's scanner interface; it is not a LAN scan server.

## Linux SANE integration

`linux/sane-dcpj315w.c` implements SANE's public backend ABI. It compiles as
`libsane-dcpj315w.so.1`, without linking the SANE implementation or a vendor driver.
The host SANE loader loads the backend and gives existing scanner applications
the standard options for mode, source, DPI, preview and millimetre geometry.

The adapter acquires a complete image synchronously in `sane_start`, then exposes
it through chunked `sane_read` calls. Parameters have the actual returned height
after acquisition; earlier estimates use unknown height (-1). This preserves the
core's policy of withholding incomplete transfers. Frontends are responsible for
performing blocking scanner calls outside their UI thread and for output/PDF
assembly. There is no Linux background bridge or additional scan application.

Requests expand horizontal bounds to the core's 16-pixel wire alignment and crop
back to the desired pixels in place. Text mode thresholds grayscale at 128 and
packs black pixels as one bits, most significant bit first, as required by SANE.
Grayscale and colour samples remain unchanged. Cancellation is only a lock-free
atomic store, safe for frontend signal handlers; the core checks that flag during
I/O and sends its bounded reset. Other SANE operations follow the standard's
non-reentrant contract. One acquisition is allowed at a time within the process;
cross-process or cross-computer arbitration has not been implemented.

Numeric addresses come from `dcpj315w.conf` (with SANE_CONFIG_DIR search support)
or an explicit `dcpj315w:IPV4` device selection. Listing configured devices does
not probe the printer. The Bash installer adds only this backend's shared library
and its own configuration/drop-in; it leaves existing backends and printing
configuration intact. The Fedora x86_64 and ARM64 simulation suites use the real
SANE loader and `scanimage`, not calls that bypass the loader. The user subsequently
confirmed physical Wi-Fi acquisition through GNOME Document Scanner on Fedora 41
x86_64, with automatic default device selection and an image returned. The user
also confirmed good-looking 300 dpi colour and multipage PDF export. Linux ARM64
hardware acquisition remains unverified; the colour check is a visual assessment,
not measured calibration.

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
