#!/bin/zsh
set -e
cd "${0:A:h}"
[[ ! -L build && ! -L build/Payload ]] || { print -u2 'Refusing linked build directory'; exit 1; }

# 从矢量母版生成所有平台图标。
/usr/bin/swift scripts/icons.swift

# ==========================================
# TSNativeTailscale Build & Packaging Script
# Target: iOS / iPadOS (arm64, TrollStore)
# ==========================================

echo "=== [1/8] Detecting macOS Build Environment ==="
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
echo "Using iPhoneOS SDK: ${SDK_PATH}"

LDID_BIN="/opt/homebrew/bin/ldid"
if [ ! -x "${LDID_BIN}" ]; then
    LDID_BIN=$(which ldid || true)
fi

# 清理旧 Payload 确保打包结构绝对纯净
rm -rf build/Payload
mkdir -p build/Payload/TSNativeTailscale.app
mkdir -p dist

echo "=== [2/8] Building Tailscale Core Binaries (tailscaled & tailscale for iOS) ==="
/bin/zsh ./build_tailscaled.sh

cp build/tailscaled build/Payload/TSNativeTailscale.app/tailscaled
cp build/tailscale build/Payload/TSNativeTailscale.app/tailscale

echo "=== [3/8] Compiling root helper (tsprobe-helper) ==="
xcrun --sdk iphoneos clang -isysroot "${SDK_PATH}" \
    -target arm64-apple-ios15.0 \
    -O2 -Wall \
    src/helper/tsprobe_helper.c \
    src/common/utun_sys.c \
    src/common/probe_protocol.c \
    -o build/Payload/TSNativeTailscale.app/tsprobe-helper

echo "=== [4/8] Compiling CLI tool (tsnativeprobe-cli) ==="
xcrun --sdk iphoneos clang -isysroot "${SDK_PATH}" \
    -target arm64-apple-ios15.0 \
    -O2 -Wall \
    cli/cli.c \
    src/common/utun_sys.c \
    src/common/probe_protocol.c \
    -o dist/tsnativeprobe-cli

echo "=== [5/8] Compiling Objective-C Core & Swift UI App ==="
xcrun --sdk iphoneos clang -isysroot "${SDK_PATH}" \
    -target arm64-apple-ios15.0 \
    -O2 -Wall -fobjc-arc \
    -c src/app/SpawnRoot.m -o build/SpawnRoot.o

xcrun --sdk iphoneos clang -isysroot "${SDK_PATH}" \
    -target arm64-apple-ios15.0 \
    -O2 -Wall -fobjc-arc \
    -c src/tailscale/TSLocalAPI.m -o build/TSLocalAPI.o

xcrun --sdk iphoneos swiftc \
    -target arm64-apple-ios15.0 \
    -sdk "${SDK_PATH}" \
    -O \
    -import-objc-header src/ui/TSBridge-Header.h \
    build/SpawnRoot.o \
    build/TSLocalAPI.o \
    src/ui/TSTheme.swift \
    src/ui/TSLocalization.swift \
    src/ui/TSLogs.swift \
    src/ui/TSAccount.swift \
    src/ui/TSShareState.swift \
    src/ui/TSViewModel.swift \
    src/ui/SettingsView.swift \
    src/ui/AccountsView.swift \
    src/ui/TSFileTransfer.swift \
    src/ui/FilesView.swift \
    src/ui/DnsSettingsView.swift \
    src/ui/AboutView.swift \
    src/ui/HomeView.swift \
    src/ui/TSApp.swift \
    -framework UIKit \
    -framework SwiftUI \
    -framework Foundation \
    -framework AuthenticationServices \
    -framework QuickLook \
    -Xlinker -lobjc \
    -o build/Payload/TSNativeTailscale.app/TSNativeTailscale

# 构建真正的系统分享扩展，与主 App 复用账户和流式传输实现
SHARE_DIR="build/Payload/TSNativeTailscale.app/PlugIns/TSFileShare.appex"
mkdir -p "${SHARE_DIR}"
xcrun --sdk iphoneos swiftc \
    -target arm64-apple-ios15.0 -sdk "${SDK_PATH}" -O \
    -application-extension -parse-as-library -module-name TSFileShare \
    -import-objc-header src/ui/TSBridge-Header.h \
    build/SpawnRoot.o build/TSLocalAPI.o \
    src/ui/TSAccount.swift src/ui/TSShareState.swift src/ui/TSLogs.swift src/ui/TSFileTransfer.swift \
    src/ui/TSTheme.swift src/ui/TSLocalization.swift src/share/ShareController.swift \
    -framework UIKit -framework SwiftUI -framework Foundation \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "${SHARE_DIR}/TSFileShare"
cp src/share/Info.plist "${SHARE_DIR}/Info.plist"
chmod 755 "${SHARE_DIR}/TSFileShare"

echo "=== [6/8] Copying Info.plist, App Icons, and Setting Executable Permissions ==="
cp src/app/Info.plist build/Payload/TSNativeTailscale.app/Info.plist
cp THIRD_PARTY_NOTICES.md build/Payload/TSNativeTailscale.app/
cp -R licenses build/Payload/TSNativeTailscale.app/
# 将构建时间和传输源码指纹写入主 App 与分享扩展。
TS_BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(shasum -a 256 src/ui/TSFileTransfer.swift | cut -c 1-12)"
for TS_BUILD_INFO in build/Payload/TSNativeTailscale.app/Info.plist "${SHARE_DIR}/Info.plist"; do
    /usr/libexec/PlistBuddy -c "Add :TSBuildID string ${TS_BUILD_ID}" "${TS_BUILD_INFO}"
done
echo "Diagnostic build: ${TS_BUILD_ID}"
if [ -d "src/app/icons" ]; then
    cp -f src/app/icons/*.png build/Payload/TSNativeTailscale.app/
fi
chmod 755 build/Payload/TSNativeTailscale.app/TSNativeTailscale
chmod 755 build/Payload/TSNativeTailscale.app/tsprobe-helper
chmod 755 build/Payload/TSNativeTailscale.app/tailscaled
chmod 755 build/Payload/TSNativeTailscale.app/tailscale
chmod 755 dist/tsnativeprobe-cli

echo "=== [7/8] Signing All Mach-O Binaries and Sealing App Bundle ==="
"${LDID_BIN}" -Sentitlements/helper.plist build/Payload/TSNativeTailscale.app/tsprobe-helper
"${LDID_BIN}" -Sentitlements/helper.plist build/Payload/TSNativeTailscale.app/tailscaled
"${LDID_BIN}" -Sentitlements/helper.plist build/Payload/TSNativeTailscale.app/tailscale
"${LDID_BIN}" -Sentitlements/helper.plist dist/tsnativeprobe-cli
"${LDID_BIN}" -Sentitlements/app_b.plist build/Payload/TSNativeTailscale.app/TSNativeTailscale
"${LDID_BIN}" -Sentitlements/share.plist "${SHARE_DIR}/TSFileShare"

# 对整个 App Bundle 进行规范封印签名
codesign -s - --force --preserve-metadata=entitlements "${SHARE_DIR}"
codesign -s - --force --deep --preserve-metadata=entitlements build/Payload/TSNativeTailscale.app
codesign --verify --deep --strict build/Payload/TSNativeTailscale.app
codesign --verify --strict "${SHARE_DIR}"

echo "=== [8/8] Packaging Tunailscale.tipa ==="
rm -f dist/Tunailscale.tipa
(cd build && zip -r -9 ../dist/Tunailscale.tipa Payload)
# 保留既有测试下载地址，正式发布使用Tunailscale.tipa
cp dist/Tunailscale.tipa dist/TSNativeTailscale.tipa

echo "Computing SHA-256 checksums..."
(cd dist && shasum -a 256 Tunailscale.tipa TSNativeTailscale.tipa tsnativeprobe-cli > SHA256SUMS.txt)

echo "=== Build Complete ==="
cat dist/SHA256SUMS.txt
