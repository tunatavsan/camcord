#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Checking for Xcode command line tools..."
if ! xcode-select -p >/dev/null 2>&1; then
	echo "ERROR: xcode-select -p failed to resolve a developer directory."
	echo "Run: xcode-select --install"
	exit 1
fi
echo "  xcode-select -p: $(xcode-select -p)"

# Honor the same override build.sh uses — otherwise a user who followed our own
# self-signed-cert instructions would see this check keep failing.
TARGET_IDENTITY="${CAMCORD_SIGN_IDENTITY:-Apple Development}"
echo "Checking for a '$TARGET_IDENTITY' code signing identity..."
# "|| true" so an unexpected non-zero from `security` still reaches the
# missing-identity instructions below instead of aborting under set -e.
IDENTITIES="$(security find-identity -v -p codesigning || true)"

if echo "$IDENTITIES" | grep -q "$TARGET_IDENTITY"; then
	echo "$IDENTITIES" | grep "$TARGET_IDENTITY"
	echo "OK: found a matching signing identity."
	exit 0
fi

cat <<'EOF'
ERROR: no "Apple Development" code signing identity found in your keychain.

camcord must be signed with a stable identity (never ad-hoc "-") so macOS TCC
grants (Screen Recording, Accessibility) survive rebuilds.

To create a free self-signed Code Signing certificate:
  1. Open Keychain Access.
  2. Menu: Keychain Access -> Certificate Assistant -> Create a Certificate...
  3. Name it, set "Identity Type" to "Self Signed Root", set
     "Certificate Type" to "Code Signing", then create it.
  4. Re-run this script to confirm it is picked up.

If you use a different identity name, export it before building:
  export CAMCORD_SIGN_IDENTITY="Your Identity Name"
EOF
exit 1
