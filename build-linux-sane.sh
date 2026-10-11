#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")" && pwd)
if [[ $(uname -s) != Linux ]]; then
  echo 'Build the SANE backend on Linux (SANE development headers are required).' >&2
  exit 1
fi
out=${OUTPUT_DIR:-"$root/build/linux-sane"}
mkdir -p "$out"
tmp=$(mktemp "$out/.backend.XXXXXX")
trap 'rm -f "$tmp"' EXIT
# Intentional word splitting allows ordinary compiler flags from build systems.
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -fPIC -fvisibility=hidden \
  ${CPPFLAGS:-} ${CFLAGS:-} -shared \
  "$root/linux/sane-dcpj315w.c" "$root/src/scanner.c" \
  ${LDFLAGS:-} -Wl,--no-undefined -Wl,-soname,libsane-dcpj315w.so.1 -o "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$out/libsane-dcpj315w.so.1.0.0"
ln -sfn libsane-dcpj315w.so.1.0.0 "$out/libsane-dcpj315w.so.1"
ln -sfn libsane-dcpj315w.so.1 "$out/libsane-dcpj315w.so"
printf 'Built %s\n' "$out/libsane-dcpj315w.so.1.0.0"
