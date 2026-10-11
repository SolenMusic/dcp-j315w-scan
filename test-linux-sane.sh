#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run only inside a disposable Linux container: this installs a real SANE backend.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$root"
./build-linux-sane.sh
./package-linux-sane.sh
python3 test_linux_install.py
case $(uname -m) in x86_64) arch=x86_64;; aarch64|arm64) arch=arm64;; *) exit 1;; esac
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
tar -xzf "${PACKAGE_DIR:-$root/build/packages}/dcp-j315w-scan-linux-$arch-0.0.1.tar.gz" -C "$stage"
"$stage/dcp-j315w-scan-linux-$arch-0.0.1/install.sh" --address 127.0.0.1
python3 test_sane.py
