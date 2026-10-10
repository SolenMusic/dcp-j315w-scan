#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${OUTPUT:-"$root/dcp-j315w-scan"}
temp=$(mktemp "${output}.XXXXXX")
trap 'rm -f "$temp"' 0 HUP INT TERM
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror ${CFLAGS:-} \
  "$root/dcp-j315w-scan.c" ${LDFLAGS:-} -o "$temp"
if [ "$(uname -s)" = Darwin ]; then
  codesign --force --sign - --identifier dcp-j315w-scan.client "$temp"
  codesign --verify --strict "$temp"
fi
chmod 755 "$temp"
mv -f "$temp" "$output"
file "$output"
