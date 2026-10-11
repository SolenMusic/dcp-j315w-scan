# Linux wireless scanner backend

An independent MIT-licensed SANE backend for the Brother DCP-J315W. It uses the
same C transport and colour conversion as the native macOS adapter. This project
is separate from printing and has no CUPS dependency.

## What has been checked

On a Fedora 41 x86_64 laptop, GNOME Document Scanner selected the scanner by
default and acquired an image over Wi-Fi. The user confirmed good-looking colour
at 300 dpi and successful multipage PDF export. Colour quality is a visual check,
not a measured ICC calibration.

The portable glibc library is built on AlmaLinux 9 and checked through stock
SANE/scanimage on Debian 12 and Fedora 41. Separate Alpine 3.24 libraries use musl.
CPU and runtime simulation checks are recorded in the main README; only Fedora
x86_64 has a physical Linux scan confirmation. GitHub CI also verifies the
openSUSE runtime on both CPUs, Arch's runtime on x86_64, and the Nix source recipe
on both CPUs. Scanner v0.1.1 adds the documented 32-bit CPU/ABI combinations.

## Choose a package

Packages are tarballs with Bash installers, rather than native .deb/.rpm/.apk
packages. Filenames contain the distribution flavour, CPU and version:

```text
dcp-j315w-scan-linux-FLAVOUR-ARCH-VERSION.tar.gz
```

| Flavour | C runtime | SANE packages installed by install-deps.sh |
|---|---|---|
| debian (Debian/Ubuntu) | glibc | libsane1, sane-utils |
| fedora (Fedora/Red Hat family) | glibc | sane-backends, sane-backends-libs |
| arch | glibc | sane |
| opensuse | glibc | sane-backends |
| alpine | musl | sane, sane-utils, bash |
| generic | glibc; distribution detected locally | Packages for that distribution |

Choose x86_64 for a 64-bit Intel/AMD laptop or arm64 for AArch64.
32-bit x86, ARMv6 and ARMv7 downloads are listed in the main README; ARMv6
hard-float (Raspberry Pi OS/Alpine) and soft-float (Debian armel) are distinct. The Alpine package is
built with musl and cannot be substituted with a glibc package. The installer
rejects mismatched CPUs, C runtimes and glibc versions older than the library's
recorded symbol requirements. Containers establish loader/install compatibility;
they do not establish that every desktop application or physical machine works.

Arch x86_64 has a runtime check in CI. The arm64 Arch flavour is a convenience
bundle for compatible Arch-derived systems; upstream Arch's official x86_64
container does not verify Arch ARM. Check your system's SANE package separately.
For NixOS, use [the declarative source recipe](../nix/README.md) in the source
checkout, rather than this installer.

## Installation

Extract the package for your distribution and CPU, then enter its folder. Install
SANE dependencies with your distribution's package manager, or run:

```sh
sudo ./install-deps.sh
sudo ./install.sh --address PRINTER_IPV4
scanimage -L
```

Run installation as root via sudo, doas, or a root shell. Alpine needs Bash before
these scripts can run: `apk add bash` from a root shell. `install-deps.sh --dry-run`
prints the planned runtime packages without changing the system. Arch uses the
supported `pacman -Syu` full upgrade, with its normal confirmation prompt.

Replace `PRINTER_IPV4` with the printer's numeric Wi-Fi address. `scanimage -L`
**lists devices only; it does not scan**. Restart a native desktop scanner app
and select **DCP-J315W (Open Scanner)**. On Fedora, install Document Scanner with
`sudo dnf install simple-scan`. GNOME Document Scanner and KDE Skanpage use SANE;
PDF export and multipage assembly belong to the application. This backend acquires
one flatbed page per scan; it has no automatic document feeder.

Use a distribution-installed scanner application for the first test. A Flatpak
application may use a scanner library inside its sandbox and may not see a host
SANE backend. Installing the backend does not modify that sandbox.

`--libdir /usr/lib64` overrides path detection (Fedora x86_64). Debian commonly
uses `/usr/lib/x86_64-linux-gnu` or `/usr/lib/aarch64-linux-gnu`; Arch and Alpine use
`/usr/lib`. The installer prints the chosen directory for later removal.

Only this backend's library, `/etc/sane.d/dcpj315w.conf` and
`/etc/sane.d/dll.d/dcpj315w` are installed. Existing backends remain in place.
Rerunning the installer replaces this backend's address configuration; use one
numeric IPv4 address per line if configuring several printers manually. Discovery
lists configured devices without contacting them; offline devices fail when
scanned. No scanner daemon or service needs to be enabled.

## First scan

Put a non-sensitive page on the glass and close the lid. Use Document Scanner for
an ordinary colour document at 300 dpi, or use a new output filename in Terminal:

```sh
(umask 077; set -o noclobber; DCP_SCAN_DEBUG=1 \
  scanimage -d dcpj315w:PRINTER_IPV4 \
  --mode Color --resolution 300 --format=png > first-scan.png)
```

The shell creates the output file before scanning; a failure may leave an empty
file. The backend never returns an incomplete acquired image. Desktop apps
control their own file permissions and output recovery. `DCP_SCAN_DEBUG=1` prints
transport errors to stderr. Keep diagnostic logs and scanned documents private.

## Build from source

| Distribution | Build packages |
|---|---|
| Fedora/Red Hat | gcc, sane-backends-devel, binutils, bash, tar, gzip |
| Debian/Ubuntu | build-essential, libsane-dev, binutils, bash, tar, gzip |
| Arch | base-devel, sane, binutils |
| openSUSE | gcc, sane-backends-devel, binutils, bash, tar, gzip |
| Alpine | build-base, sane-dev, binutils, bash, tar, gzip |

From the source checkout:

```sh
./build-linux-sane.sh
./package-linux-sane.sh generic
# Or specify debian, fedora, arch, opensuse, or alpine.
```

Build Alpine inside Alpine and use `./package-linux-sane.sh alpine`; its package
must contain a musl library. The packager
rejects a glibc binary in an Alpine bundle and a musl binary in the other distro
bundles. The library is created in `build/linux-sane/`, tarballs in
`build/packages/`. For source installation, extract that tarball and use its
installer. `CC`, `CPPFLAGS`, `CFLAGS`, `LDFLAGS`, `OUTPUT_DIR` and `PACKAGE_DIR` can
be overridden for a build system. Package generation needs binutils' `readelf`.
No Python is needed to build, install, or scan.

The backend compiles against SANE's public headers and links only the system C
runtime. It does not link or copy a vendor driver. For downloadable glibc packages,
`Dockerfile.linux-sane-release` provides a conservative AlmaLinux 9 build baseline.
`Dockerfile.alpine-sane-release` builds native musl libraries separately.

## Options and limitations

- `Color` (RGB8), `Gray` (8-bit), `Lineart` (one-bit, threshold 128).
- 100 and 300 dpi; preview uses 100 dpi. 150 dpi has only been queried on hardware
  and is deliberately not offered by this adapter yet.
- Millimetre rectangles. Horizontal wire requests expand to 16-pixel boundaries
  and are cropped back to the requested pixels.
- Full usable bed: approximately 210 x 291 mm at 300 dpi. The rightmost few
  millimetres are unavailable in aligned 100 dpi mode. These are observed limits,
  not an A4 size promise. Returned height follows the actual page-end marker.
- Acquisition completes inside `sane_start`; frontends normally run this on a
  worker. `sane_read` then supplies the complete image in chunks. Nonblocking,
  select-file-descriptor mode and incremental preview are not implemented.
- Signal-safe cancellation sets a lock-free atomic flag. The core sends a bounded
  reset and drains pending records. Physical recovery may take longer than the
  call. A second active scan in the process is rejected; separate applications or
  computers must coordinate access themselves.
- Direct IPv4 Wi-Fi only. No USB, automatic address discovery, 600 dpi, measured
  ICC calibration, or continuous device health reporting. OCR, if available, is a
  desktop application function and is not part of this backend.

## Uninstall

Use the library directory printed at installation:

```sh
sudo ./uninstall.sh --libdir /usr/lib64
```

This preserves scanned documents and `/etc/sane.d/dcpj315w.conf`.

## Developer verification

`test-linux-sane.sh` builds, packages and installs the backend before running
`test_linux_install.py` and `test_sane.py`. Run it only in a disposable container.
Tests use Python's standard library, stock libSANE and scanimage, with a simulated
scanner on loopback port 54921. No physical printer is activated. Checks cover
colour vectors, grayscale, odd-width text, crops, preview, short pages, failed
transfers, cancellation, busy handling and frontend export. Installer checks
cover preservation, permissions, addresses, symlinks and CPU/libc mismatches.

`DCP_SANE_SKIP_BUILD=1` makes runtime tests use a previously built library. This
checks portability without silently recompiling against the newer distribution.
`BUNDLE_FLAVOUR` selects the package flavour in the test runner. Linux and macOS
workflows are in `.github/workflows` and run on pushes to the
[scanner repository](https://github.com/SolenMusic/dcp-j315w-scan/actions).

Public interface reference: [SANE API standard](https://sane-project.gitlab.io/standard/api.html).
Created with LLM-assisted coding and controlled experiments. I hope this helps
keep these scanners useful for a while longer.
