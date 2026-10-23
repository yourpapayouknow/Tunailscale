#requires -Version 7.0
<#
.SYNOPSIS
    TSNativeTailscale 本地同步并调度 Mac 执行端到端集成测试
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MacHost,
    [Parameter(Mandatory)][string]$MacUser,
    [string]$RemoteDir = "~/build_tsnativeprobe"
)

$ErrorActionPreference = "Stop"

Write-Host "=== [1/3] Syncing test and source files to Mac ===" -ForegroundColor Cyan
$localRoot = $PSScriptRoot

# 阻止已知不受 tailscaled 支持的启动参数再次进入 App
if (Select-String -LiteralPath "$localRoot/src/ui/TSViewModel.swift" -SimpleMatch '"--operator') {
    throw "Unsupported tailscaled daemon flag found: --operator"
}

scp -r "${localRoot}/src" "${localRoot}/tests" "${localRoot}/patches" "${localRoot}/entitlements" "${MacUser}@${MacHost}:${RemoteDir}/"
if ($LASTEXITCODE -ne 0) {
    throw "Test source sync failed with exit code $LASTEXITCODE"
}

Write-Host "=== [2/3] Triggering automated integration tests on Mac ===" -ForegroundColor Cyan
ssh "${MacUser}@${MacHost}" "/bin/zsh -lc 'cd ${RemoteDir} && chmod +x tests/run_tests.sh && ./tests/run_tests.sh'"
if ($LASTEXITCODE -ne 0) {
    throw "Remote tests failed on Mac with exit code $LASTEXITCODE"
}

Write-Host "`nSUCCESS: Integration tests executed successfully!" -ForegroundColor Green
