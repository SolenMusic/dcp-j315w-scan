#!/bin/bash
# SPDX-License-Identifier: MIT
# Packaging reuses the existing, tested release executable without recompiling.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: fetch-bundle.sh FLAVOUR ARCH' >&2; exit 1; }
version=$(cat VERSION)
if [[ -f src/scanner.c ]]; then
  repo=dcp-j315w-scan
  file=$repo-linux-$1-$2-$version.tar.gz
else
  repo=dcp-j315w-cups
  file=$repo-$version-linux-$1-$2.tar.gz
fi
mkdir -p build/native-input
gh release download "v$version" -R "SolenMusic/$repo" --pattern "$file" --pattern SHA256SUMS --dir build/native-input
cd build/native-input
awk -v file="$file" '$2 == file {print; found++} END {if (found != 1) exit 1}' SHA256SUMS > selected.sha256
sha256sum -c selected.sha256
mkdir bundle
tar -xzf "$file" -C bundle --strip-components=1
