#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

rm -rf dist/Camcord.app
mkdir -p dist/Camcord.app/Contents/MacOS dist/Camcord.app/Contents/Resources
cp .build/release/Camcord dist/Camcord.app/Contents/MacOS/Camcord
cp Resources/Info.plist dist/Camcord.app/Contents/Info.plist
cp Resources/AppIcon.icns dist/Camcord.app/Contents/Resources/AppIcon.icns

# SPM resource bundles (e.g. KeyboardShortcuts' localized strings) are built next to
# the executable, NOT into it. Bundle.module finds them in Contents/Resources — without
# this copy the app hard-crashes (assertionFailure) the instant a view backed by those
# resources appears (the shortcut recorders in Settings › Fare ve Kısayollar).
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" dist/Camcord.app/Contents/Resources/
done
printf 'APPL????' > dist/Camcord.app/Contents/PkgInfo

IDENTITY="${CAMCORD_SIGN_IDENTITY:-Apple Development}"
codesign --force --sign "$IDENTITY" --identifier dev.tavsan.camcord dist/Camcord.app

codesign --verify --strict dist/Camcord.app
# Note: on this machine's codesign, "-dv" (verbose=1) omits the Authority
# chain; "-dvv" (verbose=2) is the minimum that includes it.
codesign -dvv dist/Camcord.app 2>&1 | grep '^Authority='

# --install: copy the freshly built+signed bundle into /Applications and relaunch
# from there (the stable location the login item should point at).
if [[ "${1:-}" == "--install" ]]; then
    if pgrep -xq Camcord; then
        # Quit via Apple event so applicationShouldTerminate runs — a raw pkill
        # (SIGTERM) would skip it and corrupt an in-progress recording's file.
        # For the same reason there is deliberately NO kill fallback: if the app
        # is still alive after the grace window (e.g. finalizing a long recording),
        # abort the install instead of corrupting the file we just protected.
        osascript -e 'tell application "Camcord" to quit' >/dev/null 2>&1 || true
        for _ in $(seq 1 120); do
            pgrep -xq Camcord || break
            sleep 0.25
        done
        if pgrep -xq Camcord; then
            echo "Camcord is still shutting down (finalizing a recording?) — install aborted, retry shortly." >&2
            exit 1
        fi
    fi
    ditto dist/Camcord.app /Applications/Camcord.app
    open /Applications/Camcord.app
    echo "Installed and launched /Applications/Camcord.app"
fi
