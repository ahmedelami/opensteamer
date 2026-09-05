#!/bin/bash
set -euo pipefail

# Build a reviewable artifact only. This script never installs, launches, or
# changes a LaunchAgent. Refuse to overwrite an existing destination.
meter_source_dir="$(cd "$(dirname "$0")" && pwd)"
meter_output="${1:?Usage: bash build-app.sh /absolute/new/path/MicDbMenu.app}"
case "$meter_output" in
    /*/MicDbMenu.app) ;;
    *) echo 'Destination must be an absolute path ending in /MicDbMenu.app' >&2; exit 1 ;;
esac
if [[ -e "$meter_output" || -L "$meter_output" ]]; then
    echo "Destination already exists: $meter_output" >&2
    exit 1
fi
swift build --package-path "$meter_source_dir" -c release --product MicDbMenu
meter_binary_dir="$(swift build --package-path "$meter_source_dir" -c release --show-bin-path)"
mkdir "$meter_output"
mkdir -p "$meter_output/Contents/MacOS" "$meter_output/Contents/Resources"
cp "$meter_source_dir/Info.plist" "$meter_output/Contents/Info.plist"
cp "$meter_binary_dir/MicDbMenu" "$meter_output/Contents/MacOS/MicDbMenu"
codesign --force --sign - "$meter_output"
codesign --verify --strict "$meter_output"
plutil -lint "$meter_output/Contents/Info.plist"
echo "Built (not installed or launched): $meter_output"
