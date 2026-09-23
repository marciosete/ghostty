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
# Usage: fork/install-ghostty-pro.sh [--build-only | --install-staged [--after PID]]
#
#   (no option)        build and install; Ghostty Pro must not be running
#   --build-only       build and stage the app, without touching the installed one, so
#                      it can run while Ghostty Pro is open
#   --install-staged   install the staged app and open it. With --after, wait for that
#                      process (the running Ghostty Pro) to quit first
#
# Ghostty Pro's "Update Ghostty Pro…" menu item runs --build-only, then quits and leaves
# --install-staged --after <its pid> to put the new version in its place.
#
# Override with APP_NAME, BUNDLE_ID, DEST or SIGN_IDENTITY, e.g. DEST=~/Applications.

set -euo pipefail

APP_NAME="${APP_NAME:-Ghostty Pro}"

# The bundle ID predates the "Ghostty Pro" name. It is never shown, and keeping it
# keeps saved windows and preferences across renames.
BUNDLE_ID="${BUNDLE_ID:-com.marciosete.terminal-pro}"
DEST="${DEST:-/Applications}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Ghostty Pro Local Signing}"

MODE=all
AFTER_PID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) MODE=build ;;
        --install-staged) MODE=install ;;
        --after) AFTER_PID="${2:?--after needs a process id}"; shift ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$DEST/$APP_NAME.app"

# Where --build-only leaves the app for --install-staged.
STAGED="$HOME/Library/Caches/$APP_NAME/Staged/$APP_NAME.app"
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

refuse_if_running() {
    for app in ${installs[@]+"${installs[@]}"}; do
        if pgrep -qf "$app/Contents/MacOS/ghostty"; then
            echo "error: $(basename "$app" .app) is running. Quit it and run this again." >&2
            exit 1
        fi
    done
}

build_and_stage() {
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
    local staging="$WORK/$APP_NAME.app"
    ditto "$BUILT" "$staging"

    echo "==> Renaming to $APP_NAME ($BUNDLE_ID)"
    PLIST="$staging/Contents/Info.plist"
    "$PLISTBUDDY" \
        -c "Set :CFBundleIdentifier $BUNDLE_ID" \
        -c "Set :CFBundleName $APP_NAME" \
        -c "Set :CFBundleDisplayName $APP_NAME" \
        "$PLIST"

    # The checkout it was built from, which its "Update Ghostty Pro…" menu item builds.
    "$PLISTBUDDY" -c "Delete :GhosttyProSourceRoot" "$PLIST" 2>/dev/null || true
    "$PLISTBUDDY" -c "Add :GhosttyProSourceRoot string $ROOT" "$PLIST"

    echo "==> Setting the Blueprint icon"
    BLUEPRINT="$ROOT/macos/Assets.xcassets/Alternate Icons/BlueprintImage.imageset/macOS-AppIcon-1024px.png"
    ICONSET="$WORK/icon.iconset"
    mkdir "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$BLUEPRINT" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$BLUEPRINT" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$staging/Contents/Resources/GhosttyPro.icns"

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
        "$staging"
    codesign --verify --deep --strict "$staging"

    echo "==> Staging at $STAGED"
    rm -rf "$STAGED"
    mkdir -p "$(dirname "$STAGED")"
    ditto "$staging" "$STAGED"
}

wait_for_quit() {
    [ -n "$AFTER_PID" ] || return 0
    echo "==> Waiting for process $AFTER_PID to quit"
    # Quitting can be cancelled; give up rather than wait forever.
    for _ in $(seq 1 600); do
        kill -0 "$AFTER_PID" 2>/dev/null || return 0
        sleep 0.2
    done
    echo "error: process $AFTER_PID is still running. The new version is staged at $STAGED;" >&2
    echo "       run fork/install-ghostty-pro.sh --install-staged after quitting it." >&2
    exit 1
}

install_staged() {
    if [ ! -d "$STAGED" ]; then
        echo "error: nothing staged at $STAGED. Run with --build-only first." >&2
        exit 1
    fi

    echo "==> Installing to $TARGET"
    for app in ${installs[@]+"${installs[@]}"}; do
        if [ "$app" != "$TARGET" ]; then
            echo "    removing previous install: $app"
            "$LSREGISTER" -u "$app" || true
        fi
        rm -rf "$app"
    done
    ditto "$STAGED" "$TARGET"
    rm -rf "$STAGED"
    "$LSREGISTER" -f "$TARGET"
}

case "$MODE" in
    all)
        refuse_if_running
        build_and_stage
        install_staged
        echo "==> Done. Open it with: open \"$TARGET\""
        ;;
    build)
        build_and_stage
        echo "==> Staged. Install it with: $0 --install-staged"
        ;;
    install)
        wait_for_quit
        refuse_if_running
        install_staged
        echo "==> Opening $TARGET"
        open "$TARGET"
        ;;
esac
