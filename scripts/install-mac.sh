#!/usr/bin/env bash
# Build the Life Recorder Mac app and install it in ~/Applications, without opening Xcode.
#
#   scripts/install-mac.sh                # build, install, open
#   scripts/install-mac.sh --build-only   # stop after building
#   scripts/install-mac.sh --no-launch    # install but do not open the app
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$repo/ios/LifeRecorder.xcodeproj"
scheme="LifeRecorderMac"
bundle_id="com.unayung.liferecorder.mac"
derived="${LIFE_RECORDER_BUILD_DIR:-$repo/build/mac}"
app="$HOME/Applications/Life Recorder.app"
launch=1
install=1

while [ $# -gt 0 ]; do
  case "$1" in
    --build-only) install=0; launch=0; shift ;;
    --no-launch) launch=0; shift ;;
    -h|--help) sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

echo "==> Building"
log="$(mktemp -t life-build)"
if ! xcodebuild -project "$project" -scheme "$scheme" -configuration Release \
     -destination 'platform=macOS' -derivedDataPath "$derived" \
     -allowProvisioningUpdates build >"$log" 2>&1; then
  grep -E "error:|errSecInternalComponent|No signing certificate" "$log" | sort -u | head -10 >&2
  if grep -q errSecInternalComponent "$log"; then
    echo >&2
    echo "Signing could not reach the login keychain. Run this script from Terminal.app" >&2
    echo "with the Mac unlocked; a sandboxed or remote shell cannot use the signing key." >&2
  fi
  echo "Full log: $log" >&2
  exit 1
fi
rm -f "$log"

built="$derived/Build/Products/Release/Life Recorder.app"
[ -d "$built" ] || { echo "Build finished but $built is missing." >&2; exit 1; }
echo "==> Built $built"
[ "$install" -eq 1 ] || exit 0

echo "==> Installing"
# Replacing an app under a running copy leaves it reading files that are gone.
osascript -e "if application id \"$bundle_id\" is running then tell application id \"$bundle_id\" to quit" \
  >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications"
rm -rf "$app"
ditto "$built" "$app"

if [ "$launch" -eq 1 ]; then
  echo "==> Opening"
  open "$app"
fi

cat <<EOF

Done. Life Recorder is in ~/Applications.
  A Mac that runs the meeting recorder (desktop/capture_mac) is already paired through it.
  On any other Mac, open Settings and enter the receiver's address, token and fingerprint.
EOF
