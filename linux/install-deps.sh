#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Install SANE runtime packages, without scanning or adding a background daemon.
set -euo pipefail
dry_run=0
if [[ ${1:-} == --dry-run && $# == 1 ]]; then dry_run=1
elif [[ $# != 0 ]]; then echo 'Usage: sudo ./install-deps.sh [--dry-run]' >&2; exit 1; fi
[[ $(uname -s) == Linux ]] || { echo 'Linux only.' >&2; exit 1; }
root=$(cd -- "$(dirname -- "$0")" && pwd)
flavour=
if [[ -f $root/BUNDLE_FLAVOUR ]]; then
  read -r flavour < "$root/BUNDLE_FLAVOUR"
fi
if [[ -z $flavour || $flavour == generic ]]; then
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *debian*|*ubuntu*) flavour=debian;;
    *fedora*|*rhel*|*centos*|*rocky*|*almalinux*) flavour=fedora;;
    *arch*) flavour=arch;;
    *opensuse*|*suse*|*sles*) flavour=opensuse;;
    *alpine*) flavour=alpine;;
    *) echo 'Install your distribution’s SANE library, scanimage and Bash using its package manager.' >&2; exit 1;;
  esac
fi
case $flavour in
  debian|raspberrypi) manager=apt-get; packages=(libsane1 sane-utils binutils);;
  fedora) manager=dnf; packages=(sane-backends sane-backends-libs binutils);;
  arch) manager=pacman; packages=(sane binutils);;
  opensuse) manager=zypper; packages=(sane-backends binutils);;
  alpine) manager=apk; packages=(sane sane-utils bash binutils);;
  *) echo 'Unknown bundle flavour.' >&2; exit 1;;
esac
command -v "$manager" >/dev/null || { echo "This bundle needs $manager; choose the bundle for your distribution." >&2; exit 1; }
printf 'SANE runtime packages: %s (%s)\n' "${packages[*]}" "$manager"
((dry_run)) && exit 0
[[ $EUID == 0 ]] || { echo 'Run with sudo, or use --dry-run.' >&2; exit 1; }
case $flavour in
  debian|raspberrypi) apt-get update; apt-get install -y "${packages[@]}";;
  fedora) dnf install -y "${packages[@]}";;
  arch) pacman -Syu --needed "${packages[@]}";;
  opensuse) zypper --non-interactive install "${packages[@]}";;
  alpine) apk add "${packages[@]}";;
esac
echo 'Choose a native desktop scanner application separately (for example Document Scanner or Skanpage).'
