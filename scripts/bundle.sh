#!/bin/bash
# Turns the compiled trixie program into a real Mac app (build/Trixie.app)
# with its own permission text, so macOS asks for the microphone and speech
# recognition on its behalf (and remembers the answer).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product trixie
APP="build/Trixie.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/trixie "$APP/Contents/MacOS/trixie"
cp App/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"
