#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$SCRIPT_DIR/MobileViewerRunner.xcodeproj"
BUILD_DIR="$SCRIPT_DIR/../.build/xctest"

# Use the first booted simulator, or any available simulator as fallback
DEST=$(xcrun simctl list devices booted --json 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k, devs in d.get('devices', {}).items():
    for dev in devs:
        if dev.get('state') == 'Booted':
            print(f\"id={dev['udid']}\")
            exit()
" 2>/dev/null || echo "")

if [ -z "$DEST" ]; then
    # No booted simulator — use generic iOS simulator destination
    DEST="generic/platform=iOS Simulator"
fi

echo "Building MobileViewerRunner..."
echo "  Destination: $DEST"
echo "  Output:      $BUILD_DIR"
echo ""

xcodebuild build-for-testing \
    -project "$PROJECT" \
    -scheme MobileViewerRunner \
    -destination "$DEST" \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO

XCTESTRUN=$(find "$BUILD_DIR" -name "*.xctestrun" | head -1)
echo "Build complete."
echo "Test run file: $XCTESTRUN"

# XCTest requires UITargetAppPath even when UseUITargetAppProvidedByTests=true.
# Without it the framework throws "No target application path specified via
# test configuration" before any test code runs.  We point it at the Runner
# app itself (already installed as the test host); the app is never launched
# as a UI target because UseUITargetAppProvidedByTests=true.
echo "Patching xctestrun: injecting UITargetAppPath..."
PKEY=":TestConfigurations:0:TestTargets:0"
RUNNER_APP="__TESTROOT__/Debug-iphonesimulator/MobileViewerRunner-Runner.app"
RUNNER_BID="io.mobileviewer.runner.xctrunner"

/usr/libexec/PlistBuddy \
    -c "Add ${PKEY}:UITargetAppPath string ${RUNNER_APP}" \
    "$XCTESTRUN" 2>/dev/null || \
/usr/libexec/PlistBuddy \
    -c "Set ${PKEY}:UITargetAppPath ${RUNNER_APP}" \
    "$XCTESTRUN"

/usr/libexec/PlistBuddy \
    -c "Add ${PKEY}:UITargetAppBundleIdentifier string ${RUNNER_BID}" \
    "$XCTESTRUN" 2>/dev/null || \
/usr/libexec/PlistBuddy \
    -c "Set ${PKEY}:UITargetAppBundleIdentifier ${RUNNER_BID}" \
    "$XCTESTRUN"

echo "Patch applied."