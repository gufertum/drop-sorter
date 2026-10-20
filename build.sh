#!/usr/bin/env bash
# Runs the unit tests, then builds "build/dropsorter" (CLI), "build/Drop Mover.app" and "build/Drop Sorter.app".
# Usage: ./build.sh
# Drop Sorter is signed with a stable identity when one exists, so macOS privacy grants (e.g. access
# to a base folder in ~/Documents) survive rebuilds: DROPSORTER_SIGN_ID, else "Drop Sorter Local" (created by
# scripts/make-signing-identity.sh), else ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build
MIN_OS=13.0
SWIFTC=(swiftc -swift-version 5 -O)
CORE=(Sources/Core/*.swift)

rm -rf "$BUILD"
mkdir -p "$BUILD/obj"

echo "==> tests"
"${SWIFTC[@]}" "${CORE[@]}" Tests/*.swift -o "$BUILD/obj/tests"
"$BUILD/obj/tests"

echo "==> UI checks"
"${SWIFTC[@]}" "${CORE[@]}" Sources/DropSorter/ShelfPanel.swift Tests/UI/main.swift -o "$BUILD/obj/uitests"
"$BUILD/obj/uitests"

echo "==> dropsorter (command line)"
"${SWIFTC[@]}" -target "$(uname -m)-apple-macos$MIN_OS" "${CORE[@]}" Sources/CLI/main.swift -o "$BUILD/dropsorter"

echo "==> icon"
"${SWIFTC[@]}" Sources/DropMover/IconRenderer.swift Tools/make-icon/main.swift -o "$BUILD/obj/make-icon"
"$BUILD/obj/make-icon" "$BUILD/obj/AppIcon.iconset"
"$BUILD/obj/make-icon" "$BUILD/obj/SorterIcon.iconset" "Sorter"

echo "==> Drop Mover"
APP="$BUILD/Drop Mover.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
iconutil -c icns "$BUILD/obj/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Host architecture only: the Command Line Tools ship no x86_64 Swift compatibility libs.
"${SWIFTC[@]}" -target "$(uname -m)-apple-macos$MIN_OS" \
  "${CORE[@]}" Sources/DropMover/*.swift \
  -o "$APP/Contents/MacOS/DropMover"
cp Resources/DropMover/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The bundle is deliberately not sealed with codesign: each copy writes its config.json into
# Contents/Resources, which would invalidate a bundle signature. The binary keeps the linker's
# ad-hoc signature, which is all Apple Silicon needs to run a locally built app.
echo "==> built: $APP"

echo "==> Drop Sorter"
SORTER="$BUILD/Drop Sorter.app"
mkdir -p "$SORTER/Contents/MacOS" "$SORTER/Contents/Resources"
iconutil -c icns "$BUILD/obj/SorterIcon.iconset" -o "$SORTER/Contents/Resources/AppIcon.icns"
"${SWIFTC[@]}" -target "$(uname -m)-apple-macos$MIN_OS" \
  "${CORE[@]}" Sources/DropSorter/*.swift Sources/DropMover/IconRenderer.swift \
  -o "$SORTER/Contents/MacOS/DropSorter"
cp Resources/DropSorter/Info.plist "$SORTER/Contents/Info.plist"
# Template for generated Drop Mover apps. No .app extension, so Launch Services does not register it.
cp -R "$APP" "$SORTER/Contents/Resources/DropMoverTemplate"
# The command line tool ships inside the app; Settings links it into ~/.local/bin. Not in
# Contents/MacOS: APFS is case-insensitive, so "dropsorter" there would replace "DropSorter".
mkdir -p "$SORTER/Contents/Helpers"
cp "$BUILD/dropsorter" "$SORTER/Contents/Helpers/dropsorter"
if cmp -s "$SORTER/Contents/MacOS/DropSorter" "$SORTER/Contents/Helpers/dropsorter"; then
  echo "error: the app executable was replaced by the command line tool" >&2
  exit 1
fi
printf 'APPL????' > "$SORTER/Contents/PkgInfo"
# Drop Sorter keeps its state in Application Support, so its bundle can be sealed.
SIGN_ID="${DROPSORTER_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]] && security find-certificate -c "Drop Sorter Local" >/dev/null 2>&1; then
  SIGN_ID="Drop Sorter Local"
fi
# Nested code first, then the bundle.
codesign --force --sign "${SIGN_ID:--}" "$SORTER/Contents/Helpers/dropsorter"
codesign --force --sign "${SIGN_ID:--}" "$SORTER"
if [[ -n "$SIGN_ID" ]]; then
  echo "    signed with \"$SIGN_ID\""
else
  echo "    ad-hoc signature: privacy grants may be asked again after each rebuild (see scripts/make-signing-identity.sh)"
fi
echo "==> built: $SORTER"
