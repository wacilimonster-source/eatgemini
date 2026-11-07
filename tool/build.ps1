# eatgemini 桌面单文件版构建脚本（桌面文档 §12.2）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tool/build.ps1 [-Dart <dart.exe路径>] [-Version 0.1.0]
#
# 产物：build/eatgemini.exe（GUI 子系统，双击即用，无控制台窗口）

param(
  [string]$Dart = "",
  [string]$Version = "0.1.0"
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

Run-Step "1/6 依赖" { & $Dart pub get }
Run-Step "2/6 内嵌界面资源" { & $Dart run tool/embed_assets.dart }
Run-Step "3/6 测试" { & $Dart test }

if (Test-Path "build/eatgemini.exe") {
  # 上一个版本还在运行时 Windows 不允许覆盖；先提示而不是产出半成品。
  $running = Get-Process eatgemini -ErrorAction SilentlyContinue
  if ($running) {
    throw "build/eatgemini.exe 正在运行（PID $($running.Id)），请先从监控窗口退出再构建"
  }
}

Run-Step "4/6 编译 exe" {
  if (!(Test-Path "build")) { New-Item -ItemType Directory "build" | Out-Null }
  # -D 的值必须整体加引号，否则 PowerShell 不会展开变量（实测得到字面量 $Version）。
  $defines = @("-DAPP_VERSION=$Version")
  if ($commit) { $defines += "-DGIT_COMMIT=$commit" }
  & $Dart compile exe bin/eatgemini.dart -o build/eatgemini.exe @defines
}
Run-Step "5/6 修改 PE 子系统为 GUI" {
  & $Dart run tool/set_subsystem.dart build/eatgemini.exe --gui
}
Run-Step "6/6 发布校验" {
  & $Dart run tool/verify_release.dart build/eatgemini.exe --version $Version
}

Write-Host "完成：build/eatgemini.exe"
