# eatgemini 桌面单文件版构建脚本（桌面文档 §12.2）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tool/build.ps1 [-Dart <dart.exe路径>] [-Version 0.1.0]
#
# 产物：build/eatgemini.exe（GUI 子系统，双击即用，无控制台窗口）

param(
  [string]$Dart = "",
  [string]$Version = "0.1.0",
  [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if ($Dart -eq "") {
  $local = Join-Path $root ".tools/dart-sdk/bin/dart.exe"
  if (Test-Path $local) { $Dart = $local } else { $Dart = "dart" }
}

$commit = ""
try { $commit = (git rev-parse --short HEAD 2>$null) } catch {}

function Run-Step {
  param([string]$Name, [scriptblock]$Block)
  Write-Host "== $Name =="
  & $Block
  if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
    throw "$Name 失败（exit $LASTEXITCODE）"
  }
}

Run-Step "1/8 依赖" { & $Dart pub get }
Run-Step "2/8 内嵌界面资源" { & $Dart run tool/embed_assets.dart }
Run-Step "3/8 测试" { & $Dart test }

if (Test-Path "build/eatgemini.exe") {
  # 只有「正在运行的进程就是本次要覆盖的 build/eatgemini.exe」才拒绝；
  # 已安装版（%LOCALAPPDATA%\Programs\eatgemini\eatgemini.exe）在运行时不应误报。
  $targetExe = (Resolve-Path "build/eatgemini.exe").Path
  $running = Get-Process eatgemini -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -eq $targetExe } catch { $false }
  }
  if ($running) {
    throw "build/eatgemini.exe 正在运行（PID $($running.Id)），请先从监控窗口退出再构建"
  }
}

Run-Step "4/8 编译便携版 exe" {
  if (!(Test-Path "build")) { New-Item -ItemType Directory "build" | Out-Null }
  # -D 的值必须整体加引号，否则 PowerShell 不会展开变量（实测得到字面量 $Version）。
  $defines = @("-DAPP_VERSION=$Version")
  if ($commit) { $defines += "-DGIT_COMMIT=$commit" }
  & $Dart compile exe bin/eatgemini.dart -o build/eatgemini.exe @defines
}
Run-Step "5/8 便携版改 GUI 子系统" {
  & $Dart run tool/set_subsystem.dart build/eatgemini.exe --gui
}

if (!$SkipInstaller) {
  Run-Step "6/8 编译安装器并附加 payload" {
    $setupDefines = @("-DSETUP_VERSION=$Version")
    if ($commit) { $setupDefines += "-DGIT_COMMIT=$commit" }
    & $Dart compile exe bin/installer.dart -o build/eatgemini-setup-base.exe @setupDefines
    & $Dart run tool/set_subsystem.dart build/eatgemini-setup-base.exe --gui
    & $Dart run tool/attach_payload.dart build/eatgemini-setup-base.exe `
      build/eatgemini.exe "build/eatgemini-setup-v$Version.exe"
  }
  Run-Step "7/8 生成发布文件与 update.json" {
    Copy-Item "build/eatgemini.exe" "build/eatgemini-v$Version.exe" -Force
    & $Dart run tool/make_update_manifest.dart --version $Version --out build/update.json
  }
}

Run-Step "8/8 发布校验" {
  & $Dart run tool/verify_release.dart build/eatgemini.exe --version $Version
  if (!$SkipInstaller) {
    & $Dart run tool/verify_release.dart "build/eatgemini-setup-v$Version.exe" `
      --version $Version --expect-payload
  }
}

if (!$SkipInstaller) {
  Write-Host "完成：build/eatgemini.exe（便携版） + build/eatgemini-setup-v$Version.exe（安装版）"
} else {
  Write-Host "完成：build/eatgemini.exe（便携版）"
}
