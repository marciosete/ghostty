#!/usr/bin/env bash
#
# Builds a release version of this fork and installs it as its own app, next to
# the official Ghostty:
#
#   - named "Ghostty Pro" with its own bundle ID, so it has its own preferences,
#     saved windows and Dock/⌘Tab entry
#   - uses Ghostty's Blueprint icon so it's easy to tell apart
#   - never auto-updates (a fork must not update from the official feed)
#   - signed with a stable local certificate, so macOS privacy answers (Photos,
#     Documents, ...) survive reinstalls. Create it once with
#     fork/create-signing-identity.sh; without it the app is signed ad hoc.
#
# It still reads the same Ghostty config file as the official app.
#
# Usage: fork/install-ghostty-pro.sh
#
# Override with APP_NAME, BUNDLE_ID, DEST or SIGN_IDENTITY, e.g. DEST=~/Applications.

set -euo pipefail

APP_NAME="${APP_NAME:-Ghostty Pro}"

# The bundle ID predates the "Ghostty Pro" name. It is never shown, and keeping it
# keeps saved windows and preferences across renames.
BUNDLE_ID="${BUNDLE_ID:-com.marciosete.terminal-pro}"
DEST="${DEST:-/Applications}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Ghostty Pro Local Signing}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$DEST/$APP_NAME.app"
PLISTBUDDY=/usr/libexec/PlistBuddy
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

bundle_id_of() {
    "$PLISTBUDDY" -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true
}

# Only ever replace an app this script installed (never the official Ghostty).
if [ -e "$TARGET" ] && [ "$(bundle_id_of "$TARGET")" != "$BUNDLE_ID" ]; then
    echo "error: $TARGET exists and isn't this fork (bundle ID: $(bundle_id_of "$TARGET")). Not replacing it." >&2
    exit 1
fi

# Earlier installs under another name (e.g. before a rename) are replaced too.
installs=()
for app in "$DEST"/*.app; do
    [ "$(bundle_id_of "$app")" = "$BUNDLE_ID" ] && installs+=("$app")
done

for app in ${installs[@]+"${installs[@]}"}; do
    if pgrep -qf "$app/Contents/MacOS/ghostty"; then
        echo "error: $(basename "$app" .app) is running. Quit it and run this again." >&2
        exit 1
    fi
done

echo "==> Building release app (this takes a few minutes)"
cd "$ROOT"
zig build -Doptimize=ReleaseFast -Dxcframework-target=native

BUILT="$ROOT/macos/build/ReleaseLocal/Ghostty.app"
if [ ! -d "$BUILT" ]; then
    echo "error: build output not found at $BUILT" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGED="$WORK/$APP_NAME.app"
ditto "$BUILT" "$STAGED"

echo "==> Renaming to $APP_NAME ($BUNDLE_ID)"
PLIST="$STAGED/Contents/Info.plist"
"$PLISTBUDDY" \
    -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    -c "Set :CFBundleName $APP_NAME" \
    -c "Set :CFBundleDisplayName $APP_NAME" \
    "$PLIST"

echo "==> Setting the Blueprint icon"
BLUEPRINT="$ROOT/macos/Assets.xcassets/Alternate Icons/BlueprintImage.imageset/macOS-AppIcon-1024px.png"
ICONSET="$WORK/icon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$BLUEPRINT" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$BLUEPRINT" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGED/Contents/Resources/GhosttyPro.icns"

# CFBundleIconName points at the official icon in the asset catalog and takes
# precedence over CFBundleIconFile, so remove it.
"$PLISTBUDDY" -c "Set :CFBundleIconFile GhosttyPro" "$PLIST"
"$PLISTBUDDY" -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true

# macOS ties privacy answers to the signature. An ad hoc one changes with every
# build, so it would ask again after each install.
if security find-identity -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
    SIGN_WITH="$SIGN_IDENTITY"
else
    echo "warning: no \"$SIGN_IDENTITY\" signing identity; signing ad hoc." >&2
    echo "         Run fork/create-signing-identity.sh to keep privacy permissions across installs." >&2
    SIGN_WITH=-
fi

echo "==> Re-signing (${SIGN_WITH/#-/ad hoc})"
# Changing Info.plist invalidates the signature. Keep the entitlements the build
# signed with.
codesign --force --deep --sign "$SIGN_WITH" \
    --preserve-metadata=entitlements,flags,runtime \
    "$STAGED"
codesign --verify --deep --strict "$STAGED"

echo "==> Installing to $TARGET"
for app in ${installs[@]+"${installs[@]}"}; do
    if [ "$app" != "$TARGET" ]; then
        echo "    removing previous install: $app"
        "$LSREGISTER" -u "$app" || true
    fi
    rm -rf "$app"
done
ditto "$STAGED" "$TARGET"
"$LSREGISTER" -f "$TARGET"

echo "==> Done. Open it with: open \"$TARGET\""
