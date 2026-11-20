#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
BUILD_DIR="/tmp/bb-messages-tests"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
DYLIB_PATH="${1:-$REPO_ROOT/build/Messages/BlueBubblesHelper.dylib}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    else
        DEVELOPER_DIR="/Library/Developer/CommandLineTools"
    fi
fi

export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
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
    -F"$SDKROOT/System/Library/PrivateFrameworks" \
    -mmacosx-version-min=11.0 \
    "$SCRIPT_DIR/ReceiptGateTests.m" \
    -framework Foundation \
    -framework IMCore \
    -o "$BUILD_DIR/ReceiptGateTests"

"$BUILD_DIR/ReceiptGateTests" "$DYLIB_PATH"
