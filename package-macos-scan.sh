#!/bin/bash
# SPDX-License-Identifier: MIT
# Package the per-user scanner helper; a graphical combined installer is separate.
set -euo pipefail
export COPYFILE_DISABLE=1
root=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $(uname -s) == Darwin && $# == 0 ]] || { echo 'Usage on macOS: ./package-macos-scan.sh' >&2; exit 1; }
version=$(cat "$root/VERSION")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
app="$root/build/DCPJ315WAirScanBridge.app"
codesign --verify --strict "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose "$app"
for arch in arm64 x86_64; do lipo "$app/Contents/MacOS/DCPJ315WAirScanBridge" -verify_arch "$arch"; done
name=dcp-j315w-scan-macos-universal-$version
out=${PACKAGE_DIR:-"$root/build/packages"}
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$name/build" "$stage/$name/macos"
cp -RX "$app" "$stage/$name/build/"
cp -X "$root/install-macos-airscan.sh" "$root/uninstall-macos-airscan.sh" "$root/README.md" \
  "$root/LICENSE" "$root/CHANGELOG.md" "$root/VERSION" "$stage/$name/"
cp -X "$root/macos/README.md" "$stage/$name/macos/"
chmod 755 "$stage/$name/"*.sh
codesign --verify --strict "$stage/$name/build/DCPJ315WAirScanBridge.app"
xcrun stapler validate "$stage/$name/build/DCPJ315WAirScanBridge.app"
tar --uid 0 --gid 0 --uname root --gname wheel -czf "$out/$name.tar.gz" -C "$stage" "$name"
printf 'Created %s\n' "$out/$name.tar.gz"
