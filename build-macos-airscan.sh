#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="$root/build/DCPJ315WAirScanBridge.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/macos/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.dcpj315w.scan.airscan' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable DCPJ315WAirScanBridge' "$app/Contents/Info.plist"
cp "$root/macos/ScannerCapabilities.xml" "$app/Contents/Resources/"
for cpu in arm64 x86_64; do
  xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -arch "$cpu" -mmacosx-version-min=11.0 \
    -c "$root/src/scanner.c" -o "$root/build/airscan-core-$cpu.o"
  xcrun clang -std=c11 -fobjc-arc -O2 -Wall -Wextra -Werror -arch "$cpu" -mmacosx-version-min=11.0 \
    "$root/macos/airscan-bridge.m" "$root/build/airscan-core-$cpu.o" \
    -framework Foundation -framework ImageIO -framework CoreGraphics \
    -o "$root/build/airscan-bridge-$cpu"
done
binary_temp=$(mktemp "$app/Contents/MacOS/.DCPJ315WAirScanBridge.XXXXXX")
trap 'rm -f "$binary_temp"' EXIT HUP INT TERM
xcrun lipo -create "$root/build/airscan-bridge-arm64" "$root/build/airscan-bridge-x86_64" -output "$binary_temp"
chmod 755 "$binary_temp"
mv -f "$binary_temp" "$app/Contents/MacOS/DCPJ315WAirScanBridge"
for cpu in arm64 x86_64; do
  xcrun lipo "$app/Contents/MacOS/DCPJ315WAirScanBridge" -verify_arch "$cpu"
done
codesign --force --sign - --identifier org.dcpj315w.scan.airscan "$app"
codesign --verify --strict "$app"
echo "$app"
