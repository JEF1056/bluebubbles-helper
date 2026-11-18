#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/BlueBubblesHelper"
SOCKET_DIR="$ROOT_DIR/Pods/CocoaAsyncSocket/Source/GCD"
BUILD_DIR="$ROOT_DIR/.build/tests"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    else
        DEVELOPER_DIR="/Library/Developer/CommandLineTools"
    fi
fi

export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx clang \
    -fobjc-arc \
    -fmodules \
    -Wall \
    -Wextra \
    -Werror \
    -Wno-deprecated-declarations \
    -isysroot "$SDKROOT" \
    -mmacosx-version-min=15.0 \
    -I "$SOURCE_DIR" \
    -I "$SOCKET_DIR" \
    "$SOURCE_DIR/FindMyFriendPayload.m" \
    "$SOURCE_DIR/FindMyDevicesDataSourceCapture.m" \
    "$SOURCE_DIR/FindMyDevicesRefreshCoordinator.m" \
    "$SOURCE_DIR/FindMyFriendsRefreshCoordinator.m" \
    "$SOURCE_DIR/ServerConnection.m" \
    "$SOCKET_DIR/GCDAsyncSocket.m" \
    "$ROOT_DIR/Tests/FindMyFriendsTests.m" \
    -framework Foundation \
    -framework Security \
    -framework CFNetwork \
    -o "$BUILD_DIR/FindMyFriendsTests"

"$BUILD_DIR/FindMyFriendsTests"

xcrun --sdk macosx swiftc \
    -warnings-as-errors \
    -sdk "$SDKROOT" \
    "$SOURCE_DIR/FindMyDeviceSnapshot.swift" \
    "$ROOT_DIR/Tests/FindMyDeviceSnapshotTests.swift" \
    -o "$BUILD_DIR/FindMyDeviceSnapshotTests"

"$BUILD_DIR/FindMyDeviceSnapshotTests"

HOST_ARCH="$(uname -m)"
xcrun --sdk macosx swiftc \
    -warnings-as-errors \
    -parse-as-library \
    -target "${HOST_ARCH}-apple-macos15.0" \
    -sdk "$SDKROOT" \
    -c "$SOURCE_DIR/FindMyDeviceSnapshot.swift" \
    -o "$BUILD_DIR/FindMyDeviceSnapshot.o"

xcrun --sdk macosx clang \
    -fobjc-arc \
    -fmodules \
    -Wall \
    -Wextra \
    -Werror \
    -Wno-deprecated-declarations \
    -isysroot "$SDKROOT" \
    -mmacosx-version-min=15.0 \
    -I "$SOURCE_DIR" \
    -I "$SOCKET_DIR" \
    -L"$SDKROOT/usr/lib/swift" \
    -Wl,-rpath,/usr/lib/swift \
    "$SOURCE_DIR/FindMyFriendPayload.m" \
    "$SOURCE_DIR/FindMyDevicesDataSourceCapture.m" \
    "$SOURCE_DIR/FindMyDevicesRefreshCoordinator.m" \
    "$SOURCE_DIR/FindMyFriendsRefreshCoordinator.m" \
    "$SOURCE_DIR/FindMyDeviceSnapshotBridge.m" \
    "$SOURCE_DIR/FindMyHelper.m" \
    "$SOURCE_DIR/ServerConnection.m" \
    "$SOCKET_DIR/GCDAsyncSocket.m" \
    "$ROOT_DIR/Tests/FindMyHelperLiveTests.m" \
    "$BUILD_DIR/FindMyDeviceSnapshot.o" \
    -framework Foundation \
    -framework CoreLocation \
    -framework Security \
    -framework CFNetwork \
    -framework CoreServices \
    -o "$BUILD_DIR/FindMyHelperLiveTests"

"$BUILD_DIR/FindMyHelperLiveTests"
