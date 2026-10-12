#!/bin/bash
# Debug build of "HardwareMonitor Dev" (local.hardwaremonitor.dev), sign with the local identity, quit any running
# HardwareMonitor (production too), install to ~/Applications and launch. Production comes from the DMG/updater.
# Extra arguments are passed to HardwareMonitor, e.g. ./scripts/build-app.sh --log-events
# BUNDLE_ONLY=1 builds the production release bundle and stops after signing (used by the release workflow).
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="HardwareMonitor Local Signing"
if [[ ${BUNDLE_ONLY:-} == 1 ]]; then
    CONFIG=release NAME=HardwareMonitor EXE=HardwareMonitor
else
    CONFIG=debug NAME="HardwareMonitor Dev" EXE=HardwareMonitorDev
fi
APP=".build/$NAME.app"
DEST="$HOME/Applications/$NAME.app"

ids=$(security find-identity -v -p codesigning)
if [[ $ids != *"\"$IDENTITY\""* ]]; then
    echo "error: code-signing identity \"$IDENTITY\" not found." >&2
    echo "Run ./scripts/make-cert.sh in Terminal.app first." >&2
    exit 1
fi

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/HardwareMonitor" "$APP/Contents/MacOS/$EXE"
cp Info.plist "$APP/Contents/Info.plist"
if [[ $CONFIG == debug ]]; then
    pb() { /usr/libexec/PlistBuddy -c "$1" "$APP/Contents/Info.plist"; }
    pb "Set :CFBundleIdentifier local.hardwaremonitor.dev"
    pb "Set :CFBundleName $NAME"
    pb "Set :CFBundleExecutable $EXE"
fi
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "$IDENTITY" "$APP"
[[ ${BUNDLE_ONLY:-} == 1 ]] && exit 0   # CI: leave the signed .build/HardwareMonitor.app, don't install

# Quit production and dev (two copies would both sample and show the same readings) and wait (up to 5 s) so `open`
# starts a fresh process.
pkill -x HardwareMonitor || true
pkill -x HardwareMonitorDev || true
for _ in {1..50}; do pgrep -x 'HardwareMonitor|HardwareMonitorDev' >/dev/null || break; sleep 0.1; done

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
mv "$APP" "$DEST"   # installs and removes the build copy: only one bundle with this ID

if [[ $# -gt 0 ]]; then
    open "$DEST" --args "$@"
else
    open "$DEST"
fi
echo "Back to production: pkill -x HardwareMonitorDev; open /Applications/HardwareMonitor.app"
