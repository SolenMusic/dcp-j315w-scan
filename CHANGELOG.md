# Changelog

## 0.1.1

- Add separately validated 32-bit ARMv6 hard/soft-float, ARMv7 and x86 Linux targets.
- Add Debian, Raspberry Pi OS/Raspbian and Alpine emulated build/test jobs.
- Validate ELF class, CPU ISA and ARM float ABI before installing.
- Preserve existing macOS and 64-bit Linux support.

## 0.1.0 — first public release

- Wi-Fi scanning for the Brother DCP-J315W through native macOS Image Capture
  and Linux SANE applications.
- User-confirmed 300 dpi colour and multipage PDF export on macOS and Fedora.
- Universal Developer ID-signed/notarized macOS helper with a per-user Bash installer.
- Linux x86_64/ARM64 downloads for Debian, Fedora, Arch, openSUSE and Alpine/musl;
  a declarative NixOS recipe.
- Clear printing/scanning support tables and links between the companion projects.
- USB/direct wired connections remain unimplemented.

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

Versions before 0.1.0 were development snapshots. Hardware verification is limited to the DCP-J315W, one Apple
Silicon Mac and one Fedora x86_64 laptop; simulation checks are documented separately.
