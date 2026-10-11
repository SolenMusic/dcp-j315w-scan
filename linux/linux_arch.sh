#!/bin/sh
# SPDX-License-Identifier: MIT
# Shared ELF/CPU/float-ABI checks. All supported targets are little-endian.
dcp_elf_arch() {
  dcp_binary=$1
  command -v readelf >/dev/null 2>&1 || { echo 'Install binutils (readelf) to validate the binary architecture.' >&2; return 1; }
  dcp_magic=$(od -An -tx1 -N6 "$dcp_binary" | tr -d ' \n')
  case "$dcp_magic" in 7f454c460101) dcp_class=32;; 7f454c460201) dcp_class=64;; *) echo 'Unsupported ELF class or byte order.' >&2; return 1;; esac
  dcp_machine=$(od -An -tu2 -j18 -N2 "$dcp_binary" | tr -d ' \n')
  case "$dcp_class:$dcp_machine" in
    64:62) echo x86_64;; 64:183) echo arm64;; 32:3) echo x86;;
    32:40)
      dcp_attrs=$(readelf -A "$dcp_binary")
      dcp_cpu=$(printf '%s\n' "$dcp_attrs" | sed -n 's/.*Tag_CPU_arch: //p' | head -1)
      dcp_flags=$(od -An -tu4 -j36 -N4 "$dcp_binary" | tr -d ' \n')
      if [ $((dcp_flags & 1024)) -ne 0 ]; then dcp_float=hard; else dcp_float=soft; fi
      case "$dcp_cpu:$dcp_float" in
        v6:hard|v6K:hard|v6KZ:hard) echo armv6;;
        v6:soft|v6K:soft|v6KZ:soft) echo armv6-softfloat;;
        v7:hard) echo armv7;;
        *) echo "Unsupported ARM CPU/float ABI: $dcp_cpu/$dcp_float" >&2; return 1;;
      esac;;
    *) echo 'Unsupported ELF CPU.' >&2; return 1;;
  esac
}
dcp_check_runtime() {
  dcp_check_binary=$1
  dcp_library=${2:-0}
  dcp_arch=$(dcp_elf_arch "$dcp_check_binary") || return 1
  dcp_host=$(uname -m)
  case "$dcp_host:$dcp_arch" in
    x86_64:x86_64|aarch64:arm64|arm64:arm64|i?86:x86|x86_64:x86) ;;
    armv6*:armv6|armv6*:armv6-softfloat|armv7*:armv6|armv7*:armv6-softfloat|armv7*:armv7|armv8l:armv6|armv8l:armv6-softfloat|armv8l:armv7|aarch64:armv6|aarch64:armv6-softfloat|aarch64:armv7) ;;
    *) echo "Binary $dcp_arch is incompatible with CPU $dcp_host." >&2; return 1;;
  esac
  if [ "$dcp_library" = 1 ]; then
    if command -v getconf >/dev/null 2>&1; then dcp_bits=$(getconf LONG_BIT) || return 1
    else
      dcp_shell_class=$(od -An -tu1 -j4 -N1 /bin/sh | tr -d ' \n')
      case "$dcp_shell_class" in 1) dcp_bits=32;; 2) dcp_bits=64;; *) return 1;; esac
    fi
    case "$dcp_arch:$dcp_bits" in arm64:64|x86_64:64|armv6:32|armv6-softfloat:32|armv7:32|x86:32) ;;
      *) echo 'A scanner plugin must match the SANE runtime word size.' >&2; return 1;; esac
  fi
  case "$dcp_arch" in
    armv6|armv7)
      [ -e /lib/ld-linux-armhf.so.3 ] || [ -e /lib/ld-musl-armhf.so.1 ] || { echo 'A hard-float ARM runtime is required.' >&2; return 1; };;
    armv6-softfloat)
      [ -e /lib/ld-linux.so.3 ] || [ -e /lib/ld-musl-arm.so.1 ] || { echo 'An ARM soft-float runtime is required; Raspberry Pi OS uses hard-float.' >&2; return 1; };;
  esac
}
