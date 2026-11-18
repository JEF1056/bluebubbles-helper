#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$HELPER_DIR/../../.." && pwd)"
SOCKET_DIR="$REPO_ROOT/Messages/MacOS-11+/Pods/CocoaAsyncSocket/Source/GCD"
BUILD_DIR="/tmp/bb-facetime-tests"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
DYLIB_PATH="$REPO_ROOT/build/FaceTime/BlueBubblesFaceTimeHelper.dylib"

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
    -Wno-deprecated-declarations \
    -isysroot "$SDKROOT" \
    -F"$SDKROOT/System/Library/PrivateFrameworks" \
    -mmacosx-version-min=11.0 \
    -include "$HELPER_DIR/PrefixHeader.pch" \
    -I "$HELPER_DIR" \
    -I "$HELPER_DIR/FaceTime" \
    -I "$HELPER_DIR/ZKSwizzle" \
    -I "$SOCKET_DIR" \
    "$HELPER_DIR/BlueBubblesFaceTimeHelper.m" \
    "$HELPER_DIR/NetworkController.m" \
    "$HELPER_DIR/ZKSwizzle/ZKSwizzle.m" \
    "$HELPER_DIR/CTBlockDescription.m" \
    "$SOCKET_DIR/GCDAsyncSocket.m" \
    "$SCRIPT_DIR/FaceTimeHelperTests.m" \
    -framework Foundation \
    -framework AppKit \
    -framework Security \
    -framework CFNetwork \
    -framework TelephonyUtilities \
    -framework IMCore \
    -o "$BUILD_DIR/FaceTimeHelperTests"

"$BUILD_DIR/FaceTimeHelperTests"

if [[ -f "$DYLIB_PATH" ]]; then
    cat << 'EOF' | xcrun --sdk macosx clang -x objective-c -isysroot "$SDKROOT" -framework Foundation -o "$BUILD_DIR/VerifyDylibLoad" -
#import <Foundation/Foundation.h>
#import <dlfcn.h>
int main(int argc, const char *argv[]) {
    if (argc < 2) return 2;
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }
    Class cls = NSClassFromString(@"BLUEBUBBLESFACETIMEHELPER");
    if (!cls) {
        fprintf(stderr, "BLUEBUBBLESFACETIMEHELPER class missing\n");
        return 1;
    }
    printf("PASS: dlopen(%s) loaded BLUEBUBBLESFACETIMEHELPER\n", argv[1]);
    return 0;
}
EOF
    "$BUILD_DIR/VerifyDylibLoad" "$DYLIB_PATH"
fi
