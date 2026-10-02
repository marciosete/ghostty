#!/usr/bin/env bash
#
# Builds Maggie.dmg: the drag-to-Applications window, with the magpie as the
# volume icon. The window's layout is the DS_Store next to this script, made
# once on a Mac by create-dmg (see background.py for the positions it encodes);
# putting it in the image needs no Finder, so this works on a headless runner.
#
# Usage: fork/dmg/build.sh <Maggie.app> <output.dmg>

set -euo pipefail

APP="${1:?app}"
OUT="${2:?output dmg}"
HERE="$(cd "$(dirname "$0")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/Maggie"

mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
cp "$HERE/background.tiff" "$STAGE/.background/background.tiff"
cp "$HERE/DS_Store" "$STAGE/.DS_Store"
cp "$APP/Contents/Resources/Maggie.icns" "$STAGE/.VolumeIcon.icns"

# A read-write image first, to mark the volume as having a custom icon (the
# kHasCustomIcon bit of its Finder info), then compressed into the one shipped.
hdiutil create -quiet -volname Maggie -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
MOUNT="$(hdiutil attach -nobrowse -readwrite -noverify "$WORK/rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')"
xattr -wx com.apple.FinderInfo \
    "00 00 00 00 00 00 00 00 04 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" \
    "$MOUNT"
sync
hdiutil detach -quiet "$MOUNT"

rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
echo "wrote $OUT"
