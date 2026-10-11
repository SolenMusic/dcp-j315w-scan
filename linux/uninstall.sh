#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
libdir= destdir=
while (($#)); do
  case $1 in
    --libdir|--destdir)
      (($# >= 2)) || exit 1
      case $1 in --libdir) libdir=$2;; --destdir) destdir=$2;; esac; shift 2;;
    *) echo 'Usage: uninstall.sh --libdir LIBRARY_DIRECTORY [--destdir STAGING_DIRECTORY]' >&2; exit 1;;
  esac
done
[[ $(uname -s) == Linux && $libdir == /* && $libdir != *..* && $libdir != */sane && $libdir != *$'\n'* ]] || { echo 'Specify the library directory used at installation (for example /usr/lib64).' >&2; exit 1; }
[[ -z $destdir || ( $destdir == /* && $destdir != / ) ]] || exit 1
[[ -n $destdir || $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
for path in "$destdir$libdir/sane" "$destdir/etc/sane.d" "$destdir/etc/sane.d/dll.d"; do
  [[ ! -L $path ]] || { echo "Refusing symlink directory: $path" >&2; exit 1; }
done
rm -f -- "$destdir$libdir/sane/libsane-dcpj315w.so" "$destdir$libdir/sane/libsane-dcpj315w.so.1" \
  "$destdir$libdir/sane/libsane-dcpj315w.so.1.0.0" "$destdir/etc/sane.d/dll.d/dcpj315w"
echo 'Removed the backend. Scanner address configuration and scanned documents were preserved.'
