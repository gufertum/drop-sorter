#!/usr/bin/env bash
# Runs the unit tests, then builds "build/suggest" and "build/Drop Mover.app".
# Usage: ./build.sh
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
