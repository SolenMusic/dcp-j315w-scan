# Native Linux packages

Binary downloads include real `.deb`, `.rpm`, Arch `.pkg.tar.zst` and Alpine
`.apk` packages. Tarballs remain an alternative for manual installation.
Packages own the driver files; do not run a tarball installer/uninstaller over
a package-managed installation. Installing requires no Python, Ruby or compiler.

| System | Install a downloaded package | Remove |
| --- | --- | --- |
| Debian / Ubuntu / Raspberry Pi OS | `sudo apt install ./PACKAGE.deb` | `sudo apt remove dcp-j315w-cups` (or `dcp-j315w-scan`) |
| Fedora / Red Hat compatible | `sudo dnf install ./PACKAGE.rpm` | `sudo dnf remove dcp-j315w-cups` (or `dcp-j315w-scan`) |
| openSUSE | `sudo zypper install ./PACKAGE.rpm` | `sudo zypper remove dcp-j315w-cups` (or `dcp-j315w-scan`) |
| Arch / compatible ARM derivatives | `sudo pacman -U ./PACKAGE.pkg.tar.zst` | `sudo pacman -R dcp-j315w-cups` (or `dcp-j315w-scan`) |
| Alpine 3.24+ | `sudo apk add --allow-untrusted ./PACKAGE.apk` | `sudo apk del dcp-j315w-cups` (or `dcp-j315w-scan`) |

These are local GitHub downloads, not packages in an official distro repository.
Check the release's SHA256SUMS before installation. RPM and Arch packages are
unsigned; your package manager may ask you to accept the local package. Alpine
downloads use native APKv3 (apk-tools 3, Alpine 3.24+) and are unsigned, hence the
explicit local-file `--allow-untrusted` option. This does not change repository
signature settings. No automatic update repository is configured.

After installing the printing package, start CUPS using your distro's service
manager, then configure a network queue:

On minimal Alpine systems, the administrator may need membership in `lpadmin`
for CUPS queue configuration. For root setup, run `addgroup root lpadmin` from a
root shell first. This is ordinary CUPS administration setup, not a scanner
requirement.

```sh
sudo dcp-j315w-print-configure --address PRINTER_ADDRESS
# Alternatively, Bonjour:
sudo dcp-j315w-print-configure --discover
```

The PPD is also available in the normal CUPS model directory for desktop printer
setup. Existing queues and their settings are preserved during package upgrades.
The configure command changes CUPS queue settings, not package-owned files.
Before removing the printing package, remove its queues (finish/cancel pending
jobs first). Repeat for additional queues using `--queue NAME`:

```sh
sudo dcp-j315w-print-remove-queue
```

Package removal itself leaves CUPS's queues untouched, as with other printer
driver packages. A retained queue cannot print until its driver is reinstalled.
Unrelated printers and jobs are never removed by our scripts.

After installing the scanning package:

```sh
sudo dcp-j315w-scan-configure --address PRINTER_IPV4
scanimage -L
```

Restart GNOME Document Scanner or KDE Skanpage. The SANE configuration is marked
as a configuration file; normal upgrades preserve edits. Removal follows the
distro's usual rules: Debian retains configuration until purge, RPM may save it
as `.rpmsave`, Arch as `.pacsave`, and Alpine preserves modified `/etc` files.
Scanned documents are never part of package removal. Printing and scanning have
separate packages; installing one does not require the other.

Download the correct CPU/libc flavour. Raspberry Pi OS ARMv6 hard-float and
Debian ARMv6 soft-float are different builds. Debian ARMv7 packages also carry an
ARMv6 rejection check because both hard-float variants have the `armhf` package
architecture label. ARM64 Arch packages target compatible ARM derivatives;
upstream Arch is x86_64. No physical tests have been performed on older boards.

## Building packages

`build-native.py` is a development tool. It stages files from a verified existing
binary release, checks the ELF CPU/libc, and uses FPM 1.17.0 for Debian, RPM and
Arch metadata. RPM uses `rpmbuild`; Arch includes `.PKGINFO`, `.MTREE` and backup
metadata. Alpine uses its own `apk mkpkg`. Source build instructions remain in
the main README. Build the appropriate Linux release bundle first, or download
and checksum-verify it; extract the bundle to `build/input/BUNDLE`.

```sh
docker build -f packaging/Dockerfile -t dcp-native-builder .
docker run --rm -v "$PWD:/source" dcp-native-builder \
  python3 packaging/build-native.py debian x86_64 build/input/BUNDLE
# For Alpine/musl inputs use packaging/Dockerfile.alpine instead.
```

Packages are emitted under `build/native`. Use `--revision 2` for a subsequent
packaging revision of the same driver version. The packaging workflow tests
dependency resolution, file ownership, upgrades and removal in disposable distro
containers. It never contacts a physical printer/scanner. CPU emulation tests
do not replace real hardware checks.
