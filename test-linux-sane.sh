#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run only inside a disposable Linux container: this installs a real SANE backend.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$root"
if [[ ${DCP_SANE_SKIP_BUILD:-0} != 1 ]]; then ./build-linux-sane.sh; fi
flavour=${BUNDLE_FLAVOUR:-generic}
./package-linux-sane.sh "$flavour"
python3 test_linux_install.py
. "$root/linux/linux_arch.sh"
arch=$(dcp_elf_arch "${OUTPUT_DIR:-$root/build/linux-sane}/libsane-dcpj315w.so.1.0.0")
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
version=$(cat VERSION)
name=dcp-j315w-scan-linux-$flavour-$arch-$version
tar -xzf "${PACKAGE_DIR:-$root/build/packages}/$name.tar.gz" -C "$stage"
"$stage/$name/install-deps.sh" --dry-run
"$stage/$name/install.sh" --address 127.0.0.1
python3 test_sane.py
