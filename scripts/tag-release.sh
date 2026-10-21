#!/usr/bin/env bash
# Tags the release on main: annotated tag vX.Y.Z from VERSION. Pushing the tag is a separate step.
# Usage: scripts/tag-release.sh
# Checks: on main, clean tree, tag not taken, CHANGELOG.md has a dated "## [X.Y.Z] - YYYY-MM-DD" entry.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
fail() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must be X.Y.Z, found '$VERSION'"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "not on main"
git diff --quiet HEAD || fail "uncommitted changes"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG exists already"
grep -Eq "^## \[$VERSION\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" CHANGELOG.md \
  || fail "CHANGELOG.md needs a line '## [$VERSION] - $(date +%F)' (not 'unreleased')"

git tag -a "$TAG" -m "Drop Sorter $VERSION"
echo "tagged $TAG at $(git rev-parse --short HEAD); push with: git push origin $TAG"
