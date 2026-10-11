#!/bin/bash
# SPDX-License-Identifier: MIT
# Uses credentials already stored in the user's keychain; never exports them.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: ./notarize-macos-scan.sh KEYCHAIN_PROFILE' >&2; exit 1; }
root=$(cd -- "$(dirname -- "$0")" && pwd)
app="$root/build/DCPJ315WAirScanBridge.app"
version=$(cat "$root/VERSION")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
codesign --verify --strict "$app"
ditto -c -k --keepParent "$app" "$work/scanner.zip"
xcrun notarytool submit "$work/scanner.zip" --keychain-profile "$1" --output-format plist > "$work/result.plist"
id=$(/usr/libexec/PlistBuddy -c 'Print :id' "$work/result.plist")
printf '%s\n' "$id" > "$root/build/notary-$version.id"
echo "Notarization submission: $id"
if ! xcrun notarytool wait "$id" --keychain-profile "$1" --timeout 60s --output-format plist > "$work/result.plist"; then
  echo "Resume this submission with: xcrun notarytool wait $id --keychain-profile PROFILE; do not resubmit." >&2
  exit 1
fi
status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$work/result.plist")
[[ $status == Accepted ]] || { echo "Notarization status: $status; do not publish." >&2; exit 1; }
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --verbose --type execute "$app"
