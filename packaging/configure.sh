#!/bin/bash
# SPDX-License-Identifier: MIT
# Configure a package-managed backend without copying driver files.
set -euo pipefail
if [[ $# != 2 || $1 != --address ]]; then
  echo 'Usage: sudo dcp-j315w-scan-configure --address PRINTER_IPV4' >&2
  exit 1
fi
[[ $EUID == 0 ]] || { echo 'Use sudo.' >&2; exit 1; }
address=$2
[[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 1
IFS=. read -r -a octets <<< "$address"
for octet in "${octets[@]}"; do
  [[ $octet == 0 || $octet != 0* ]] && ((10#$octet <= 255)) || exit 1
done
conf=/etc/sane.d/dcpj315w.conf
[[ ! -L $conf ]] || { echo 'Refusing symlink configuration.' >&2; exit 1; }
tmp=$(mktemp /etc/sane.d/.dcpj315w.XXXXXX)
trap 'rm -f "$tmp"' EXIT
printf '# DCP-J315W Open Scanner; one numeric IPv4 address per line.\n%s\n' "$address" > "$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$conf"
if command -v restorecon >/dev/null; then restorecon "$conf"; fi
echo 'Scanner address saved. Restart your scanning application.'
