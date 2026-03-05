#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building..."
xcodebuild -scheme Hex -configuration Debug build 2>&1 | grep --line-buffered -E "^(Compile|Ld |Link|Copy|Process|error:|warning:|\*\* BUILD)"
BUILD_STATUS=${PIPESTATUS[0]}
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "Build failed."
    exit 1
fi
echo ""

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Hex-*/Build/Products/Debug/Hex\ Dev.app -maxdepth 0 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "Error: Could not find built app"
    exit 1
fi

# Kill existing instance if running
pkill -x "Hex Dev" 2>/dev/null && sleep 0.5 || true

echo "Launching $APP_PATH"
echo "Logs will stream below. Press Ctrl+C to quit the app."
echo ""

# Launch and stream logs filtered to our subsystem
open "$APP_PATH"
sleep 1

# Trap Ctrl+C to also kill the app
trap 'echo ""; echo "Stopping app..."; pkill -x "Hex Dev" 2>/dev/null; exit 0' INT

log stream --predicate 'subsystem == "com.kitlangton.Hex"' --level debug
