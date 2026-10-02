#!/usr/bin/env bash
#
# Turns the Ghostty.app that Xcode built into Maggie.app: its name, bundle ID,
# icon, version and update feed key. Signing is left to the caller
# (fork/install.sh locally, the release workflow on CI), since it differs.
#
# Usage: fork/package.sh <built Ghostty.app> <output Maggie.app> [options]
#
#   --version <string>   CFBundleShortVersionString, what people see (e.g. 2026.10.2)
#   --build <number>     CFBundleVersion, what Sparkle compares; must only go up
#   --commit <sha>       the commit built, shown in About
#   --source-root <dir>  the checkout to build updates from; sets the
#                        "Update Maggie from Source…" menu item. Local installs only.
#
# Override APP_NAME and BUNDLE_ID in the environment, as fork/install.sh does.

set -euo pipefail

APP_NAME="${APP_NAME:-Maggie}"
BUNDLE_ID="${BUNDLE_ID:-com.marciosete.maggie}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLISTBUDDY=/usr/libexec/PlistBuddy

BUILT="${1:?built app}"
OUT="${2:?output app}"
shift 2

VERSION=""
BUILD=""
COMMIT=""
SOURCE_ROOT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?}"; shift ;;
        --build) BUILD="${2:?}"; shift ;;
        --commit) COMMIT="${2:?}"; shift ;;
        --source-root) SOURCE_ROOT="${2:?}"; shift ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
ditto "$BUILT" "$OUT"
PLIST="$OUT/Contents/Info.plist"

echo "==> Renaming to $APP_NAME ($BUNDLE_ID)"
"$PLISTBUDDY" \
    -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    -c "Set :CFBundleName $APP_NAME" \
    -c "Set :CFBundleDisplayName $APP_NAME" \
    "$PLIST"

# Shown in About.
"$PLISTBUDDY" -c "Delete :NSHumanReadableCopyright" "$PLIST" 2>/dev/null || true
"$PLISTBUDDY" -c "Add :NSHumanReadableCopyright string © 2026 Marcio Sete. Built on Ghostty, © Mitchell Hashimoto and the Ghostty contributors. MIT License." "$PLIST"

[ -z "$VERSION" ] || "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[ -z "$BUILD" ] || "$PLISTBUDDY" -c "Set :CFBundleVersion $BUILD" "$PLIST"
[ -z "$COMMIT" ] || "$PLISTBUDDY" -c "Set :GhosttyCommit $COMMIT" "$PLIST"

"$PLISTBUDDY" -c "Delete :MaggieSourceRoot" "$PLIST" 2>/dev/null || true
[ -z "$SOURCE_ROOT" ] || "$PLISTBUDDY" -c "Add :MaggieSourceRoot string $SOURCE_ROOT" "$PLIST"

echo "==> Setting the icon"
# Built by fork/icon/compose.py: the photo at large sizes, the flat drawing at small
# ones. The build's own icon (images/Maggie.icon) is one layer, so it can't do that.
iconutil -c icns "$ROOT/fork/icon/Maggie.iconset" -o "$OUT/Contents/Resources/Maggie.icns"
# CFBundleIconName points at the icon in the asset catalog and takes precedence
# over CFBundleIconFile, so remove it.
"$PLISTBUDDY" -c "Set :CFBundleIconFile Maggie" "$PLIST"
"$PLISTBUDDY" -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true

echo "==> Setting the update feed key"
# Updates are verified against this key, never Ghostty's. Without it the app can't
# take an update from the feed, so a build from a checkout without the key is still
# usable, just not updatable.
PUBLIC_KEY="$ROOT/fork/sparkle-public.key"
if [ -s "$PUBLIC_KEY" ]; then
    "$PLISTBUDDY" -c "Set :SUPublicEDKey $(tr -d '[:space:]' <"$PUBLIC_KEY")" "$PLIST"
else
    echo "warning: no fork/sparkle-public.key; the app won't accept updates from the feed." >&2
    "$PLISTBUDDY" -c "Delete :SUPublicEDKey" "$PLIST" 2>/dev/null || true
fi
# Let Sparkle ask the person whether to check automatically, as Ghostty's releases do.
"$PLISTBUDDY" -c "Delete :SUEnableAutomaticChecks" "$PLIST" 2>/dev/null || true
