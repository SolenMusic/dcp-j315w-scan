#!/bin/bash
# Install this user's local scanner bridge. Scans remain in native apps' folders.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "$0")" && pwd)
printer_addr=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --address) [[ $# -ge 2 ]] || exit 2; printer_addr=$2; shift 2 ;;
    *) printf 'Usage: %s --address PRINTER_IPV4\n' "$0" >&2; exit 2 ;;
  esac
done
ip_pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
[[ "$printer_addr" =~ $ip_pattern ]] || { echo 'A numeric IPv4 printer address is required.' >&2; exit 2; }
IFS=. read -r part1 part2 part3 part4 <<< "$printer_addr"
for component in "$part1" "$part2" "$part3" "$part4"; do
  [[ ${#component} -eq 1 || ${component:0:1} != 0 ]] || exit 2
  (( 10#$component <= 255 )) || exit 2
done
[[ $(uname -s) == Darwin && $(id -u) -ne 0 ]] || { echo 'Run as your macOS user, without sudo.' >&2; exit 2; }
source_app="$project_root/build/DCPJ315WAirScanBridge.app"
[[ -d "$source_app" ]] || { echo 'Run ./build-macos-airscan.sh first.' >&2; exit 1; }
codesign --verify --strict "$source_app"
label=org.dcpj315w.scan.airscan
scan_support="$HOME/Library/Application Support/DCPJ315WScan"
agent_folder="$HOME/Library/LaunchAgents"
agent_plist="$agent_folder/$label.plist"
installed_app="$scan_support/DCPJ315WAirScanBridge.app"
domain="gui/$(id -u)"
[[ ! -L "$scan_support" && ! -L "$agent_plist" && ! -L "$installed_app" ]] || { echo 'Refusing a symlink at an installation target.' >&2; exit 1; }
mkdir -p "$scan_support" "$agent_folder"
chmod 700 "$scan_support"
stage=$(mktemp -d "$scan_support/.install.XXXXXX")
committed=0
replaced=0
was_loaded=0
cleanup() {
  if [[ $committed -eq 0 && $replaced -eq 1 ]]; then
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    rm -rf -- "$installed_app"
    [[ ! -d "$stage/previous.app" ]] || mv "$stage/previous.app" "$installed_app"
    if [[ -f "$stage/previous.plist" ]]; then cp "$stage/previous.plist" "$agent_plist"; else rm -f "$agent_plist"; fi
    [[ $was_loaded -eq 0 ]] || launchctl bootstrap "$domain" "$agent_plist" || true
  fi
  rm -rf -- "$stage"
}
trap cleanup EXIT
cp -R "$source_app" "$stage/new.app"
codesign --verify --strict "$stage/new.app"
xml_escape() { sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
program_xml=$(printf '%s' "$installed_app/Contents/MacOS/DCPJ315WAirScanBridge" | xml_escape)
log_xml=$(printf '%s' "$scan_support/bridge.log" | xml_escape)
cat > "$stage/agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$program_xml</string><string>--address</string><string>$printer_addr</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardOutPath</key><string>$log_xml</string>
<key>StandardErrorPath</key><string>$log_xml</string>
</dict></plist>
PLIST
chmod 600 "$stage/agent.plist"
plutil -lint "$stage/agent.plist"
[[ ! -e "$agent_plist" ]] || cp "$agent_plist" "$stage/previous.plist"
if launchctl print "$domain/$label" >/dev/null 2>&1; then
  was_loaded=1
  launchctl bootout "$domain/$label"
fi
[[ ! -e "$installed_app" ]] || mv "$installed_app" "$stage/previous.app"
replaced=1
mv "$stage/new.app" "$installed_app"
cp "$stage/agent.plist" "$agent_plist"
touch "$scan_support/bridge.log"; chmod 600 "$scan_support/bridge.log"
if ! launchctl bootstrap "$domain" "$agent_plist"; then
  echo 'Launch failed; the previous installation was restored.' >&2; exit 1
fi
committed=1
echo 'Installed DCP-J315W Open Scanner for this user and enabled login startup.'
echo 'Open Image Capture or Preview to scan. No administrator authentication is required.'
