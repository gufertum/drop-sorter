#!/usr/bin/env bash
# Creates a configured copy of the built Drop Mover app.
# Usage: scripts/install-copy.sh <folder> <app name> <target folder> [pattern]
#   scripts/install-copy.sh ~/Documents/Inbox "_archive-invoices" ~/Documents/Archive/Invoices
# The copy gets its own Contents/Resources/config.json; change it later in the app window.
set -euo pipefail

usage() { echo "usage: $0 <folder> <app name> <target folder> [pattern]" >&2; exit 2; }
[ $# -ge 3 ] && [ $# -le 4 ] || usage

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/build/Drop Mover.app"
FOLDER="$1"
NAME="${2%.app}"
TARGET="${3%/}"
DEFAULT_PATTERN='{date}_{time}_{name}{ext}'  # keep in sync with Renamer.defaultPattern
PATTERN="${4:-$DEFAULT_PATTERN}"
DEST="$FOLDER/$NAME.app"

fail() { echo "error: $*" >&2; exit 1; }
[ -d "$SRC" ]    || fail "no build at '$SRC', run ./build.sh first"
[ -d "$FOLDER" ] || fail "folder does not exist: $FOLDER"
[ -d "$TARGET" ] || fail "target folder does not exist: $TARGET"
[ -e "$DEST" ]   && fail "already exists: $DEST"
[[ "$NAME" == */* || -z "$NAME" ]] && fail "invalid app name: '$NAME'"

# Same token set as Renamer.swift; anything left in braces is a typo.
rest=$(printf '%s' "$PATTERN" | sed -E 's/\{(date|time|name|ext|original|date:[^{}]+)\}//g')
[[ "$rest" == *[{}]* ]] && fail "invalid pattern '$PATTERN' (tokens: {date} {time} {date:FORMAT} {name} {ext} {original})"
[[ "$rest" == */* ]] && fail "pattern must not contain '/': $PATTERN"

TARGET_ABS="$(cd "$TARGET" && pwd -P)"
cp -R "$SRC" "$DEST"
CFG="$DEST/Contents/Resources/config.json"
plutil -create xml1 "$CFG"
plutil -insert target -string "$TARGET_ABS" "$CFG"
plutil -insert pattern -string "$PATTERN" "$CFG"
plutil -convert json "$CFG"
echo "created: $DEST"
echo "  target:  $TARGET_ABS"
echo "  pattern: $PATTERN"
