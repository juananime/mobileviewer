#!/usr/bin/env bash
# Usage:
#   ./run-ios.sh                        # open Simulator viewer
#   ./run-ios.sh example_flow.yaml      # run a YAML flow
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. Ensure a simulator is booted ──────────────────────────────────────────

BOOTED=$(xcrun simctl list devices booted --json 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
for devs in d.get('devices', {}).values():
    for dev in devs:
        if dev.get('state') == 'Booted':
            print(dev['udid'])
            exit()
" 2>/dev/null || echo "")

if [ -z "$BOOTED" ]; then
    # Pick iPhone 16 first, then any available simulator
    UDID=$(xcrun simctl list devices available --json \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
preferred = None
fallback = None
for runtime, devs in d.get('devices', {}).items():
    if 'iOS' not in runtime:
        continue
    for dev in devs:
        if not dev.get('isAvailable'):
            continue
        if 'iPhone 16' in dev.get('name', '') and not preferred:
            preferred = dev['udid']
        if not fallback:
            fallback = dev['udid']
print(preferred or fallback or '')
")
    if [ -z "$UDID" ]; then
        echo "No available iOS simulator found. Open Xcode → Window → Devices and Simulators to add one." >&2
        exit 1
    fi
    echo "Booting simulator $UDID ..."
    xcrun simctl boot "$UDID"
    open -a Simulator
    echo ""
fi

# ── 2. Run the Dart CLI (auto-builds runner if needed) ───────────────────────

dart run "$SCRIPT_DIR/bin/mobileviewer.dart" --ios "$@"