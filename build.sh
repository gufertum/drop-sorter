#!/usr/bin/env bash
# Runs the unit tests, then builds "build/suggest", "build/Drop Mover.app" and "build/Drop Sorter.app".
# Usage: ./build.sh
# DROPSORTER_SIGN_ID="<codesigning identity>" signs Drop Sorter with a stable identity, so macOS
# privacy grants (e.g. access to ~/Documents) survive rebuilds; without it the app is signed ad hoc.
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

echo "==> suggest tool"
"${SWIFTC[@]}" "${CORE[@]}" Tools/suggest/main.swift -o "$BUILD/suggest"

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
  "${CORE[@]}" Sources/DropSorter/*.swift \
  -o "$SORTER/Contents/MacOS/DropSorter"
cp Resources/DropSorter/Info.plist "$SORTER/Contents/Info.plist"
printf 'APPL????' > "$SORTER/Contents/PkgInfo"
# Drop Sorter keeps its state in Application Support, so its bundle can be sealed.
codesign --force --sign "${DROPSORTER_SIGN_ID:--}" "$SORTER"
[[ -n "${DROPSORTER_SIGN_ID:-}" ]] || echo "    (ad-hoc signature: privacy grants may be asked again after each rebuild)"
echo "==> built: $SORTER"
