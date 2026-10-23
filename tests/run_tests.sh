#!/bin/zsh
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export GOTOOLCHAIN=go1.27.3

# 平台化 App 及子进程必须能够读写自己的账户数据容器
for ENTITLEMENTS in entitlements/app_b.plist entitlements/helper.plist entitlements/share.plist; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.private.security.storage.AppDataContainers' "$ENTITLEMENTS")" == true ]]
done
# 主 App 与扩展必须注册同一 App Group 和原生分享服务
for ENTITLEMENTS in entitlements/app_b.plist entitlements/share.plist; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$ENTITLEMENTS")" == group.com.iwmei.tunailscale ]]
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' src/share/Info.plist)" == com.apple.share-services ]]
echo "PASS: application and helper container access entitlements"
python3 -B tests/test_ui.py
python3 -B tests/test_release.py

# 导出必须保留完整日志，界面截断不能影响导出文件
mkdir -p build/test-viewmodel
xcrun swiftc -parse-as-library src/ui/TSLogs.swift tests/test_logs.swift -o build/test-viewmodel/test_logs
build/test-viewmodel/test_logs 2>build/test-viewmodel/logs-stderr.txt
# USB 系统日志必须包含阶段标记且不得泄露未脱敏密钥。
grep -Fq '[TSTransfer]' build/test-viewmodel/logs-stderr.txt
if grep -Fq 'trace_secret' build/test-viewmodel/logs-stderr.txt; then
    echo 'ERROR: unredacted transfer diagnostics'
    exit 1
fi

echo "=== [1/6] Checking native iOS interface ioctls ==="
# 从当前补丁编译 cgo 前导 C 代码，并拦截 ioctl 以免修改宿主网络
{
    awk '
        /^diff --git/ && source { exit }
        /^\+\+\+ b\/wgengine\/router\/osrouter\/router_userspace_ios.go$/ { source = 1; next }
        source && /^\+/ { print substr($0, 2) }
    ' patches/tailscale-ios-native-router.patch | sed -n '/^\/\*$/,/^\*\//p' | sed '1d;$d'
    cat tests/test_ios_router.c
} | xcrun --sdk macosx clang -x c -std=c11 -Wall -Wextra -Werror \
    -Dioctl=ts_ioctl -fsanitize=undefined -o /tmp/test_ios_router -
/tmp/test_ios_router

# 编译真实 ViewModel，使用受控回包覆盖状态与生命周期边界
mkdir -p build/test-viewmodel
cp /usr/bin/true build/test-viewmodel/tailscaled
xcrun swiftc -parse-as-library src/ui/TSViewModel.swift src/ui/TSLocalization.swift src/ui/TSAccount.swift src/ui/TSShareState.swift src/ui/TSLogs.swift \
    tests/test_viewmodel.swift -o build/test-viewmodel/test_viewmodel
build/test-viewmodel/test_viewmodel

# 真实文件系统验证官方 CLI 包装的账户隔离和数据完整性边界
xcrun swiftc -parse-as-library src/ui/TSAccount.swift src/ui/TSShareState.swift src/ui/TSLogs.swift src/ui/TSFileTransfer.swift \
    tests/test_transfer.swift -o build/test-viewmodel/test_transfer
build/test-viewmodel/test_transfer

# 拦截内核启动入口，检查真实 Objective-C 启动器传递的环境
xcrun clang -framework Foundation -fobjc-arc -Dposix_spawn=ts_spawn \
    src/app/SpawnRoot.m tests/test_spawn.m -o /tmp/test_spawn
/tmp/test_spawn

# 受控 HTTP 回包验证独立认证 socket 与真实账户解析
xcrun clang -framework Foundation -fobjc-arc src/tailscale/TSLocalAPI.m \
    tests/test_api_scope.m -o /tmp/test_api_scope
/tmp/test_api_scope

# 用真实 Unix HTTP 和模拟进程表覆盖异常响应及后台清理范围
xcrun clang -framework Foundation -fobjc-arc -fsanitize=undefined \
    src/tailscale/TSLocalAPI.m tests/test_http.m -o /tmp/test_http_audit
/tmp/test_http_audit
{ cat tests/test_terminate.c; sed -n '/^static int prcfail(/,/^\/\* 以 root 权限修改文件权限/p' src/helper/tsprobe_helper.c | sed '$d'; } | \
    xcrun clang -x c -Wall -Wextra -Wno-unused-function -fsanitize=undefined -o /tmp/test_terminate_audit -
/tmp/test_terminate_audit
{ cat tests/test_terminate_native.c; sed -n '/^static int prcfail(/,/^\/\* 只终止本 App 包内/p' src/helper/tsprobe_helper.c | sed '$d'; } | \
    xcrun clang -x c -Wall -Wextra -fsanitize=undefined -o /tmp/test_terminate_native -
/tmp/test_terminate_native --socket=/tmp/audit-main.sock
/tmp/test_terminate_native --socket /tmp/audit-main.sock

# 同版本官方 CLI 通过独立 Unix HTTP 端点验证真实文件协议
if [[ ! -x build/test-viewmodel/host-tailscale ]]; then
    (cd build/tailscale-src && go build -tags ts_omit_ssh,ts_omit_aws,ts_omit_kube -o ../test-viewmodel/host-tailscale ./cmd/tailscale)
fi
[[ "$(go version build/test-viewmodel/host-tailscale)" == *go1.27.3 ]]
python3 -B tests/test_file_cli.py "${PWD}/build/test-viewmodel/host-tailscale"

echo "=== [2/6] Cleaning up old test environment ==="
pkill -f "test-ts.sock" || true
rm -f /tmp/test-ts.sock /tmp/test-ts.state /tmp/test_localapi

echo "=== [3/6] Building native macOS test runner ==="
clang -framework Foundation -fobjc-arc \
    src/tailscale/TSLocalAPI.m \
    tests/test_localapi.m \
    -o /tmp/test_localapi

echo "=== [4/6] Starting isolated background tailscaled for testing ==="
DAEMON_BIN="${PWD}/build/test-viewmodel/host-tailscaled"
if [ ! -x "${DAEMON_BIN}" ]; then
    echo "Compiling host tailscaled..."
    (cd build/tailscale-src && go build -o ../test-viewmodel/host-tailscaled ./cmd/tailscaled)
fi
[[ "$(go version "$DAEMON_BIN")" == *go1.27.3 ]]

TS_FORCE_NOISE_443=1 ${DAEMON_BIN} \
    --socket=/tmp/test-ts.sock \
    --state=/tmp/test-ts.state \
    --tun=userspace-networking \
    --port=0 \
    > /tmp/test_tailscaled.log 2>&1 &
TS_PID=$!

echo "tailscaled started with PID: ${TS_PID}, waiting for socket..."
for i in {1..30}; do
    if [ -S /tmp/test-ts.sock ]; then
        echo "Socket /tmp/test-ts.sock is ready!"
        break
    fi
    sleep 0.2
done

if [ ! -S /tmp/test-ts.sock ]; then
    echo "ERROR: /tmp/test-ts.sock did not become ready!"
    cat /tmp/test_tailscaled.log
    kill -9 ${TS_PID} || true
    exit 1
fi

echo "=== [5/6] Executing automated LocalAPI test suite ==="
TEST_EXIT_CODE=0
/tmp/test_localapi /tmp/test-ts.sock || TEST_EXIT_CODE=$?

echo "=== [6/6] Cleaning up test daemon ==="
kill -9 ${TS_PID} || true
rm -f /tmp/test-ts.sock /tmp/test-ts.state /tmp/test_localapi /tmp/test_ios_router /tmp/test_viewmodel /tmp/test_spawn /tmp/test_api_scope

if [ ${TEST_EXIT_CODE} -eq 0 ]; then
    echo "\n>>> ALL AUTOMATED INTEGRATION TESTS PASSED 100%! <<<"
    exit 0
else
    echo "\n>>> TESTS FAILED WITH EXIT CODE: ${TEST_EXIT_CODE} <<<"
    exit ${TEST_EXIT_CODE}
fi
