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
    CODE_SIGNING_REQUIRED=NO \
    -quiet

XCTESTRUN=$(find "$BUILD_DIR" -name "*.xctestrun" | head -1)
echo "Build complete."
echo "Test run file: $XCTESTRUN"