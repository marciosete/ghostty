#!/usr/bin/env bash
#
# Builds a release version of Maggie and installs it as its own app, next to the
# official Ghostty:
#
#   - named "Maggie" with its own bundle ID, so it has its own preferences, saved
#     workspace and Dock/⌘Tab entry
#   - with the Maggie icon from fork/icon
#   - never auto-updates (a fork must not update from the official feed)
#   - signed with a stable local certificate, so macOS privacy answers (Photos,
#     Documents, ...) survive reinstalls. Create it once with
#     fork/create-signing-identity.sh; without it the app is signed ad hoc.
#
# It reads the same Ghostty config file as the official app.
#
# Usage: fork/install.sh [--build-only | --install-staged [--after PID]]
#
#   (no option)        build and install; Maggie must not be running
#   --build-only       build and stage the app, without touching the installed one, so
#                      it can run while Maggie is open
#   --install-staged   install the staged app and open it. With --after, wait for that
#                      process (the running Maggie) to quit first
#
# Maggie's "Update Maggie…" menu item runs --build-only, then quits and leaves
# --install-staged --after <its pid> to put the new version in its place.
#
# Override with APP_NAME, BUNDLE_ID, DEST or SIGN_IDENTITY, e.g. DEST=~/Applications.

set -euo pipefail

APP_NAME="${APP_NAME:-Maggie}"
BUNDLE_ID="${BUNDLE_ID:-com.marciosete.maggie}"
DEST="${DEST:-/Applications}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Maggie Local Signing}"

# What the app was called before it was Maggie. An install under this ID is replaced,
# and its preferences (the saved workspace among them) and Application Support are
# copied over the first time.
LEGACY_BUNDLE_ID="com.marciosete.terminal-pro"
LEGACY_SIGN_IDENTITY="Ghostty Pro Local Signing"

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

is_ours() {
    [ "$1" = "$BUNDLE_ID" ] || [ "$1" = "$LEGACY_BUNDLE_ID" ]
}

# Only ever replace an app this script installed (never the official Ghostty).
if [ -e "$TARGET" ] && ! is_ours "$(bundle_id_of "$TARGET")"; then
    echo "error: $TARGET exists and isn't Maggie (bundle ID: $(bundle_id_of "$TARGET")). Not replacing it." >&2
    exit 1
fi

# Earlier installs under another name (e.g. before a rename) are replaced too.
installs=()
for app in "$DEST"/*.app; do
    is_ours "$(bundle_id_of "$app")" && installs+=("$app")
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

    # The checkout it was built from, which its "Update Maggie…" menu item builds.
    "$PLISTBUDDY" -c "Delete :MaggieSourceRoot" "$PLIST" 2>/dev/null || true
    "$PLISTBUDDY" -c "Add :MaggieSourceRoot string $ROOT" "$PLIST"

    echo "==> Setting the Maggie icon"
    # Built by fork/icon/compose.py: the photo at large sizes, the flat drawing at small
    # ones. The build's own icon (images/Maggie.icon) is one layer, so it can't do that.
    iconutil -c icns "$ROOT/fork/icon/Maggie.iconset" -o "$staging/Contents/Resources/Maggie.icns"

    # CFBundleIconName points at the icon in the asset catalog and takes precedence
    # over CFBundleIconFile, so remove it.
    "$PLISTBUDDY" -c "Set :CFBundleIconFile Maggie" "$PLIST"
    "$PLISTBUDDY" -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true

    # macOS ties privacy answers to the signature. An ad hoc one changes with every
    # build, so it would ask again after each install. The identity from before the
    # rename still works, and keeps the answers given to it.
    if security find-identity -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
        SIGN_WITH="$SIGN_IDENTITY"
    elif security find-identity -p codesigning | grep -qF "\"$LEGACY_SIGN_IDENTITY\""; then
        SIGN_WITH="$LEGACY_SIGN_IDENTITY"
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
    echo "       run fork/install.sh --install-staged after quitting it." >&2
    exit 1
}

# Preferences and Application Support are keyed by bundle ID. Bring the old ID's
# over, once, so the saved workspace and caches survive the rename.
migrate_legacy_state() {
    [ "$BUNDLE_ID" != "$LEGACY_BUNDLE_ID" ] || return 0

    local prefs="$HOME/Library/Preferences"
    if [ -f "$prefs/$LEGACY_BUNDLE_ID.plist" ] && [ ! -f "$prefs/$BUNDLE_ID.plist" ]; then
        echo "==> Copying preferences from $LEGACY_BUNDLE_ID"
        defaults export "$LEGACY_BUNDLE_ID" - | defaults import "$BUNDLE_ID" -
    fi

    local support="$HOME/Library/Application Support"
    if [ -d "$support/$LEGACY_BUNDLE_ID" ] && [ ! -d "$support/$BUNDLE_ID" ]; then
        echo "==> Copying Application Support from $LEGACY_BUNDLE_ID"
        ditto "$support/$LEGACY_BUNDLE_ID" "$support/$BUNDLE_ID"
    fi
}

install_staged() {
    if [ ! -d "$STAGED" ]; then
        echo "error: nothing staged at $STAGED. Run with --build-only first." >&2
        exit 1
    fi

    migrate_legacy_state

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
        # The app inherits this environment, and its terminals inherit the app's. The
        # overrides the updater passes in must not reach them, or a plain fork/install.sh
        # run from one of those terminals would pick them up.
        env -u APP_NAME -u BUNDLE_ID -u DEST -u SIGN_IDENTITY open "$TARGET"
        ;;
esac
