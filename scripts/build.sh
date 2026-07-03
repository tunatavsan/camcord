#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

rm -rf dist/Camcord.app
mkdir -p dist/Camcord.app/Contents/MacOS
cp .build/release/Camcord dist/Camcord.app/Contents/MacOS/Camcord
cp Resources/Info.plist dist/Camcord.app/Contents/Info.plist
printf 'APPL????' > dist/Camcord.app/Contents/PkgInfo

IDENTITY="${CAMCORD_SIGN_IDENTITY:-Apple Development}"
codesign --force --sign "$IDENTITY" --identifier dev.tavsan.camcord dist/Camcord.app

codesign --verify --strict dist/Camcord.app
# Note: on this machine's codesign, "-dv" (verbose=1) omits the Authority
# chain; "-dvv" (verbose=2) is the minimum that includes it.
codesign -dvv dist/Camcord.app 2>&1 | grep '^Authority='
