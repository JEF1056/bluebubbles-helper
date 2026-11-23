#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="/Users/jfan/Documents/bluebubbles-server/packages/server/appResources/private-api/macos11"
DYLIB_NAME="BlueBubblesCameraHook.dylib"
BUILD_DIR="$DIR/build"
mkdir -p "$BUILD_DIR" "$OUT_DIR"

FRAMEWORKS="-framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework CoreMedia -framework CoreVideo -framework Foundation -framework VideoToolbox"
CFLAGS="-fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter"

for ARCH in x86_64 arm64 arm64e; do
    clang -arch "$ARCH" -shared $CFLAGS $FRAMEWORKS "$DIR/BlueBubblesCameraHook.m" -o "$BUILD_DIR/${DYLIB_NAME}.${ARCH}"
done

lipo -create \
    "$BUILD_DIR/${DYLIB_NAME}.x86_64" \
    "$BUILD_DIR/${DYLIB_NAME}.arm64" \
    "$BUILD_DIR/${DYLIB_NAME}.arm64e" \
    -output "$OUT_DIR/$DYLIB_NAME"

codesign -f -s - "$OUT_DIR/$DYLIB_NAME"
md5 -q "$OUT_DIR/$DYLIB_NAME" > "$OUT_DIR/${DYLIB_NAME}.md5"

# Build & run unit test
clang -arch arm64 $CFLAGS $FRAMEWORKS "$DIR/BlueBubblesCameraHook.m" "$DIR/BlueBubblesCameraHookTests.m" -o "$BUILD_DIR/BlueBubblesCameraHookTests"
"$BUILD_DIR/BlueBubblesCameraHookTests"

echo "Built and bundled $OUT_DIR/$DYLIB_NAME ($(cat "$OUT_DIR/${DYLIB_NAME}.md5"))"
