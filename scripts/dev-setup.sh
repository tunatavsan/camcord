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

echo "Checking for an 'Apple Development' code signing identity..."
IDENTITIES="$(security find-identity -v -p codesigning)"

if echo "$IDENTITIES" | grep -q "Apple Development"; then
	echo "$IDENTITIES" | grep "Apple Development"
	echo "OK: found an Apple Development signing identity."
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
