# Changelog

## 0.0.2 — development packages

- Record Fedora 41 x86_64 hardware confirmation through GNOME Document Scanner:
  automatic default device selection, good-looking 300 dpi colour, and multipage
  PDF export.
- Build portable glibc libraries on an AlmaLinux 9 baseline and separate native
  musl libraries for Alpine.
- Add Debian, Fedora/Red Hat, Arch, openSUSE and Alpine tarball flavours with Bash
  SANE dependency installers, runtime metadata and CPU/libc compatibility checks.
- Add verification workflows for Linux distribution runtimes and both macOS CPUs.
- Publish the separate MIT-licensed scanner source repository. All eight initial
  fixed CI jobs pass; Linux package archives/checksums are available as artifacts.

## 0.0.1 — initial development implementation

- Independent C11 Wi-Fi scanner core, grayscale/RGB acquisition and cancellation.
- Native macOS Image Capture integration using a local-only AirScan bridge.
- Linux SANE backend and Bash installation/removal scripts.
- Verified macOS colour/grayscale scans and multipage PDF; Linux ARM64 and x86_64
  loopback SANE tests and initial Fedora hardware acquisition.

These versions are development snapshots in the public source repository. No
tagged scanner release has been published yet. Hardware verification is limited to the DCP-J315W, one Apple
Silicon Mac and one Fedora x86_64 laptop; simulation checks are documented separately.
