#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."

echo "Checking for Xcode command line tools..."
if ! xcode-select -p >/dev/null 2>&1; then
    echo "ERROR: xcode-select -p failed to resolve a developer directory."
    echo "Run: xcode-select --install"
    exit 1
fi
echo "  xcode-select -p: $(xcode-select -p)"

TARGET_IDENTITY="${CAMCORD_SIGN_IDENTITY:-}"
if [[ -z "$TARGET_IDENTITY" && -d /Applications/Camcord.app ]]; then
    codesign --verify --deep --strict /Applications/Camcord.app || {
        echo "ERROR: The installed app has an invalid signature." >&2
        exit 1
    }
    TARGET_IDENTITY="$(codesign -dvv /Applications/Camcord.app 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
    [[ -n "$TARGET_IDENTITY" ]] || {
        echo "ERROR: The installed app has no stable signing identity." >&2
        exit 1
    }
fi
echo "Checking for a stable signing identity..."
IDENTITIES="$(security find-identity -v -p codesigning)" || {
    echo "ERROR: Cannot read code signing identities." >&2
    exit 1
}
if [[ -z "$TARGET_IDENTITY" ]]; then
    TARGET_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk '/^[[:space:]]*[0-9]+\)/ { print $2 }')"
fi
MATCHES="$(printf '%s\n' "$IDENTITIES" | awk -v wanted="$TARGET_IDENTITY" '
    /^[[:space:]]*[0-9]+\)/ { hash=$2; name=$0; sub(/^[^"]*"/, "", name); sub(/"[[:space:]]*$/, "", name); if (name == wanted || hash == wanted) print hash }')"
if [[ -n "$MATCHES" && "$MATCHES" != *$'\n'* && "$TARGET_IDENTITY" != '-' ]]; then
    echo "OK: found one exact signing identity ($MATCHES)."
    exit 0
fi

cat <<'EOF'
ERROR: The configured stable signing identity is missing or ambiguous.

Use an existing Code Signing identity from your keychain and configure its
exact certificate name or SHA-1 hash before building:
  export CAMCORD_SIGN_IDENTITY="Your Exact Certificate Name"
  ./scripts/build.sh

A stable identity preserves macOS Screen Recording and Accessibility grants
across rebuilds. Installation refuses a change to the installed app's signing
identifier, team, certificate chain, or designated requirement. This script
never creates, trusts, or changes certificates.

For a local bundle without a certificate, explicitly use --unsigned or
--ad-hoc. These bundles cannot be installed with --install and their privacy
permissions may need to be granted again on each rebuild.
EOF
exit 1
