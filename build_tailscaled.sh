#!/bin/zsh
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export GOTOOLCHAIN=go1.27.3

echo "=== [1/3] Setting up environment for Tailscale iOS cross compilation ==="
SCRIPT_DIR=${0:A:h}
CORE_DIR="${SCRIPT_DIR}/build/tailscale-src"
CORE_REV=b83f28ebfbd9f86c2543e30e9dcf035a417dce1e

# 在项目内固定上游源码，不修改其他项目的检出
if [[ ! -e "$CORE_DIR" ]]; then
    mkdir -p "$CORE_DIR"
    git -C "$CORE_DIR" init
    git -C "$CORE_DIR" remote add origin https://github.com/tailscale/tailscale.git
    git -C "$CORE_DIR" fetch --depth 1 origin "$CORE_REV"
    git -C "$CORE_DIR" checkout --detach FETCH_HEAD
fi
cd "$CORE_DIR"
[[ "$(git rev-parse HEAD)" == "$CORE_REV" ]] || { print -u2 'Unexpected Tailscale checkout'; exit 1; }
go version

for PATCH_PATH in \
    "${SCRIPT_DIR}/patches/tailscale-ios-no-scutil.patch" \
    "${SCRIPT_DIR}/patches/tailscale-ios-native-router.patch"; do
    if git apply --reverse --check "${PATCH_PATH}" >/dev/null 2>&1; then
        echo "$(basename "${PATCH_PATH}") already applied."
    else
        git apply --check "${PATCH_PATH}"
        git apply "${PATCH_PATH}"
    fi
done

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG_PATH=$(xcrun --sdk iphoneos -find clang)

echo "SDK: ${SDK_PATH}"
echo "Clang: ${CLANG_PATH}"

mkdir -p "${SCRIPT_DIR}/build"

BUILD_TAGS="ios,ts_omit_ssh,ts_omit_aws,ts_omit_kube"

echo "=== [2/3] Compiling tailscaled (daemon) for Darwin/iOS arm64 with native utun support ==="
CGO_ENABLED=1 \
CC="${CLANG_PATH}" \
CGO_CFLAGS="-isysroot ${SDK_PATH} -target arm64-apple-ios15.0" \
CGO_LDFLAGS="-isysroot ${SDK_PATH} -target arm64-apple-ios15.0" \
GOOS=ios \
GOARCH=arm64 \
go build -trimpath -ldflags="-s -w" -tags "${BUILD_TAGS}" -o "${SCRIPT_DIR}/build/tailscaled" ./cmd/tailscaled

echo "=== [3/3] Compiling tailscale (CLI) for Darwin/iOS arm64 ==="
CGO_ENABLED=1 \
CC="${CLANG_PATH}" \
CGO_CFLAGS="-isysroot ${SDK_PATH} -target arm64-apple-ios15.0" \
CGO_LDFLAGS="-isysroot ${SDK_PATH} -target arm64-apple-ios15.0" \
GOOS=ios \
GOARCH=arm64 \
go build -trimpath -ldflags="-s -w" -tags "${BUILD_TAGS}" -o "${SCRIPT_DIR}/build/tailscale" ./cmd/tailscale

echo "=== Tailscale Mach-O binaries ready ==="
for CORE_BIN in tailscaled tailscale; do
    file "${SCRIPT_DIR}/build/${CORE_BIN}"
    [[ "$(go version "${SCRIPT_DIR}/build/${CORE_BIN}")" == *go1.27.3 ]]
done
