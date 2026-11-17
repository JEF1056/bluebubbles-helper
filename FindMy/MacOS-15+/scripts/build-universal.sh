#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="$ROOT_DIR/BlueBubblesHelper.xcworkspace"
SCHEME="BlueBubblesHelper DyLib"
BUILD_DIR="$ROOT_DIR/.build/universal"
DIST_DIR="$ROOT_DIR/dist"
PRODUCT="BlueBubblesFindMyHelper.dylib"

mkdir -p "$DIST_DIR"

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    export DEVELOPER_DIR

    if ! cmp -s "$ROOT_DIR/Podfile.lock" "$ROOT_DIR/Pods/Manifest.lock"; then
        printf 'Podfile.lock and Pods/Manifest.lock differ; run pod install before building.\n' >&2
        exit 1
    fi

    build_architecture() {
        local architecture="$1"
        local derived_data="$BUILD_DIR/$architecture"

        xcodebuild \
            -quiet \
            -workspace "$WORKSPACE" \
            -scheme "$SCHEME" \
            -configuration Release \
            -destination "generic/platform=macOS" \
            -derivedDataPath "$derived_data" \
            ARCHS="$architecture" \
            VALID_ARCHS="x86_64 arm64 arm64e" \
            ONLY_ACTIVE_ARCH=NO \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            build
    }

    build_architecture x86_64
    build_architecture arm64
    build_architecture arm64e

    X86_PRODUCT="$BUILD_DIR/x86_64/Build/Products/Release/$PRODUCT"
    ARM_PRODUCT="$BUILD_DIR/arm64/Build/Products/Release/$PRODUCT"
    ARM64E_PRODUCT="$BUILD_DIR/arm64e/Build/Products/Release/$PRODUCT"
    OUTPUT="$DIST_DIR/$PRODUCT"

    lipo -create "$X86_PRODUCT" "$ARM_PRODUCT" "$ARM64E_PRODUCT" -output "$OUTPUT"
else
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    for ARCH in x86_64 arm64 arm64e; do
        ARCH_DIR="$BUILD_DIR/$ARCH"
        mkdir -p "$ARCH_DIR"
        xcrun --sdk macosx swiftc \
            -O \
            -target "${ARCH}-apple-macos15.0" \
            -sdk "$SDKROOT" \
            -parse-as-library \
            -c "$ROOT_DIR/BlueBubblesHelper/FindMyDeviceSnapshot.swift" \
            -o "$ARCH_DIR/FindMyDeviceSnapshot.o"

        xcrun --sdk macosx clang \
            -arch "$ARCH" \
            -dynamiclib \
            -O2 \
            -fobjc-arc \
            -fmodules \
            -Wno-deprecated-declarations \
            -isysroot "$SDKROOT" \
            -mmacosx-version-min=15.0 \
            -install_name "@rpath/$PRODUCT" \
            -current_version 1.0.0 \
            -compatibility_version 1.0.0 \
            -Wl,-rpath,/usr/lib/swift \
            -Wl,-rpath,@executable_path/../Frameworks \
            -Wl,-rpath,@loader_path/../Frameworks \
            -L"$SDKROOT/usr/lib/swift" \
            -I "$ROOT_DIR/BlueBubblesHelper" \
            -I "$ROOT_DIR/Pods/CocoaAsyncSocket/Source/GCD" \
            "$ROOT_DIR/BlueBubblesHelper/ServerConnection.m" \
            "$ROOT_DIR/BlueBubblesHelper/FindMyFriendPayload.m" \
            "$ROOT_DIR/BlueBubblesHelper/FindMyFriendsRefreshCoordinator.m" \
            "$ROOT_DIR/BlueBubblesHelper/FindMyDevicesDataSourceCapture.m" \
            "$ROOT_DIR/BlueBubblesHelper/FindMyDeviceSnapshotBridge.m" \
            "$ROOT_DIR/BlueBubblesHelper/FindMyDevicesRefreshCoordinator.m" \
            "$ROOT_DIR/BlueBubblesHelper/FindMyHelper.m" \
            "$ROOT_DIR/Pods/CocoaAsyncSocket/Source/GCD/GCDAsyncSocket.m" \
            "$ARCH_DIR/FindMyDeviceSnapshot.o" \
            -framework Foundation \
            -framework CoreLocation \
            -framework Security \
            -framework CFNetwork \
            -framework CoreServices \
            -o "$ARCH_DIR/$PRODUCT"
    done

    OUTPUT="$DIST_DIR/$PRODUCT"
    lipo -create \
        "$BUILD_DIR/x86_64/$PRODUCT" \
        "$BUILD_DIR/arm64/$PRODUCT" \
        "$BUILD_DIR/arm64e/$PRODUCT" \
        -output "$OUTPUT"
fi

lipo "$OUTPUT" -verify_arch x86_64 arm64 arm64e

INSTALL_NAME="$(otool -D "$OUTPUT" | tail -n 1 | xargs)"
EXPECTED_INSTALL_NAME="@rpath/$PRODUCT"
if [[ "$INSTALL_NAME" != "$EXPECTED_INSTALL_NAME" ]]; then
    printf 'Unexpected install name: %s (expected %s)\n' "$INSTALL_NAME" "$EXPECTED_INSTALL_NAME" >&2
    exit 1
fi

printf 'Built %s (%s)\n' "$OUTPUT" "$(lipo -archs "$OUTPUT")"
