#!/usr/bin/env bash
# Builds the installable package: build/release/DropSorter-X.Y.Z-<arch>.zip (Drop Sorter.app, with the
# Drop Mover template and the command line tool inside) and its .sha256 file.
# Usage: scripts/make-release.sh
# Checks: clean tree; on the tag vX.Y.Z from VERSION, unless ALLOW_UNTAGGED=1 (test packages).
# The app is signed with the local identity (see build.sh), not with a Developer ID, and not
# notarized: docs/user/getting-started.md explains the first open.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
ARCH="$(uname -m)"
fail() { echo "error: $*" >&2; exit 1; }

git diff --quiet HEAD && [[ -z "$(git status --porcelain)" ]] || fail "uncommitted or untracked changes"
if [[ "${ALLOW_UNTAGGED:-0}" != 1 ]]; then
  [[ "$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)" == "$(git rev-parse HEAD)" ]] \
    || fail "HEAD is not tagged $TAG (scripts/tag-release.sh on main), or set ALLOW_UNTAGGED=1"
fi

./build.sh

OUT=build/release
ZIP="$OUT/DropSorter-$VERSION-$ARCH.zip"
mkdir -p "$OUT"
rm -f "$ZIP" "$ZIP.sha256"
# ditto keeps the bundle intact (symlinks, extended attributes, signature); Finder unpacks it.
ditto -c -k --sequesterRsrc --keepParent "build/Drop Sorter.app" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

# The package must unpack to a working, correctly signed app.
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/Drop Sorter.app" || fail "signature broken in $ZIP"
[[ -x "$CHECK/Drop Sorter.app/Contents/Helpers/dropsorter" ]] || fail "command line tool missing in $ZIP"
[[ -d "$CHECK/Drop Sorter.app/Contents/Resources/DropMoverTemplate" ]] || fail "Drop Mover template missing in $ZIP"

echo "==> $ZIP ($(du -h "$ZIP" | cut -f1)), $(cut -d' ' -f1 < "$ZIP.sha256")"
