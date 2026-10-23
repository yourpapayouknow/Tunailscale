#!/bin/zsh
set -e
set -o pipefail

# 构建独立视觉测试 App，不签特权权限或启动真实后台
ts_ui_root="${PWD}/build/ui-audit"
ts_ui_app="${ts_ui_root}/UIAudit.app"
ts_ui_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
ts_ui_device=${TS_UI_DEVICE:?Set TS_UI_DEVICE to an isolated iPhone simulator UDID}
mkdir -p "$ts_ui_app"
for ts_ui_source in SpawnRoot TSLocalAPI; do
    ts_ui_folder=app
    [[ "$ts_ui_source" == TSLocalAPI ]] && ts_ui_folder=tailscale
    xcrun --sdk iphonesimulator clang -isysroot "$ts_ui_sdk" -target arm64-apple-ios15.0-simulator -fobjc-arc \
        -c "src/${ts_ui_folder}/${ts_ui_source}.m" -o "${ts_ui_root}/${ts_ui_source}.o"
done
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios15.0-simulator -sdk "$ts_ui_sdk" -parse-as-library \
    -import-objc-header src/ui/TSBridge-Header.h "${ts_ui_root}/SpawnRoot.o" "${ts_ui_root}/TSLocalAPI.o" \
    src/ui/TSTheme.swift src/ui/TSLocalization.swift src/ui/TSLogs.swift src/ui/TSAccount.swift \
    src/ui/TSShareState.swift src/ui/TSViewModel.swift src/ui/SettingsView.swift src/ui/AccountsView.swift \
    src/ui/TSFileTransfer.swift src/ui/FilesView.swift src/ui/DnsSettingsView.swift src/ui/AboutView.swift \
    src/ui/HomeView.swift src/share/ShareController.swift tests/ui_snapshots.swift \
    -framework UIKit -framework SwiftUI -framework Foundation -framework AuthenticationServices -framework QuickLook \
    -o "${ts_ui_app}/UIAudit"
cp tests/ui_snapshots.plist "${ts_ui_app}/Info.plist"
cp src/app/icons/*.png "${ts_ui_app}/"
codesign -s - --force "$ts_ui_app"
xcrun simctl bootstatus "$ts_ui_device" -b
xcrun simctl install "$ts_ui_device" "$ts_ui_app"
xcrun simctl launch --console --terminate-running-process "$ts_ui_device" com.utunailscale.ui-audit 2>&1 | tee "${ts_ui_root}/run.log"
grep -Fq 'UIAudit complete:' "${ts_ui_root}/run.log"
ts_ui_data=$(xcrun simctl get_app_container "$ts_ui_device" com.utunailscale.ui-audit data)
mkdir -p "${ts_ui_root}/screenshots"
cp "${ts_ui_data}/Documents/"*.png "${ts_ui_root}/screenshots/"
# 只有超宽且前台的文字允许移动，短文字与后台画面必须保持静止
[[ "$(shasum -a 256 "${ts_ui_root}/screenshots/scroll-active-start.png" | cut -d ' ' -f 1)" != "$(shasum -a 256 "${ts_ui_root}/screenshots/scroll-active-later.png" | cut -d ' ' -f 1)" ]]
for ts_ui_mode in fit inactive; do
    cmp "${ts_ui_root}/screenshots/scroll-${ts_ui_mode}-start.png" "${ts_ui_root}/screenshots/scroll-${ts_ui_mode}-later.png"
done
print "PASS: overflow scrolls, fitting text and background stay still"
print "UI screenshots: ${ts_ui_root}/screenshots"
