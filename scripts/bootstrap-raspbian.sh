#!/bin/bash
# SPDX-License-Identifier: MIT
# Developer-only: construct an ARMv6 hard-float root from the signed Raspbian archive.
set -euo pipefail
[[ $(uname -s) == Linux && $EUID == 0 ]] || { echo 'Run inside a disposable Linux CI runner as root.' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL https://archive.raspbian.org/raspbian.public.key -o "$work/key.asc"
printf 'ca59cd4f2bcbc3a1d41ba6815a02a8dc5c175467a59bd87edeac458f4a5345de  %s\n' "$work/key.asc" | sha256sum -c -
gpg --batch --dearmor --output "$work/archive-keyring.gpg" "$work/key.asc"
deBootstrapRoot="$work/root"
deBootstrapArch=armhf
debootstrap --foreign --arch="$deBootstrapArch" --variant=minbase --include=ca-certificates --keyring="$work/archive-keyring.gpg" bookworm "$deBootstrapRoot" https://archive.raspbian.org/raspbian
cp /usr/bin/qemu-arm-static "$deBootstrapRoot/usr/bin/"
QEMU_CPU=arm1176 chroot "$deBootstrapRoot" /usr/bin/qemu-arm-static /bin/sh /debootstrap/debootstrap --second-stage
install -d "$deBootstrapRoot/usr/share/keyrings"
cp "$work/archive-keyring.gpg" "$deBootstrapRoot/usr/share/keyrings/raspbian.gpg"
printf 'deb [signed-by=/usr/share/keyrings/raspbian.gpg] https://archive.raspbian.org/raspbian bookworm main\n' > "$deBootstrapRoot/etc/apt/sources.list"
cp /etc/resolv.conf "$deBootstrapRoot/etc/resolv.conf"
# CA certificates are part of the bootstrap so subsequent HTTPS apt transport works.
tar -C "$deBootstrapRoot" -c . | docker import --platform linux/arm/v6 - dcp-raspbian:bookworm
