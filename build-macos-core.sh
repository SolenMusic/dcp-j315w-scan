#!/bin/sh
# Build a reusable universal static core for an eventual ICA device module.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$(uname -s)" != Darwin ]; then
  echo 'This universal build requires the macOS SDK.' >&2
  exit 1
fi
out="$root/build/macos-core"
mkdir -p "$out"
for cpu in arm64 x86_64; do
  xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -arch "$cpu" \
    -mmacosx-version-min=11.0 -c "$root/src/scanner.c" -o "$out/scanner-$cpu.o"
  # Recreate the archive so no old members can survive an incremental build.
  rm -f "$out/libdcpscan-$cpu.a"
  xcrun ar rcs "$out/libdcpscan-$cpu.a" "$out/scanner-$cpu.o"
done
xcrun lipo -create "$out/libdcpscan-arm64.a" "$out/libdcpscan-x86_64.a" \
  -output "$out/libdcpscan.a"
for cpu in arm64 x86_64; do
  xcrun lipo "$out/libdcpscan.a" -verify_arch "$cpu"
done
cp "$root/src/scanner.h" "$out/scanner.h"
echo "Universal core: $out/libdcpscan.a"
