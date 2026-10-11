#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")" && pwd)
address= libdir= destdir=
while (($#)); do
  case $1 in
    --address|--libdir|--destdir)
      (($# >= 2)) || { echo "Missing value for $1" >&2; exit 1; }
      case $1 in --address) address=$2;; --libdir) libdir=$2;; --destdir) destdir=$2;; esac
      shift 2;;
    *) echo 'Usage: install.sh --address IPV4 [--libdir /usr/lib64] [--destdir STAGING_DIRECTORY]' >&2; exit 1;;
  esac
done
[[ $(uname -s) == Linux ]] || { echo 'This installer requires Linux.' >&2; exit 1; }
[[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo 'Use a numeric IPv4 address.' >&2; exit 1; }
IFS=. read -r -a octets <<< "$address"
for octet in "${octets[@]}"; do
  [[ $octet == 0 || $octet != 0* ]] && ((10#$octet <= 255)) || { echo 'Invalid IPv4 address.' >&2; exit 1; }
done
if [[ -z $destdir && $EUID != 0 ]]; then echo 'Run the installer with sudo.' >&2; exit 1; fi
if [[ -n $destdir ]]; then [[ $destdir == /* && $destdir != / ]] || { echo 'Staging directory must be an absolute path other than /.' >&2; exit 1; }; fi
if [[ -z $libdir ]]; then
  if command -v pkg-config >/dev/null && pkg-config --exists sane-backends; then
    libdir=$(pkg-config --variable=libdir sane-backends)
  fi
  if [[ -z $libdir ]]; then
    machine=$(uname -m)
    case $machine in x86_64) triplet=x86_64-linux-gnu;; aarch64|arm64) triplet=aarch64-linux-gnu;; *) triplet=unknown;; esac
    if [[ -d /usr/lib/$triplet/sane ]]; then libdir=/usr/lib/$triplet
    elif [[ -d /usr/lib64/sane ]]; then libdir=/usr/lib64
    elif [[ -d /usr/lib/sane ]]; then libdir=/usr/lib
    else echo 'Install SANE first, or supply --libdir for its library directory.' >&2; exit 1; fi
  fi
fi
[[ $libdir == /* && $libdir != *..* && $libdir != */sane && $libdir != *$'\n'* ]] || { echo 'Use an absolute library directory (without /sane).' >&2; exit 1; }
binary=$root/libsane-dcpj315w.so.1.0.0
[[ -f $binary ]] || { echo 'Backend binary is missing from this package.' >&2; exit 1; }
magic=$(od -An -tx1 -N4 "$binary" | tr -d ' \n')
elf_machine=$(od -An -tu2 -j18 -N2 "$binary" | tr -d ' \n')
case $(uname -m) in x86_64) expected=62;; aarch64|arm64) expected=183;; *) echo 'Only x86_64 and arm64 are supported.' >&2; exit 1;; esac
[[ $magic == 7f454c46 && $elf_machine == "$expected" ]] || { echo 'This package is for a different CPU architecture.' >&2; exit 1; }
lib=$destdir$libdir/sane
conf=$destdir/etc/sane.d
for path in "$lib" "$conf" "$conf/dll.d" "$conf/dcpj315w.conf" "$conf/dll.d/dcpj315w" "$lib/libsane-dcpj315w.so.1.0.0"; do
  [[ ! -L $path ]] || { echo "Refusing symlink installation target: $path" >&2; exit 1; }
done
install -d -m 755 "$lib" "$conf/dll.d"
tmp=$(mktemp "$lib/.dcpj315w.XXXXXX")
trap 'rm -f "$tmp"' EXIT
install -m 755 "$binary" "$tmp"
mv -f "$tmp" "$lib/libsane-dcpj315w.so.1.0.0"
ln -sfn libsane-dcpj315w.so.1.0.0 "$lib/libsane-dcpj315w.so.1"
ln -sfn libsane-dcpj315w.so.1 "$lib/libsane-dcpj315w.so"
printf '# DCP-J315W Open Scanner; one numeric IPv4 address per line.\n%s\n' "$address" > "$conf/dcpj315w.conf"
chmod 644 "$conf/dcpj315w.conf"
printf 'dcpj315w\n' > "$conf/dll.d/dcpj315w"
chmod 644 "$conf/dll.d/dcpj315w"
if [[ -z $destdir ]] && command -v restorecon >/dev/null; then
  restorecon "$lib/libsane-dcpj315w.so.1.0.0" "$conf/dcpj315w.conf" "$conf/dll.d/dcpj315w"
fi
printf 'Installed DCP-J315W Open Scanner for %s.\nRestart your scanner application, or run: scanimage -L\n' "$address"
printf 'Backend library directory: %s/sane\n' "$libdir"
