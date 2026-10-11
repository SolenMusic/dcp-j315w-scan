#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $(uname -s) == Linux ]] || { echo 'Package on Linux.' >&2; exit 1; }
version=$(cat "$root/VERSION")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
flavour=${1:-generic}
case $flavour in generic|debian|fedora|arch|opensuse|alpine|raspberrypi) ;; *) echo 'Unknown distribution flavour.' >&2; exit 1;; esac
out=${PACKAGE_DIR:-"$root/build/packages"}
binary=${OUTPUT_DIR:-"$root/build/linux-sane"}/libsane-dcpj315w.so.1.0.0
[[ -f $binary ]] || { echo 'Run ./build-linux-sane.sh first.' >&2; exit 1; }
. "$root/linux/linux_arch.sh"
arch=$(dcp_elf_arch "$binary")
command -v readelf >/dev/null || { echo 'Install binutils for packaging.' >&2; exit 1; }
dependencies=$(readelf -d "$binary")
if [[ $dependencies == *libc.musl-* ]]; then libc=musl
elif [[ $dependencies == *libc.so.6* ]]; then libc=glibc
else echo 'Cannot identify the binary C runtime.' >&2; exit 1; fi
if [[ $flavour == alpine && $libc != musl ]] || [[ $flavour != alpine && $libc == musl ]]; then
  echo 'The binary C runtime does not match this distribution bundle.' >&2; exit 1
fi
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
name=dcp-j315w-scan-linux-$flavour-$arch-$version
mkdir "$stage/$name"
install -m 755 "$binary" "$root/linux/install.sh" "$root/linux/uninstall.sh" "$root/linux/install-deps.sh" "$root/linux/linux_arch.sh" "$stage/$name/"
install -m 644 "$root/LICENSE" "$root/linux/README.md" "$root/CHANGELOG.md" "$root/VERSION" "$stage/$name/"
printf '%s\n' "$flavour" > "$stage/$name/BUNDLE_FLAVOUR"
printf '%s\n' "$libc" > "$stage/$name/BUNDLE_LIBC"
printf '%s\n' "$arch" > "$stage/$name/BUNDLE_ARCH"
if [[ $libc == glibc ]]; then
  readelf --version-info "$binary" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1 | sed 's/^GLIBC_//' > "$stage/$name/MIN_GLIBC"
fi
tar -czf "$out/$name.tar.gz" -C "$stage" "$name"
printf 'Created %s\n' "$out/$name.tar.gz"
