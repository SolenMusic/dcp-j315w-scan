#!/bin/bash
set -euo pipefail
[[ $(uname -s) == Darwin && $(id -u) -ne 0 ]] || { echo 'Run as your macOS user, without sudo.' >&2; exit 2; }
label=org.dcpj315w.scan.airscan
scan_support="$HOME/Library/Application Support/DCPJ315WScan"
agent_plist="$HOME/Library/LaunchAgents/$label.plist"
[[ ! -L "$scan_support" && ! -L "$agent_plist" ]] || { echo 'Refusing symlink targets.' >&2; exit 1; }
if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then launchctl bootout "gui/$(id -u)/$label"; fi
rm -f -- "$agent_plist"
rm -rf -- "$scan_support/DCPJ315WAirScanBridge.app"
# Preserve diagnostic logs; native applications own scanned documents elsewhere.
echo 'Removed this user’s scanner bridge and login startup entry.'
