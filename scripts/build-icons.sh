#!/bin/bash
set -euo pipefail
umask 077

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $# == 2 ]] || fail "Usage: $0 <source.icon> <empty-output-directory>"

SOURCE="$1"
OUTPUT="$2"
[[ -d "$SOURCE" && "$SOURCE" == *.icon ]] || fail "Icon Composer source must be an existing .icon directory: $SOURCE"
SOURCE="$(cd -P "$SOURCE" && pwd)"
ICON_NAME="$(basename "$SOURCE" .icon)"
[[ "$ICON_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || fail "Icon filename must contain only letters, numbers, underscores, or hyphens."
[[ -n "$OUTPUT" && "$OUTPUT" != */ && "$(basename "$OUTPUT")" != . && "$(basename "$OUTPUT")" != .. ]] || fail "Output must name a directory."
OUTPUT_PARENT="$(cd -P "$(dirname "$OUTPUT")" && pwd)"
OUTPUT="$OUTPUT_PARENT/$(basename "$OUTPUT")"
[[ "$OUTPUT" != "$SOURCE" && "$OUTPUT" != "$SOURCE"/* ]] || fail "Output must be outside the icon source."
[[ ! -L "$OUTPUT" ]] || fail "Symlink output refused: $OUTPUT"
if [[ ! -e "$OUTPUT" ]]; then mkdir "$OUTPUT"; fi
[[ -d "$OUTPUT" ]] || fail "Output is not a directory: $OUTPUT"
require_empty_output() {
    [[ -z "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "Output directory must be empty: $OUTPUT"
}
require_empty_output

# Only this private, newly created stage is ever removed.
TEMP_PARENT="$(cd -P "${TMPDIR:-/tmp}" && pwd)"
STAGE="$(mktemp -d "$TEMP_PARENT/camcord-icons.XXXXXX")"
cleanup() {
    local status=$? links
    trap - EXIT INT TERM
    if [[ -d "$STAGE" && ! -L "$STAGE" && "$STAGE" == "$TEMP_PARENT"/camcord-icons.* ]]; then
        links="$(find "$STAGE" -type l -print -quit)" || exit 1
        if [[ -z "$links" ]]; then
            rm -rf -- "$STAGE"
        else
            echo "ERROR: Symlink in private stage; retained for inspection: $STAGE" >&2
            status=1
        fi
    else
        echo "ERROR: Unsafe private stage; cleanup refused: $STAGE" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! xcrun actool --compile "$STAGE" --platform macosx \
    --minimum-deployment-target 26.0 --target-device mac \
    --app-icon "$ICON_NAME" --standalone-icon-behavior all \
    --output-partial-info-plist "$STAGE/partial.plist" \
    --warnings --notices --errors --output-format human-readable-text "$SOURCE" \
    > "$STAGE/actool.log" 2>&1; then
    cat "$STAGE/actool.log" >&2
    fail "Icon compilation failed."
fi
cat "$STAGE/actool.log"
if LC_ALL=C grep -Eiq '(^|[[:space:]])(warning|error):|com\.apple\.actool\.[^[:space:]]*(warnings|errors)' "$STAGE/actool.log"; then
    fail "Icon compiler reported warnings or errors."
fi
for artifact in Assets.car "$ICON_NAME.icns" partial.plist; do
    [[ -s "$STAGE/$artifact" && ! -L "$STAGE/$artifact" ]] || fail "Missing or invalid compiler output: $artifact"
done
plutil -lint "$STAGE/partial.plist" >/dev/null
for key in CFBundleIconName CFBundleIconFile; do
    value="$(plutil -extract "$key" raw -expect string "$STAGE/partial.plist")" || fail "Missing compiler icon key: $key"
    [[ "$value" == "$ICON_NAME" ]] || fail "Compiler $key does not match generated basename '$ICON_NAME'."
done

require_empty_output
for artifact in Assets.car "$ICON_NAME.icns" partial.plist; do
    chmod 0644 "$STAGE/$artifact"
    (umask 022; cp -n "$STAGE/$artifact" "$OUTPUT/$artifact")
    cmp -s "$STAGE/$artifact" "$OUTPUT/$artifact" || fail "Output changed during publication: $artifact"
done
echo "Compiled $ICON_NAME into $OUTPUT"
