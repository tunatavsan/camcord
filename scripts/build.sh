#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
PROJECT_ROOT="$PWD"
BUNDLE_ID="dev.tavsan.camcord"
INSTALL_ROOT="/Applications"
INSTALL_APP="$INSTALL_ROOT/Camcord.app"
INSTALL=false
SIGN_MODE=signed

fail() { echo "ERROR: $*" >&2; exit 1; }
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --unsigned) SIGN_MODE=unsigned ;;
        --ad-hoc) SIGN_MODE=adhoc ;;
        *) fail "Unknown argument: $arg. Use --install, --unsigned, or --ad-hoc." ;;
    esac
done
[[ "$INSTALL" == false || "$SIGN_MODE" == signed ]] || fail "Installation requires a stable signing identity."

# Refuse symlinked parents as well as the final path before moving or removing files.
check_path() {
    local path="$1"
    [[ "$path" == /* && "$path" != *'/../'* && "$path" != *'/./'* ]] || fail "Unsafe path: $path"
    while [[ "$path" != / ]]; do
        [[ ! -L "$path" ]] || fail "Symlink path refused: $path"
        path="$(dirname "$path")"
    done
}
check_bundle() {
    local links plist_id
    check_path "$1"
    [[ -d "$1" && -f "$1/Contents/Info.plist" && -f "$1/Contents/MacOS/Camcord" ]] || fail "Incomplete app bundle: $1"
    links="$(find "$1" -type l -print -quit)" || fail "Cannot validate app bundle paths: $1"
    [[ -z "$links" ]] || fail "Symlinks inside app bundle refused: $1"
    plist_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" || fail "Cannot read bundle identifier: $1"
    [[ "$plist_id" == "$BUNDLE_ID" ]] || fail "Unexpected bundle identifier: $1"
}
require_stopped() {
    local status=0
    pgrep -x Camcord >/dev/null 2>&1 || status=$?
    case "$status" in
        1) return ;;
        0) fail "Camcord is running. Quit it explicitly when capture and file saving are finished, then retry --install." ;;
        *) fail "Could not establish whether Camcord is running; installation refused." ;;
    esac
}
signature() {
    local details requirement identifier team authorities
    codesign --verify --deep --strict "$1" >&2 || fail "Invalid signature: $1"
    details="$(codesign -dvv "$1" 2>&1)" || fail "Cannot read signature: $1"
    requirement="$(codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p')" || fail "Cannot read designated requirement: $1"
    identifier="$(printf '%s\n' "$details" | sed -n 's/^Identifier=//p')"
    team="$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p')"
    authorities="$(printf '%s\n' "$details" | sed -n 's/^Authority=//p')"
    [[ "$identifier" == "$BUNDLE_ID" && -n "$team" && "$team" != not\ set && -n "$authorities" && -n "$requirement" ]] || fail "A stable Camcord signature is required: $1"
    printf '%s\n%s\n%s\n%s\n' "$identifier" "$team" "$authorities" "$requirement"
}

BUILD_STAGE=""
INSTALL_STAGE=""
LOCK=""
BACKUP=""
OLD_MOVED=false
NEW_MOVED=false
INSTALL_COMMITTED=false
KEEP_BUILD_STAGE=false
cleanup() {
    local status=$? links
    trap - EXIT INT TERM
    if [[ "$INSTALL_COMMITTED" == false && "$NEW_MOVED" == true ]]; then
        # Preserve the failed candidate for inspection before restoring the original.
        if [[ ! -e "$INSTALL_STAGE/failed-Camcord.app" && ! -L "$INSTALL_STAGE/failed-Camcord.app" ]] &&
            mv "$INSTALL_APP" "$INSTALL_STAGE/failed-Camcord.app"; then
            NEW_MOVED=false
        else
            echo "ERROR: Could not move failed installation aside. Backup: $BACKUP" >&2
            status=1
        fi
    fi
    if [[ "$INSTALL_COMMITTED" == false && "$OLD_MOVED" == true && "$NEW_MOVED" == false ]]; then
        if [[ ! -e "$INSTALL_APP" && ! -L "$INSTALL_APP" ]] && mv "$BACKUP" "$INSTALL_APP"; then
            echo "Restored previous installation." >&2
        else
            echo "ERROR: Automatic rollback failed. Recover previous app from: $BACKUP" >&2
            status=1
        fi
    fi
    if [[ -n "$BUILD_STAGE" && "$KEEP_BUILD_STAGE" == false ]]; then
        check_path "$BUILD_STAGE"
        [[ "$BUILD_STAGE" == "$PROJECT_ROOT"/dist/.camcord-build.* && -d "$BUILD_STAGE" ]] || exit 1
        links="$(find "$BUILD_STAGE" -type l -print -quit)" || exit 1
        [[ -z "$links" ]] || exit 1
        rm -rf -- "$BUILD_STAGE"
    fi
    # Install stages containing backups or failed bundles are retained, never swept.
    if [[ -n "$INSTALL_STAGE" ]]; then rmdir "$INSTALL_STAGE" 2>/dev/null || true; fi
    if [[ -n "$LOCK" ]]; then rmdir "$LOCK" || status=1; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_path "$PROJECT_ROOT/dist/Camcord.app"
[[ ! -e dist/Camcord.app || -d dist/Camcord.app ]] || fail "dist/Camcord.app is not a directory."
if [[ "$INSTALL" == true ]]; then
    check_path "$INSTALL_APP"
    [[ -d "$INSTALL_ROOT" ]] || fail "Install directory is missing: $INSTALL_ROOT"
    require_stopped
    check_path "$INSTALL_ROOT/.camcord-install.lock"
    mkdir "$INSTALL_ROOT/.camcord-install.lock" || fail "Another installation is active (or its lock remains): $INSTALL_ROOT/.camcord-install.lock"
    LOCK="$INSTALL_ROOT/.camcord-install.lock"
fi

INSTALLED_SIGNATURE=""
INSTALLED_IDENTITY=""
if [[ "$SIGN_MODE" == signed && -e "$INSTALL_APP" ]]; then
    check_bundle "$INSTALL_APP"
    INSTALLED_SIGNATURE="$(signature "$INSTALL_APP")"
    INSTALLED_IDENTITY="$(codesign -dvv "$INSTALL_APP" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
    [[ -n "$INSTALLED_IDENTITY" ]] || fail "Cannot read installed signing identity."
fi
if [[ "$SIGN_MODE" == signed ]]; then
    IDENTITY="${CAMCORD_SIGN_IDENTITY:-$INSTALLED_IDENTITY}"
    [[ "$IDENTITY" != '-' ]] || fail "Use --ad-hoc explicitly to create a non-installable ad-hoc bundle."
    # Match the entire certificate name (or hash), never an ambiguous substring.
    IDENTITIES="$(security find-identity -v -p codesigning)" || fail "Cannot read code signing identities."
    if [[ -z "$IDENTITY" ]]; then
        # A fresh contributor checkout may use its sole stable keychain identity.
        IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk '/^[[:space:]]*[0-9]+\)/ { print $2 }')"
        [[ -n "$IDENTITY" && "$IDENTITY" != *$'\n'* ]] || fail "No unambiguous stable signing identity. Set CAMCORD_SIGN_IDENTITY to an exact certificate name or hash, or explicitly use --unsigned / --ad-hoc."
    fi
    MATCHES="$(printf '%s\n' "$IDENTITIES" | awk -v wanted="$IDENTITY" '
        /^[[:space:]]*[0-9]+\)/ { hash=$2; name=$0; sub(/^[^"]*"/, "", name); sub(/"[[:space:]]*$/, "", name); if (name == wanted || hash == wanted) print hash }')"
    [[ -n "$MATCHES" && "$MATCHES" != *$'\n'* ]] || fail "Expected exactly one signing identity '$IDENTITY'. Set CAMCORD_SIGN_IDENTITY to an exact certificate name or hash; see scripts/dev-setup.sh."
fi

swift build -c release
mkdir -p dist
BUILD_STAGE="$(mktemp -d "$PROJECT_ROOT/dist/.camcord-build.XXXXXX")"
check_path "$BUILD_STAGE"
APP="$BUILD_STAGE/Camcord.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Camcord "$APP/Contents/MacOS/Camcord"
cp Resources/Info.plist "$APP/Contents/Info.plist"
build_number="$(git rev-list --count HEAD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$APP/Contents/Info.plist"
if [[ -e Resources/AppIcon.icon || -L Resources/AppIcon.icon ]]; then
    ICON_OUTPUT="$BUILD_STAGE/icons"
    scripts/build-icons.sh "$PROJECT_ROOT/Resources/AppIcon.icon" "$ICON_OUTPUT"
    cp "$ICON_OUTPUT/Assets.car" "$APP/Contents/Resources/Assets.car"
    cp "$ICON_OUTPUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    # Merge only the compiler's icon keys, preserving the app's other metadata.
    for icon_key in CFBundleIconName CFBundleIconFile; do
        icon_value="$(plutil -extract "$icon_key" raw -expect string "$ICON_OUTPUT/partial.plist")"
        [[ "$icon_value" == AppIcon ]] || fail "Unexpected compiled icon basename: $icon_value"
        plutil -replace "$icon_key" -string "$icon_value" "$APP/Contents/Info.plist"
    done
else
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [[ -f Resources/MenuBarTemplate.pdf ]]; then
    cp Resources/MenuBarTemplate.pdf "$APP/Contents/Resources/MenuBarTemplate.pdf"
fi

# Bundle.module resolves resources outside Contents/Resources. Copy localized
# resources explicitly so the app remains portable after leaving the build machine.
if compgen -G ".build/release/*.bundle" >/dev/null; then
    fail "SwiftPM resource bundles are not supported; use Bundle.main resources."
fi
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/KeyboardShortcuts.bundle"
cp -R Packages/KeyboardShortcuts/Sources/KeyboardShortcuts/Localization/*.lproj \
    "$APP/Contents/Resources/KeyboardShortcuts.bundle/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
check_bundle "$APP"
case "$SIGN_MODE" in
    signed) codesign --force --sign "$MATCHES" --identifier "$BUNDLE_ID" "$APP" ;;
    adhoc) codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" ;;
esac
if [[ "$SIGN_MODE" != unsigned ]]; then codesign --verify --deep --strict "$APP"; fi

if [[ "$INSTALL" == true ]]; then
    NEW_SIGNATURE="$(signature "$APP")"
    [[ -z "$INSTALLED_SIGNATURE" || "$NEW_SIGNATURE" == "$INSTALLED_SIGNATURE" ]] || fail "Installed and new signing identifier, team, certificate chain, or designated requirement differ; installation refused."
    INSTALL_STAGE="$(mktemp -d "$INSTALL_ROOT/.camcord-install.XXXXXX")"
    check_path "$INSTALL_STAGE"
    ditto "$APP" "$INSTALL_STAGE/Camcord.app"
    check_bundle "$INSTALL_STAGE/Camcord.app"
    [[ "$(signature "$INSTALL_STAGE/Camcord.app")" == "$NEW_SIGNATURE" ]] || fail "Staged signature differs; installation refused."
    require_stopped
    check_path "$INSTALL_APP"
    # Recheck the installed app after staging so a concurrent replacement is refused.
    if [[ -n "$INSTALLED_SIGNATURE" ]]; then
        check_bundle "$INSTALL_APP"
        [[ "$(signature "$INSTALL_APP")" == "$INSTALLED_SIGNATURE" ]] || fail "Installed app changed during staging."
        BACKUP="$INSTALL_STAGE/previous-Camcord.app"
        mv "$INSTALL_APP" "$BACKUP"
        OLD_MOVED=true
    else
        [[ ! -e "$INSTALL_APP" ]] || fail "An app appeared at the installation path during staging."
    fi
    mv "$INSTALL_STAGE/Camcord.app" "$INSTALL_APP"
    NEW_MOVED=true
    [[ "$(signature "$INSTALL_APP")" == "$NEW_SIGNATURE" ]] || fail "Installed signature differs after replacement."
    INSTALL_COMMITTED=true
    [[ -z "$BACKUP" ]] || echo "Previous installation retained at: $BACKUP"
fi

# Keep the previous locally built bundle too; never delete other dist contents.
check_path "$PROJECT_ROOT/dist/Camcord.app"
if [[ -e dist/Camcord.app ]]; then
    mv dist/Camcord.app "$BUILD_STAGE/previous-Camcord.app"
    KEEP_BUILD_STAGE=true
fi
mv "$APP" dist/Camcord.app
if [[ "$INSTALL" == true ]]; then
    open -g "$INSTALL_APP" || fail "Installed successfully, but background launch failed. Previous installation remains at: ${BACKUP:-none}"
    echo "Installed and launched $INSTALL_APP in the background."
else
    echo "Built $PROJECT_ROOT/dist/Camcord.app ($SIGN_MODE)."
fi
