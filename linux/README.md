# Linux wireless scanner backend

An independent MIT-licensed SANE backend for the Brother DCP-J315W. It uses the
same C transport and colour conversion as the native macOS adapter. It is separate
from the printing driver and does not change CUPS queues.

This is a development preview. Fedora 41 x86_64 and ARM64 builds pass the
installer and stock SANE/scanimage simulation suites. A physical scan from Linux
and a Linux desktop application check are still pending.

## Fedora installation

Install the SANE runtime and your preferred scanner application:

```sh
sudo dnf install sane-backends sane-backends-libs simple-scan
```

Extract the Linux package for your CPU, enter the extracted folder, then run:

```sh
sudo ./install.sh --address PRINTER_IPV4
scanimage -L
```

Replace `PRINTER_IPV4` with the printer's numeric Wi-Fi address. Restart GNOME
Document Scanner (`simple-scan`) or KDE Skanpage after installation and select
**DCP-J315W (Open Scanner)**. Both applications use SANE; their PDF export and
multipage assembly belong to the application. This backend acquires one flatbed
page per scan. There is no automatic document feeder.

`--libdir /usr/lib64` can override installation path detection (Fedora x86_64).
Debian commonly uses `/usr/lib/x86_64-linux-gnu` or `/usr/lib/aarch64-linux-gnu`;
Arch and Alpine commonly use `/usr/lib`. The package must match both the CPU and
C runtime: a glibc build is not an Alpine/musl package. Distribution packages and
physical tests beyond Fedora are future work.

The installer writes only this backend's library, `/etc/sane.d/dcpj315w.conf` and
`/etc/sane.d/dll.d/dcpj315w`. Existing backends and CUPS settings are preserved.
Rerunning it replaces this backend's address configuration; use one numeric IPv4
address per line if configuring several printers manually. Discovery lists the
configured devices without contacting them; offline devices fail when scanned.
Use `DCP_SCAN_DEBUG=1 scanimage ...` to print transport errors to stderr.

## First scan

Put a non-sensitive page on the glass and close the lid. Check the device list:

```sh
scanimage -L
scanimage -d dcpj315w:PRINTER_IPV4 --help
```

For a colour scan, choose a new filename:

```sh
(umask 077; set -o noclobber; scanimage -d dcpj315w:PRINTER_IPV4 \
  --mode Color --resolution 300 --format=png > first-scan.png)
```

The shell creates that output file before scanning; a failed scan may leave an
empty file. The backend never returns an incomplete acquired image. Desktop apps
control their own file permissions and output recovery.

## Build from source

Fedora:

```sh
sudo dnf install gcc sane-backends-devel sane-backends sane-backends-libs tar gzip
./build-linux-sane.sh
./package-linux-sane.sh
```

On Debian/Ubuntu the build dependencies are `build-essential libsane-dev`; on Arch
use `base-devel sane`. No Python is needed to build, install, or scan. Tests use
Python's standard library only. The backend links only the system C runtime and
compiles against SANE's public headers; it does not link or copy a vendor driver.
The shared library is created in `build/linux-sane/`, and the tarball in
`build/packages/`. For a direct source install, extract that tarball and use its
installer. Override `CC`, `CPPFLAGS`, `CFLAGS`, `LDFLAGS`, `OUTPUT_DIR` or
`PACKAGE_DIR` as needed for a build system.

## Options and limitations

- `Color` (RGB8), `Gray` (8-bit), `Lineart` (one-bit, threshold 128).
- 100 and 300 dpi; preview requests use 100 dpi. 150 dpi has only been queried on
  hardware and is deliberately not offered by this adapter yet.
- Millimetre scan rectangles. The adapter expands horizontal wire requests to
  16-pixel boundaries and crops back to the requested pixel area.
- Full usable bed: approximately 210 x 291 mm at 300 dpi; the rightmost few
  millimetres are unavailable in the aligned 100 dpi mode. This uses observed
  limits, not an A4 size promise. Returned height always follows actual page-end.
- Acquisition completes inside `sane_start`; SANE frontends normally perform
  this on a worker. Afterwards `sane_read` supplies the completed image in chunks.
  No nonblocking/select-file-descriptor mode or incremental preview is offered.
- Signal-safe cancellation sets a lock-free atomic flag. The core sends a bounded
  reset and drains pending records. Physical recovery after cancellation can take
  longer than the call, as on macOS. A second active scan within the same process
  is rejected; separate applications/computers must coordinate access themselves.
- Direct IPv4 Wi-Fi only. No USB, automatic address discovery, 600 dpi, OCR,
  measured ICC calibration, or physical ink/paper status reporting.

## Uninstall

Use the same library directory selected at installation:

```sh
sudo ./uninstall.sh --libdir /usr/lib64
```

This preserves scanned documents and `/etc/sane.d/dcpj315w.conf`.

## Developer verification

Install the backend in an isolated Linux test environment, then run:

```sh
python3 test_sane.py
```

This uses stock libSANE and `scanimage` against a simulated scanner on loopback
port 54921. It checks discovery, colour vectors, grayscale, odd-width one-bit
packing, offset geometry, preview, short pages, incomplete transfer, cancellation,
busy handling and real frontend export. It does not activate a physical printer.

Public interface reference: [SANE API standard](https://sane-project.gitlab.io/standard/api.html).
Created with LLM-assisted coding and controlled experiments. I hope this helps
keep these scanners useful for a while longer.
