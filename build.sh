#!/usr/bin/env bash
# Runs the unit tests, then builds "build/suggest", "build/Drop Mover.app" and "build/Drop Sorter.app".
# Usage: ./build.sh
# Drop Sorter is signed with a stable identity when one exists, so macOS privacy grants (e.g. access
# to a vault in ~/Documents) survive rebuilds: DROPSORTER_SIGN_ID, else "Drop Sorter Local" (created by
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
SIGN_ID="${DROPSORTER_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]] && security find-certificate -c "Drop Sorter Local" >/dev/null 2>&1; then
  SIGN_ID="Drop Sorter Local"
fi
codesign --force --sign "${SIGN_ID:--}" "$SORTER"
if [[ -n "$SIGN_ID" ]]; then
  echo "    signed with \"$SIGN_ID\""
else
  echo "    ad-hoc signature: privacy grants may be asked again after each rebuild (see scripts/make-signing-identity.sh)"
fi
echo "==> built: $SORTER"
