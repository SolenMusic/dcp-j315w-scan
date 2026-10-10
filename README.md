# DCP-J315W Network Scanner

An independent native wireless-scanning core for the **Brother DCP-J315W**, with
an initial command-line test client. This project is separate from the
`dcp-j315w-cups` printing repository and has no CUPS dependency.

Created with LLM-assisted coding and controlled experiments on a real printer.
The native Apple Silicon macOS client has acquired readable release notes over
Wi-Fi at both 100 and 300 dpi. I hope this helps keep these scanners useful for a
while longer.

## Current scope

- Direct IPv4 connection to the scanner service on TCP port 54921.
- Grayscale capabilities and acquisition at 100, 150 or 300 dpi.
- Full-bed scans and selectable rectangular regions, with bounded memory use.
- Native macOS PNG export with correct DPI metadata; portable 8-bit PGM export.
- Fragmented TCP transfer handling, strict record validation, a 180-second scan
  deadline, cancellation and progress callbacks.
- No partial image on transfer failure; output files are private and existing
  files are never overwritten. Existing paths are rejected before scanning.
- A reusable, synchronous C11 core without global state or UI dependencies, and
  a universal macOS static library build for Intel and Apple Silicon.

**Native Image Capture/Preview integration is the macOS target, but is not yet
implemented.** The command-line client exercises the core during development.
A Linux SANE backend is the later target for GNOME Document Scanner and KDE
Skanpage; no dedicated scanning GUI is planned.

Colour conversion, automatic discovery, calibrated tone reproduction, 600 dpi,
PDF export, device-module installation and Linux SANE integration remain to be
implemented. The scanner accepts a colour query and emits colour records, but
correct colour interpretation has not yet been verified.

## Build and use

From this project folder, with Xcode or its command-line tools installed:

```sh
./build.sh
./dcp-j315w-scan --info PRINTER_IPV4 --dpi 300
./dcp-j315w-scan --scan PRINTER_IPV4 result.png --dpi 300
./dcp-j315w-scan --scan PRINTER_IPV4 preview.pgm
./dcp-j315w-scan --scan PRINTER_IPV4 crop.png --dpi 300 --area 160,300,800,600
```

Replace `PRINTER_IPV4` with the printer's numeric network address. Put a document
on the glass and close the lid before scanning. The output filename must be new.
No administrator authentication or system installation is needed. Use Ctrl-C to
cancel. PNG export uses Apple's ImageIO; no Python or external image converter is
needed. The PNG records the chosen resolution in both axes.

The `--area` values are **x, y, width, height in pixels at the selected DPI**.
X and width must be multiples of 16; zero width/height means the remaining bed.
The CLI converts those dimensions to the protocol's absolute right/bottom bounds.
A full-bed scan can end before the reported maximum height; only the rows actually
returned with a confirmed device page-end marker are saved.

`build.sh` accepts `CC`, `CFLAGS`, `LDFLAGS` and `OUTPUT`, and applies an ad hoc
signature on macOS. This is not yet a packaged or notarized release. The networking
core uses only the system C runtime; the CLI additionally links Apple frameworks
for PNG export on macOS. Portable PGM remains available without those frameworks.

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

Python is only a development dependency. The local simulated scanner checks exact
image bytes under fragmented transfers, embedded end-marker-valued pixels,
malformed capabilities, incomplete transfer rejection, wrong row-size rejection,
cancellation, offset-region coordinates and output preservation.

Verified on this device:

| Check | Result |
|---|---|
| Apple Silicon, grayscale 100 dpi | 816 x 1145 pixels, complete page-end |
| Apple Silicon, grayscale 300 dpi | 2480 x 3435 pixels, complete page-end |
| 300 dpi offset region | 800 x 600 pixels, correct content and position |
| Native PNG metadata | 300 dpi in both axes, grayscale colour space |
| Physical cancellation after first row | Client exits without output; immediate reuse can fail while the device recovers |
| Intel macOS client | Builds and passes simulated transport tests under Rosetta |
| Universal macOS static core | Both architectures build and are present in the archive |

150 dpi is accepted by the capability query but has not had a physical acquisition
check. No physical Intel Mac, Linux build, Linux GUI or native Image Capture check
has been performed. The full-bed height discrepancy is documented rather than
hidden by padding; exact edge coverage still needs investigation.
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
