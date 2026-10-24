#!/usr/bin/env bash
# Refreshes docs/user/images: Drop Sorter draws its shelf, chooser, toast and Settings tabs from a sample
# folder tree (--render-help-images), light and dark, at @2x. No Screen Recording permission needed.
# Usage: ./build.sh && scripts/make-help-images.sh
# The app runs with an empty temporary home folder (CFFIXED_USER_HOME), so the sample folders, config and
# history never touch the real ones and the images show "~/Documents/…" on every Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Drop Sorter.app/Contents/MacOS/DropSorter"
IMAGES=docs/user/images
fail() { echo "error: $*" >&2; exit 1; }
[[ -x "$APP" ]] || fail "$APP not found; run ./build.sh first"

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/home" "$WORK/images"

CFFIXED_USER_HOME="$WORK/home" "$APP" --render-help-images "$WORK/images" 2>"$WORK/log" \
  || { cat "$WORK/log" >&2; fail "rendering failed"; }

# Replace the whole set, so images the app no longer draws disappear (DocsTests flags unused ones).
mkdir -p "$IMAGES"
rm -f "$IMAGES"/*.png
cp "$WORK/images"/*.png "$IMAGES/"
echo "==> $(ls "$IMAGES"/*.png | wc -l | tr -d ' ') images in $IMAGES ($(du -sh "$IMAGES" | cut -f1))"
