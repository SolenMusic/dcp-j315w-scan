# DCP-J315W Network Scanner

[![Linux SANE checks](https://github.com/SolenMusic/dcp-j315w-scan/actions/workflows/linux-sane.yml/badge.svg)](https://github.com/SolenMusic/dcp-j315w-scan/actions/workflows/linux-sane.yml)
[![macOS scanner checks](https://github.com/SolenMusic/dcp-j315w-scan/actions/workflows/macos-airscan.yml/badge.svg)](https://github.com/SolenMusic/dcp-j315w-scan/actions/workflows/macos-airscan.yml)

An independent native wireless-scanning core for the **Brother DCP-J315W**, with
native macOS Image Capture integration, a Linux SANE backend, and a command-line test client. This project is separate from the
[dcp-j315w-cups](https://github.com/SolenMusic/dcp-j315w-cups) printing repository and has no CUPS dependency.

Created with LLM-assisted coding and controlled experiments on a real printer.
The native Apple Silicon macOS client has acquired readable release notes over
Wi-Fi at both 100 and 300 dpi. I hope this helps keep these scanners useful for a
while longer.

## Printing and scanning support

Printing and scanning are separate projects for the same **Brother DCP-J315W**.
Install the component you need, or both for the full Wi-Fi printing/scanning setup.
Here, **wired** means a direct USB/cable connection to the printer.

| Capability | [CUPS printing driver](https://github.com/SolenMusic/dcp-j315w-cups) | [Network scanner driver](https://github.com/SolenMusic/dcp-j315w-scan) |
| --- | --- | --- |
| Wi-Fi printing | Supported | Not provided; use the printing driver |
| Wi-Fi scanning | Not provided; use the scanner driver | Supported |
| USB / wired printing | Not implemented | Not provided |
| USB / wired scanning | Not provided | Not implemented |
| Monochrome and colour printing | 300/600 dpi; black-only monochrome | Not provided |
| Colour, grayscale and text scanning | Not provided | 100/300 dpi in native apps; thresholded one-bit text |
| Multiple pages | CUPS pages, copies and collation | Multipage PDF assembled by the scanning application |
| macOS integration | Standard print dialogs via CUPS | Image Capture via a local AirScan helper |
| Linux integration | CUPS | SANE; confirmed in GNOME Document Scanner |
| Intel/x86_64 and ARM64 builds | macOS and Linux | macOS and Linux |
| Linux distro packaging | Debian/Ubuntu, Fedora/Red Hat, Arch, openSUSE, Alpine/musl; Nix recipe | Same distro flavours; Nix recipe |
| iOS / AirPrint | Not implemented | Not provided; macOS helper is local to that Mac |
| Windows | Not implemented | Not implemented |
| Other printer models | Unverified | Unverified |

Physical checks cover Wi-Fi printing and scanning on one Apple Silicon Mac and
one Fedora x86_64 laptop. Other CPU/distro combinations have automated checks;
these do not replace physical hardware tests. USB support is future work.

For a choice of printing, scanning or both on macOS, use the [combined graphical macOS installer](https://github.com/SolenMusic/dcp-j315w-installer/releases/tag/v0.1.0).
It includes the native DCP-J315W Setup configuration/removal app. Linux downloads
remain separate in the two component repositories.

## Download v0.1.0

The [v0.1.0 release](https://github.com/SolenMusic/dcp-j315w-scan/releases/tag/v0.1.0)
contains a universal macOS tarball with a Developer ID-signed, notarized and
stapled scanner helper, plus Linux tarballs with Bash installers.

| System | x86_64 | ARM64 |
| --- | --- | --- |
| macOS | [Universal download](https://github.com/SolenMusic/dcp-j315w-scan/releases/download/v0.1.0/dcp-j315w-scan-macos-universal-0.1.0.tar.gz) | Same universal download |
| Debian / Ubuntu | [Download](https://github.com/SolenMusic/dcp-j315w-scan/releases/download/v0.1.0/dcp-j315w-scan-linux-debian-x86_64-0.1.0.tar.gz) | [Download](https://github.com/SolenMusic/dcp-j315w-scan/releases/download/v0.1.0/dcp-j315w-scan-linux-debian-arm64-0.1.0.tar.gz) |
| Fedora / Red Hat | [Download](https://github.com/SolenMusic/dcp-j315w-scan/releases/download/v0.1.0/dcp-j315w-scan-linux-fedora-x86_64-0.1.0.tar.gz) | [Download](https://github.com/SolenMusic/dcp-j315w-scan/releases/download/v0.1.0/dcp-j315w-scan-linux-fedora-arm64-0.1.0.tar.gz) |
| Arch / compatible ARM derivatives | [Download](https://github.com/SolenMusic/dcp-j315w-scan/releases/download/v0.1.0/dcp-j315w-scan-linux-arch-x86_64-0.1.0.tar.gz) | [Download](https://github.com/SolenMusic/dcp-j315w-scan/releases/download/v0.1.0/dcp-j315w-scan-linux-arch-arm64-0.1.0.tar.gz) |
| openSUSE | [Download](https://github.com/SolenMusic/dcp-j315w-scan/releases/download/v0.1.0/dcp-j315w-scan-linux-opensuse-x86_64-0.1.0.tar.gz) | [Download](https://github.com/SolenMusic/dcp-j315w-scan/releases/download/v0.1.0/dcp-j315w-scan-linux-opensuse-arm64-0.1.0.tar.gz) |
| Alpine (musl) | [Download](https://github.com/SolenMusic/dcp-j315w-scan/releases/download/v0.1.0/dcp-j315w-scan-linux-alpine-x86_64-0.1.0.tar.gz) | [Download](https://github.com/SolenMusic/dcp-j315w-scan/releases/download/v0.1.0/dcp-j315w-scan-linux-alpine-arm64-0.1.0.tar.gz) |

NixOS uses the [source recipe](nix/README.md). Linux downloads are distro-specific
tarballs, not native .deb/.rpm/.apk packages. The Arch ARM bundle is not verified
against upstream Arch's x86_64-only container.

## Current scope

- Direct IPv4 connection to the scanner service on TCP port 54921.
- Grayscale and colour acquisition at 100/300 dpi. The core also accepts 150 dpi,
  but physical acquisition at that resolution has not been checked.
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

The Linux SANE backend exposes colour, grayscale, one-bit text, 100/300 dpi,
preview and rectangular scan areas to existing SANE applications. Linux packages
are available for installation; stock libSANE and `scanimage` have
passed simulated-scanner tests. On the Fedora 41 x86_64 laptop, GNOME Document
Scanner selected the scanner as its default device and successfully returned an
image over Wi-Fi. The user subsequently confirmed good-looking colour at 300 dpi
and successful multipage PDF export in Document Scanner. The command-line client is also available for development.

Automatic printer-address discovery, measured colour calibration, 600 dpi,
USB support remains to be implemented. A graphical combined macOS installer is
available in the companion installer repository. Native 300 dpi colour acquisition has been physically checked, and
channel order matches the supplied digital original. The user confirmed the scan
colours appear accurate against the printed canvas. No scanner ICC
profile or vendor tone table is included; PNG RGB is tagged as sRGB as a practical
output convention, not as a calibrated measurement of the scanner.

## Native macOS installation

For the release tarball, extract it, open Terminal in its folder, then run:

```sh
./install-macos-airscan.sh --address PRINTER_IPV4
```

No compiler or Python is required for a binary download. To build from source,
install Xcode or its command-line tools and run `./build-macos-airscan.sh` first.

Run as your normal user, without sudo. The installer copies the universal
Intel/Apple Silicon app under your user's Library/Application Support and starts
a LaunchAgent at login. Release helpers are Developer ID-signed and notarized;
source builds use an ad hoc signature unless a signing identity is supplied. The installer uses Bash and
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

## Linux installation and build

See [the Linux guide](linux/README.md) for Fedora installation, GNOME Document
Scanner/KDE Skanpage use, scan options and removal. Builds require a C compiler
and SANE development headers; installing and scanning do not require Python.

```sh
./build-linux-sane.sh
./package-linux-sane.sh generic
```

The generated tarball includes Bash installation and removal scripts. The backend
uses direct Wi-Fi TCP sessions, with no background daemon, AirScan bridge or CUPS
dependency on Linux. Address discovery is currently manual.

Distribution tarball flavours cover Debian/Ubuntu, Fedora/Red Hat, Arch and
openSUSE using a conservative glibc build. Alpine has a separate native musl
build. Each bundle has Bash dependency, installation and removal scripts, with
CPU/libc compatibility checks. A [NixOS source recipe](nix/README.md) uses the
system's declarative SANE backend integration. See [the changelog](CHANGELOG.md)
for release history.

## Older 32-bit Linux systems

These target combinations are built separately for printing and scanning:

| Download label | Distribution / ABI | Intended hardware |
| --- | --- | --- |
| `raspberrypi-armv6` | Raspberry Pi OS/Raspbian, ARMv6 hard-float | Pi 1, Zero/Zero W; also compatible later 32-bit Pi systems |
| `debian-armv6-softfloat` | Debian armel, ARMv6 soft-float | Pi 1 running Debian armel and similar ARMv6 systems |
| `debian-armv7` | Debian armhf, ARMv7 hard-float | Pi 2 and similar ARMv7 boards |
| `alpine-armv6` | Alpine armhf, ARMv6 hard-float | Pi 1 and Zero/W |
| `alpine-armv7` | Alpine armv7, ARMv7 hard-float | Pi 2 and similar boards |
| `debian-x86` / `alpine-x86` | 32-bit x86 | i686-class systems, subject to the distribution's CPU requirements |

**ARMv6 hard-float and soft-float packages are not interchangeable.** Debian's
standard armhf requires ARMv7; Raspberry Pi OS/Raspbian's armhf is built for
ARMv6 with VFPv2. Alpine calls its ARMv6 hard-float port armhf and its newer port
armv7. ELF CPU, class and float-ABI checks are performed before installation.
The scanner plugin must also match the SANE runtime word size.

The Debian baseline is Bookworm (12). Debian 13 no longer provides a normal
32-bit x86 installer/kernel and its remaining i386 packages target 64-bit CPUs
with SSE2. These downloads do not restore an operating system's own support.
Fedora/Red Hat, upstream Arch and openSUSE bundles are not advertised for these
32-bit targets; use a distribution that actually provides the required runtime.

Legacy CI uses QEMU user-mode emulation with ARM1176 for ARMv6 and Cortex-A7 for
ARMv7. Builds must pass the same protocol, application-library and installation
checks as other Linux targets. No physical Pi 1, Pi 2 or 32-bit PC has been tested
yet, and emulation does not measure real-board speed or memory pressure.
Full-colour 600 dpi printing can need approximately 100 MiB for the renderer's
RGB page alone, in addition to CUPS/PDF rendering. Older boards should start with
300 dpi document printing and 100 dpi scan previews.

Primary architecture references: [Debian ARM ports](https://www.debian.org/ports/arm/),
[Alpine downloads and Pi architecture mapping](https://www.alpinelinux.org/downloads/),
[Debian 13 i386 changes](https://www.debian.org/releases/trixie/release-notes/issues.en.html#reduced-support-for-i386).

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
signature on macOS. The CLI is a development tool; the macOS release packages
the native scanner helper. The networking
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
```

These tests disable discovery and contact only a simulated scanner at localhost.
They check exact image crops, grayscale, one-bit text, JPEG and PNG output, busy
jobs, cancellation, disconnected requests, validation and shutdown. Both CPU
slices have also been checked on their native GitHub macOS runners. The local
runner now enforces the Mac's native architecture; it rejects Intel-under-Rosetta
tests on Apple Silicon before launching a helper. Earlier forced Intel tests on
the development Mac could record the production app in macOS's Intel-app history
and trigger a macOS 28 Rosetta warning. The release helper is universal and the
installed development helper was sampled running native ARM64. This removes a
Rosetta requirement for ordinary scanning; full macOS 28 compatibility still
requires testing on that OS. See [Apple's Rosetta guidance](https://support.apple.com/en-gb/102527).

Linux checks use stock libSANE and `scanimage`, with Python's standard library
as the loopback scanner simulator. In a disposable Linux environment containing
the installed backend, run `python3 test_sane.py`; installer boundary checks are
in `test_linux_install.py`. `test-linux-sane.sh` builds/packages/installs the backend
and runs both suites, so run it only in an isolated container. Runtime tests can
use the existing library without recompiling against the newer distribution.
GitHub workflows cover both CPUs for glibc, musl, Nix and macOS, with separate
Debian/Fedora/openSUSE loaders and an x86_64 Arch runtime check.

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
| Fedora 41 SANE, x86_64 | Build, Bash installation/removal and stock libSANE/scanimage loopback suite pass in an emulated container |
| Fedora 41 SANE, ARM64 | Same suite passes in a native ARM64 Linux VM/container |
| Linux Wi-Fi capability query | x86_64 client receives valid 300 dpi colour capabilities from the physical scanner; no acquisition started |
| Fedora 41, GNOME Document Scanner | User confirmed default device selection, physical Wi-Fi acquisition, good-looking colour at 300 dpi and successful multipage PDF export |
| Portable glibc library | AlmaLinux 9 builds on both CPUs; Debian 12 loader/install suites pass on both CPUs; Fedora 41 suite passes on x86_64 |
| Alpine 3.24 musl | Independent x86_64 and ARM64 builds pass stock SANE, frontend export and installer suites in containers |
| Public GitHub build checks | All eight jobs pass: macOS, glibc, Alpine/musl and Nix on both CPUs; glibc jobs also check Debian/Fedora/openSUSE runtimes, plus Arch on x86_64 |

The first complete public checks ran against commit `103ccc4`:
[Linux and Nix results](https://github.com/SolenMusic/dcp-j315w-scan/actions/runs/38138955069),
[macOS results](https://github.com/SolenMusic/dcp-j315w-scan/actions/runs/38138955057).
Linux package archives and checksums are also available as workflow artifacts.
The macOS scanner release uses a signed/notarized helper with a per-user Bash
installer; the companion installer repository offers the combined graphical
printing/scanning installer and setup/removal app.

150 dpi grayscale is accepted by the capability query but has not had a physical
acquisition check. Colour at 100 dpi was acquired in a protocol experiment and at
300 dpi through the native core. A 150 dpi colour acquisition is not yet checked.
No physical Intel Mac or Linux ARM64 hardware scan has been checked. The first
Fedora x86_64 Document Scanner acquisition, 300 dpi colour and multipage PDF
export are user-confirmed. Colour quality is a visual assessment, not an ICC
calibration measurement. The full-bed height discrepancy is documented rather than
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
