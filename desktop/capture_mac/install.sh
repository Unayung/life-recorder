#!/usr/bin/env bash
# Build the Mac meeting recorder, install it in ~/Applications and start it at every login.
#
#   desktop/capture_mac/install.sh                      # upload to the default receiver
#   desktop/capture_mac/install.sh --receiver URL       # another receiver
#   desktop/capture_mac/install.sh --build-only
#
# Needs receiver.token and receiver.crt in ~/Library/Application Support/LifeRecorder (the same pair the
# phone is paired with). macOS asks once for microphone and system audio access.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
label="com.unayung.life-recorder.capture"
build="$repo/build/capture_mac/Life Recorder Capture.app"
app="$HOME/Applications/Life Recorder Capture.app"
agent="$HOME/Library/LaunchAgents/$label.plist"
data="$HOME/Library/Application Support/LifeRecorder"
receiver="https://omarchy.tail3fdc0b.ts.net:8443"
install=1

while [ $# -gt 0 ]; do
  case "$1" in
    --receiver) receiver="${2:?--receiver needs a URL}"; shift 2 ;;
    --build-only) install=0; shift ;;
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "==> Building"
rm -rf "$build"
mkdir -p "$build/Contents/MacOS"
cp "$here/Info.plist" "$build/Contents/Info.plist"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
  -o "$build/Contents/MacOS/LifeRecorderCapture" "$here/main.swift"

# A stable signing identity keeps the privacy grants across rebuilds; ad-hoc signing would lose them.
identity="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${identity:--}" "$build"
[ "$install" = 1 ] || { echo "Built $build"; exit 0; }

for file in receiver.token receiver.crt; do
  [ -f "$data/$file" ] || { echo "Missing $data/$file; pair with the receiver first." >&2; exit 1; }
done

echo "==> Installing"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$app"
ditto "$build" "$app"
cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>$app/Contents/MacOS/LifeRecorderCapture</string>
    <string>--receiver</string><string>$receiver</string>
  </array>
  <key>AssociatedBundleIdentifiers</key><string>com.unayung.liferecorder.capture</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/LifeRecorderCapture.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/LifeRecorderCapture.log</string>
</dict></plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$agent"

echo
echo "Done. Allow microphone access if macOS asks. System audio access is asked for at the first meeting;"
echo "if the other side is missing, allow Life Recorder Capture in System Settings > Privacy & Security >"
echo "Screen & System Audio Recording. Log: ~/Library/Logs/LifeRecorderCapture.log"
