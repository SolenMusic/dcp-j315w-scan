#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $(uname -s) == Linux ]] || { echo 'Package on Linux.' >&2; exit 1; }
case $(uname -m) in x86_64) arch=x86_64;; aarch64|arm64) arch=arm64;; *) exit 1;; esac
version=0.0.1
out=${PACKAGE_DIR:-"$root/build/packages"}
binary=${OUTPUT_DIR:-"$root/build/linux-sane"}/libsane-dcpj315w.so.1.0.0
[[ -f $binary ]] || { echo 'Run ./build-linux-sane.sh first.' >&2; exit 1; }
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
name=dcp-j315w-scan-linux-$arch-$version
mkdir "$stage/$name"
install -m 755 "$binary" "$root/linux/install.sh" "$root/linux/uninstall.sh" "$stage/$name/"
install -m 644 "$root/LICENSE" "$root/linux/README.md" "$stage/$name/"
tar -czf "$out/$name.tar.gz" -C "$stage" "$name"
printf 'Created %s\n' "$out/$name.tar.gz"
