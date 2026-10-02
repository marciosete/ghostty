#!/usr/bin/env bash
#
# The next release's version, from the commits since the last release, the way
# semantic-release reads conventional commits:
#
#   feat: …                          minor    0.1.4 → 0.2.0
#   fix: … / perf: …                 patch    0.1.4 → 0.1.5
#   feat!: … or "BREAKING CHANGE:"   major    0.1.4 → 1.0.0
#   anything else                    no release
#
# A scope is welcome and names what changed: feat(sidebar): …, fix(usage): ….
# Releases are tags, vMAJOR.MINOR.PATCH; nothing is written to the tree.
#
# Usage: fork/next-version.sh [--notes <file>]
#
# Prints "previous=…", "version=…" and "bump=…" (major, minor, patch or none),
# and with --notes writes the release notes, grouped by kind, to <file>.

set -euo pipefail

NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --notes) NOTES="${2:?}"; shift ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

previous="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 2>/dev/null || true)"
range="${previous:+$previous..}HEAD"

# One line per commit: hash, subject. Merges are skipped, as semantic-release does.
commits="$(git log --no-merges --format='%h %s' "$range")"

scope='(\([^)]+\))?'
breaking_subject="^[a-z]+$scope!: "
feature_subject="^feat$scope!?: "
fix_subject="^(fix|perf)$scope!?: "

bump=none
breaking=0
features=()
fixes=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    hash="${line%% *}"
    subject="${line#* }"
    [[ "$subject" =~ $breaking_subject ]] && breaking=1
    if [[ "$subject" =~ $feature_subject ]]; then
        features+=("$hash $subject")
    elif [[ "$subject" =~ $fix_subject ]]; then
        fixes+=("$hash $subject")
    fi
done <<<"$commits"
if git log --no-merges --format=%B "$range" | grep -q '^BREAKING CHANGE:'; then
    breaking=1
fi

if [ "$breaking" = 1 ]; then
    bump=major
elif [ "${#features[@]}" -gt 0 ]; then
    bump=minor
elif [ "${#fixes[@]}" -gt 0 ]; then
    bump=patch
fi

major=0; minor=0; patch=0
if [ -n "$previous" ]; then
    IFS=. read -r major minor patch <<<"${previous#v}"
fi
case "$bump" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
esac
version="$major.$minor.$patch"

echo "previous=$previous"
echo "version=$version"
echo "bump=$bump"

[ -n "$NOTES" ] || exit 0

# "feat(sidebar): folders" reads as "**sidebar:** folders" in the notes.
describe() {
    local hash="${1%% *}" subject="${1#* }"
    local rest="${subject#*: }"
    local head="${subject%%: *}"
    local scoped='\(([^)]+)\)' label=""
    [[ "$head" =~ $scoped ]] && label="**${BASH_REMATCH[1]}:** "
    echo "* $label$rest ($hash)"
}
{
    if [ "${#features[@]}" -gt 0 ]; then
        echo "### Features"
        echo
        for c in "${features[@]}"; do describe "$c"; done
        echo
    fi
    if [ "${#fixes[@]}" -gt 0 ]; then
        echo "### Bug Fixes"
        echo
        for c in "${fixes[@]}"; do describe "$c"; done
        echo
    fi
    if [ -n "$previous" ]; then
        echo "**Full changelog:** https://github.com/marciosete/maggie/compare/$previous...v$version"
    fi
} >"$NOTES"
