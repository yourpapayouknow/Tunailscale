#requires -Version 7.0
<#
.SYNOPSIS
    TSNativeTailscale 本地同步并调度局域网 Mac 构建脚本
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MacHost,
    [Parameter(Mandatory)][string]$MacUser,
    [string]$RemoteDir = "~/build_tsnativeprobe"
)

$ErrorActionPreference = "Stop"

Write-Host "=== [1/4] Preparing remote build directory on Mac ($MacHost) ===" -ForegroundColor Cyan
ssh "${MacUser}@${MacHost}" "/bin/zsh -lc 'mkdir -p ${RemoteDir}'"

Write-Host "=== [2/4] Syncing source files to Mac ===" -ForegroundColor Cyan
$localRoot = $PSScriptRoot
scp -r "${localRoot}/src" "${localRoot}/entitlements" "${localRoot}/cli" "${localRoot}/patches" "${localRoot}/scripts" "${localRoot}/build.sh" "${localRoot}/build_tailscaled.sh" "${MacUser}@${MacHost}:${RemoteDir}/"

Write-Host "=== [3/4] Triggering remote build on Mac ===" -ForegroundColor Cyan
ssh "${MacUser}@${MacHost}" "/bin/zsh -lc 'cd ${RemoteDir} && chmod +x build.sh build_tailscaled.sh && ./build.sh'"
if ($LASTEXITCODE -ne 0) {
    throw "Remote build failed on Mac with exit code $LASTEXITCODE"
}

Write-Host "=== [4/4] Fetching build artifacts from Mac ===" -ForegroundColor Cyan
if (-not (Test-Path "${localRoot}/dist")) {
    New-Item -ItemType Directory -Path "${localRoot}/dist" -Force | Out-Null
}

scp "${MacUser}@${MacHost}:${RemoteDir}/dist/TSNativeTailscale.tipa" "${localRoot}/dist/TSNativeTailscale.tipa"
scp "${MacUser}@${MacHost}:${RemoteDir}/dist/Tunailscale.tipa" "${localRoot}/dist/Tunailscale.tipa"
scp "${MacUser}@${MacHost}:${RemoteDir}/dist/tsnativeprobe-cli" "${localRoot}/dist/tsnativeprobe-cli"
scp "${MacUser}@${MacHost}:${RemoteDir}/dist/SHA256SUMS.txt" "${localRoot}/dist/SHA256SUMS.txt"

Write-Host "`nSUCCESS: Tunailscale.tipa retrieved successfully!" -ForegroundColor Green
Get-ChildItem -Path "${localRoot}/dist" | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
