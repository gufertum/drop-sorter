#!/usr/bin/env bash
# Builds "build/<name>.app" (default "Drop Mover") after running the unit tests.
# Usage: ./build.sh ["App Name"]
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="${1:-Drop Mover}"
BUILD=build
APP="$BUILD/$APP_NAME.app"
MIN_OS=13.0
SWIFTC=(swiftc -swift-version 5 -O)

rm -rf "$BUILD"
mkdir -p "$BUILD/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> tests"
"${SWIFTC[@]}" Sources/Renamer.swift Sources/Config.swift Tests/main.swift -o "$BUILD/obj/tests"
"$BUILD/obj/tests"

echo "==> icon"
"${SWIFTC[@]}" Sources/IconRenderer.swift Tools/make-icon/main.swift -o "$BUILD/obj/make-icon"
"$BUILD/obj/make-icon" "$BUILD/obj/AppIcon.iconset"
iconutil -c icns "$BUILD/obj/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> app"
# Host architecture only: the Command Line Tools ship no x86_64 Swift compatibility libs.
"${SWIFTC[@]}" -target "$(uname -m)-apple-macos$MIN_OS" \
  Sources/main.swift Sources/Renamer.swift Sources/Config.swift Sources/IconRenderer.swift \
  -o "$APP/Contents/MacOS/DropMover"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The bundle is deliberately not sealed with codesign: each copy writes its config.json into
# Contents/Resources, which would invalidate a bundle signature. The binary keeps the linker's
# ad-hoc signature, which is all Apple Silicon needs to run a locally built app.
echo "==> built: $APP"
