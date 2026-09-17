#!/usr/bin/env bash
# Build Life Recorder and install it on a connected iPhone, without opening Xcode.
#
#   scripts/install-iphone.sh                 # build, install, launch
#   scripts/install-iphone.sh --device NAME   # pick a device by name, UDID or identifier
#   scripts/install-iphone.sh --build-only    # stop after building
#   scripts/install-iphone.sh --no-launch     # install but do not start the app
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$repo/ios/LifeRecorder.xcodeproj"
scheme="LifeRecorder"
bundle_id="com.unayung.liferecorder"
derived="${LIFE_RECORDER_BUILD_DIR:-$repo/build/device}"
device="${LIFE_RECORDER_DEVICE:-}"
launch=1
install=1

while [ $# -gt 0 ]; do
  case "$1" in
    --device) device="${2:?--device needs a name, UDID or identifier}"; shift 2 ;;
    --build-only) install=0; launch=0; shift ;;
    --no-launch) launch=0; shift ;;
    -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild is unavailable. Install Xcode, then run: sudo xcodebuild -license" >&2
  exit 1
fi

# Keep the generated project in step with project.yml when xcodegen is installed.
if command -v xcodegen >/dev/null 2>&1 && [ "$repo/ios/project.yml" -nt "$project/project.pbxproj" ]; then
  echo "==> project.yml changed; regenerating the Xcode project"
  (cd "$repo/ios" && xcodegen generate >/dev/null)
fi

# Simulators report transportType "sameMachine"; a real iPhone reports wired or localNetwork.
pick_device() {
  local json="$1" wanted="$2"
  python3 - "$json" "$wanted" <<'PY'
import json, sys
path, wanted = sys.argv[1], sys.argv[2]
devices = json.load(open(path))["result"]["devices"]
real = []
for device in devices:
    connection = device.get("connectionProperties", {})
    hardware = device.get("hardwareProperties", {})
    if connection.get("transportType") == "sameMachine" or hardware.get("platform") != "iOS":
        continue
    real.append({
        "name": device["deviceProperties"].get("name", "?"),
        "identifier": device["identifier"],
        "udid": hardware.get("udid", ""),
        "state": connection.get("tunnelState", "unknown"),
    })
if wanted:
    real = [d for d in real if wanted in (d["name"], d["identifier"], d["udid"])]
connected = [d for d in real if d["state"] == "connected"]
if len(connected) == 1:
    print(connected[0]["identifier"], connected[0]["name"], sep="\t")
    sys.exit(0)
if not real:
    print("NONE", file=sys.stderr)
elif not connected:
    print("DISCONNECTED\t" + ", ".join(d["name"] for d in real), file=sys.stderr)
else:
    print("AMBIGUOUS\t" + ", ".join(d["name"] for d in connected), file=sys.stderr)
sys.exit(1)
PY
}

devices_json="$(mktemp -t life-devices)"
trap 'rm -f "$devices_json"' EXIT
xcrun devicectl list devices --json-output "$devices_json" >/dev/null 2>&1 || true

if ! picked="$(pick_device "$devices_json" "$device" 2>"$devices_json.err")"; then
  reason="$(cut -f1 "$devices_json.err" 2>/dev/null || true)"
  detail="$(cut -f2 "$devices_json.err" 2>/dev/null || true)"
  rm -f "$devices_json.err"
  case "$reason" in
    DISCONNECTED) echo "iPhone found but not reachable ($detail)." >&2
                  echo "Connect it by USB or put it on this Wi-Fi, then unlock it." >&2 ;;
    AMBIGUOUS)    echo "Several iPhones are connected ($detail); pass --device NAME." >&2 ;;
    *)            echo "No paired iPhone found. Connect it by USB and trust this Mac." >&2 ;;
  esac
  exit 1
fi
rm -f "$devices_json.err"
identifier="$(printf '%s' "$picked" | cut -f1)"
name="$(printf '%s' "$picked" | cut -f2)"
echo "==> Device: $name"

echo "==> Building"
log="$(mktemp -t life-build)"
if ! xcodebuild -project "$project" -scheme "$scheme" -configuration Debug \
     -destination "id=$identifier" -derivedDataPath "$derived" \
     -allowProvisioningUpdates build >"$log" 2>&1; then
  grep -E "error:|errSecInternalComponent|requires a provisioning profile|No signing certificate" "$log" | sort -u | head -10 >&2
  if grep -q errSecInternalComponent "$log"; then
    echo >&2
    echo "Signing could not reach the login keychain. Run this script from Terminal.app" >&2
    echo "with the Mac unlocked; a sandboxed or remote shell cannot use the signing key." >&2
  fi
  echo "Full log: $log" >&2
  exit 1
fi
rm -f "$log"

app="$derived/Build/Products/Debug-iphoneos/$scheme.app"
[ -d "$app" ] || { echo "Build finished but $app is missing." >&2; exit 1; }
echo "==> Built $app"
[ "$install" -eq 1 ] || exit 0

echo "==> Installing"
if ! xcrun devicectl device install app --device "$identifier" "$app" >/dev/null; then
  echo "Install failed. Unlock the iPhone and keep it unlocked, then run this again." >&2
  exit 1
fi

if [ "$launch" -eq 1 ]; then
  echo "==> Launching"
  # iOS refuses to launch onto a locked screen; that is the usual failure here.
  xcrun devicectl device process launch --device "$identifier" --terminate-existing "$bundle_id" >/dev/null \
    || echo "Installed, but launching failed. Unlock the iPhone and open Life Recorder once." >&2
fi

cat <<EOF

Done. On the iPhone:
  1. Allow microphone and local network access if asked.
  2. Tap "Pair Mac" and use the pairing link from receiver/setup.py.
  3. Switch the recorder on.
EOF
