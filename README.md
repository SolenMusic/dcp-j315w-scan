# DCP-J315W Network Scanner

An independent native wireless-scanning core for the **Brother DCP-J315W**, with
native macOS Image Capture integration and a command-line test client. This project is separate from the
`dcp-j315w-cups` printing repository and has no CUPS dependency.

Created with LLM-assisted coding and controlled experiments on a real printer.
The native Apple Silicon macOS client has acquired readable release notes over
Wi-Fi at both 100 and 300 dpi. I hope this helps keep these scanners useful for a
while longer.

## Current scope

- Direct IPv4 connection to the scanner service on TCP port 54921.
- Grayscale and initial colour acquisition at 100, 150 or 300 dpi.
- Full-bed scans and selectable rectangular regions, with bounded memory use.
- Native macOS PNG export with correct DPI metadata; portable 8-bit PGM/PPM export.
- Strict three-plane colour framing and a standard YCbCr-to-RGB conversion.
  Channel order was checked against the digital original of the scanned artwork.
- Fragmented TCP transfer handling, strict record validation, a 180-second scan
  deadline, cancellation and progress callbacks.
- No partial image on transfer failure; output files are private and existing
  files are never overwritten. Existing paths are rejected before scanning.
- A reusable, synchronous C11 core without global state or UI dependencies, and
  a universal macOS static library build for Intel and Apple Silicon.

**Native Image Capture now works on the tested Apple Silicon Mac running macOS
27.** A small, local AirScan bridge exposes the existing scanner core to Apple's
built-in scanner driver. The bridge has no custom scanning GUI. Image Capture
provides overview, region selection, colour/grayscale controls and PDF export.
A mixed-resolution, mixed-colour two-page PDF has been physically checked.

A Linux SANE backend remains the target for GNOME Document Scanner and KDE
Skanpage. The command-line client is also available for development.

Automatic printer-address discovery, measured colour calibration, 600 dpi,
USB support, a signed public scanner installer and Linux SANE integration remain
to be implemented. Native 300 dpi colour acquisition has been physically checked, and
channel order matches the supplied digital original. The user confirmed the scan
colours appear accurate against the printed canvas. No scanner ICC
profile or vendor tone table is included; PNG RGB is tagged as sRGB as a practical
output convention, not as a calibrated measurement of the scanner.

## Native macOS installation

With Xcode or its command-line tools installed:

```sh
./build-macos-airscan.sh
./install-macos-airscan.sh --address PRINTER_IPV4
```

Run as your normal user, without sudo. This builds a universal Intel/Apple Silicon
app, installs it under your user's Library/Application Support, and starts a
LaunchAgent at login. Source builds use an ad hoc signature; this scanner project
has not yet had a signed/notarized public release. The installer uses Bash and
macOS system tools, not Python.

Open **Image Capture**, choose **DCP-J315W Open Scanner** under Shared, and select
**Show Details**. Click **Overview**, select the desired area, then scan. For
ordinary documents or artwork choose **300 dpi**. Choose **PDF** and enable
**Combine into single document** to append subsequent flatbed scans using the same
name. Changing Kind can reset Format to JPEG in Image Capture; select PDF again
if necessary. Native PDF export, including a 300 dpi colour page followed by a
100 dpi grayscale page, has been checked. The two test pages used the same canvas
without moving it, so this verifies PDF assembly rather than paper feeding.

The helper listens **only on 127.0.0.1** and its Bonjour announcement uses the
local-only interface. It does not share this scanner with other computers or iOS.
Printer traffic goes directly to the configured IPv4 address. If that address
changes, rerun the installer with the new address. No CUPS queue or printer driver
is modified. Scanned images remain in memory until delivered to the native app;
the native app controls its output files and their permissions. Configuration and
bridge logs are private to this user.

To remove the helper and login startup entry:

```sh
./uninstall-macos-airscan.sh
```

This preserves native applications' scanned documents and the helper's diagnostic
log. See [macOS integration notes](macos/README.md) for lifecycle and limitations.

## Command-line build and use

From this project folder, with Xcode or its command-line tools installed:

```sh
./build.sh
./dcp-j315w-scan --info PRINTER_IPV4 --dpi 300
./dcp-j315w-scan --scan PRINTER_IPV4 result.png --dpi 300
./dcp-j315w-scan --scan PRINTER_IPV4 preview.pgm
./dcp-j315w-scan --scan PRINTER_IPV4 artwork.png --dpi 300 --mode colour
./dcp-j315w-scan --scan PRINTER_IPV4 artwork.ppm --mode colour
./dcp-j315w-scan --scan PRINTER_IPV4 crop.png --dpi 300 --area 160,300,800,600
```

Replace `PRINTER_IPV4` with the printer's numeric network address. Put a document
on the glass and close the lid before scanning. The output filename must be new.
No administrator authentication or system installation is needed. Use Ctrl-C to
cancel. PNG export uses Apple's ImageIO; no Python or external image converter is
needed. The PNG records the chosen resolution in both axes. `--mode colour`
(or `--mode color`) selects colour; the default is `--mode gray`. Use `.ppm` for
portable RGB or `.pgm` for grayscale, and `.png` for either mode on macOS.

The `--area` values are **x, y, width, height in pixels at the selected DPI**.
X and width must be multiples of 16; zero width/height means the remaining bed.
The CLI converts those dimensions to the protocol's absolute right/bottom bounds.
A full-bed scan can end before the reported maximum height; only the rows actually
returned with a confirmed device page-end marker are saved.

`build.sh` accepts `CC`, `CFLAGS`, `LDFLAGS` and `OUTPUT`, and applies an ad hoc
signature on macOS. This is not yet a packaged or notarized release. The networking
core uses only the system C runtime; the CLI additionally links Apple frameworks
for PNG export on macOS. Portable PGM/PPM remains available without those frameworks.

## Reusable macOS core

```sh
./build-macos-core.sh
```

This creates `build/macos-core/libdcpscan.a` for arm64 and x86_64, plus its public
header. It requires the macOS SDK and targets macOS 11 or later. The static library
contains no ImageIO or GUI code. See [the core interface](src/scanner.h) and
[architecture notes](CORE.md) for the ownership, threading and callback contract.

## Verification

```sh
python3 test_transport.py
```

For the AirScan bridge integration tests (Python plus Pillow, development only):

```sh
./build-macos-airscan.sh
python3 test_airscan.py
DCP_AIRSCAN_ARCH=x86_64 python3 test_airscan.py # Rosetta required on Apple Silicon
```

These tests disable discovery and contact only a simulated scanner at localhost.
They check exact image crops, grayscale, one-bit text, JPEG and PNG output, busy
jobs, cancellation, disconnected requests, validation and shutdown. Both CPU
slices pass on the development Mac.

Python is only a development dependency. The local simulated scanner checks exact
image bytes under fragmented transfers, embedded end-marker-valued pixels,
malformed capabilities, incomplete transfer rejection, wrong row-size rejection,
cancellation, offset-region coordinates and output preservation. Colour checks
include primary and neutral RGB vectors, clipping, incorrect plane order, missing
planes and private PNG output with RGB/DPI metadata.

Verified on this device:

| Check | Result |
|---|---|
| Apple Silicon, grayscale 100 dpi | 816 x 1145 pixels, complete page-end |
| Apple Silicon, grayscale 300 dpi | 2480 x 3435 pixels, complete page-end |
| Apple Silicon, colour 300 dpi | 2480 x 3435 RGB pixels, complete page-end; channel order checked against original and colours visually confirmed by user |
| Native colour PNG metadata | 300 dpi in both axes, sRGB profile, private file mode 0600 |
| 300 dpi offset region | 800 x 600 pixels, correct content and position |
| Native PNG metadata | 300 dpi in both axes, grayscale colour space |
| Physical cancellation after first row | Client exits without output; immediate reuse can fail while the device recovers |
| Intel macOS client | Builds and passes grayscale/colour transport tests under Rosetta |
| Universal macOS static core | Both architectures build and are present in the archive |
| Native Image Capture | Colour overview, 300 dpi colour export and 100 dpi grayscale export verified |
| Native multipage PDF | Two pages, correct physical dimensions, RGB then grayscale image data |
| AirScan bridge | Full loopback integration suite passes on ARM64 and x86_64 under Rosetta |

150 dpi grayscale is accepted by the capability query but has not had a physical
acquisition check. Colour at 100 dpi was acquired in a protocol experiment and at
300 dpi through the native core. A 150 dpi colour acquisition is not yet checked. No physical Intel Mac, Linux build or Linux GUI check has been performed. The full-bed height discrepancy is documented rather than
hidden by padding; exact edge coverage still needs investigation.
The colour test object was a 30 x 30 cm printed canvas. It exceeds the scanner
bed, so the scan intentionally contains only the portion on the glass; it is not
a complete reproduction of the square artwork.

Immediate capability queries following physical cancellation have timed out or
returned an unexpected response. A later query succeeded. Device recovery timing
and cancellation acknowledgements still need investigation before native UI use.

## Observations and provenance

The tested standard eSCL capabilities URL returns 404; no standard eSCL support
has been established. The old software's discovery/push-scan configuration is not
required for this successful computer-initiated session. The cause of historical
wireless-scanning failures has not been established.

See [protocol notes](PROTOCOL.md). Scans and raw experiments remain local in
`captures/` and `research/`, both ignored by Git. Do not commit private documents
or machine logs.

Own source and documentation are MIT licensed. Protocol names and framing were
researched using the GPL-licensed [brscan project](https://github.com/dmikushin/brscan),
then confirmed against the actual DCP-J315W's responses. This core is independently
written; no code, decompiled algorithm, decoder or calibration file from that
project is included or linked. Its code retains its GPL licence. This is not a
formal separated-team clean-room effort.
