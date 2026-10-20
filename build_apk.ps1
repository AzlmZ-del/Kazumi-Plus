# 常驻 APK 构建：单架构 arm64 + 凭据从 build_local.env 注入，
# 编译完直接 adb 装机（不落桌面）。
#
# 凭据来自 build_local.env（已 gitignore，切勿提交），格式：
#   DANDAN_APPID=xxx
#   DANDAN_KEY=xxx
#   MIRROR_APPID=xxx
#   MIRROR_KEY=xxx
#
# 用法：
#   .\build_apk.ps1              编译并安装
#   .\build_apk.ps1 -NoInstall   只编译，产物留在 build 目录
param(
    [switch]$NoInstall
)

$ErrorActionPreference = 'Continue'
$Repo = 'D:\Kazumi'
Set-Location $Repo
$env:PATH = 'D:\Tools\nuget;' + $env:PATH

$Adb = 'D:\Tools\dev\android-sdk\platform-tools\adb.exe'

# ---- 读取凭据 ----
$envFile = Join-Path $Repo 'build_local.env'
if (-not (Test-Path -LiteralPath $envFile)) {
    Write-Error "缺少 $envFile（DANDAN_APPID / DANDAN_KEY / MIRROR_APPID / MIRROR_KEY）"
    exit 1
}
$cred = @{}
Get-Content -LiteralPath $envFile | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_]+)\s*=\s*(.+?)\s*$') { $cred[$Matches[1]] = $Matches[2] }
}
if (-not $cred['DANDAN_APPID'] -or -not $cred['DANDAN_KEY']) {
    Write-Error 'build_local.env 缺 DANDAN_APPID 或 DANDAN_KEY'
    exit 1
}

$defines = @(
    "--dart-define=DANDANAPI_APPID=$($cred['DANDAN_APPID'])",
    "--dart-define=DANDANAPI_KEY=$($cred['DANDAN_KEY'])"
)
if ($cred['MIRROR_APPID'] -and $cred['MIRROR_KEY']) {
    $defines += "--dart-define=KAZUMI_APPID=$($cred['MIRROR_APPID'])"
    $defines += "--dart-define=KAZUMI_KEY=$($cred['MIRROR_KEY'])"
}
$def = $defines -join ' '

# 单架构 arm64：splits.abi 只留 arm64-v8a（见 android/app/build.gradle）。
# 开了 splits 之后产物名是 app-arm64-v8a-release.apk，不再是 app-release.apk。
cmd /c "flutter build apk --release --target-platform android-arm64 $def > build_apk_log.txt 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Error 'APK 构建失败，日志见 build_apk_log.txt'
    exit 1
}

$apk = 'D:\Kazumi\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
if (-not (Test-Path -LiteralPath $apk)) {
    Write-Error "构建产物不存在: $apk"
    exit 1
}
$sizeMb = [math]::Round((Get-Item -LiteralPath $apk).Length / 1MB, 1)
Remove-Item -LiteralPath 'D:\Kazumi\build_apk_log.txt' -Force -ErrorAction SilentlyContinue
Write-Output "BUILD OK -> $apk ($sizeMb MB)"

if ($NoInstall) {
    Write-Output 'SKIP INSTALL (-NoInstall)'
    exit 0
}

# 设备检查
$devices = & $Adb devices |
    Select-Object -Skip 1 |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -match '\sdevice$' }
if (-not $devices) {
    Write-Output 'NO DEVICE: 没有检测到已授权的设备，产物保留在 build 目录'
    exit 2
}

Write-Output "INSTALL -> $($devices -join ', ')"
& $Adb install -r -d $apk 2>&1 | ForEach-Object { Write-Output "  $_" }
if ($LASTEXITCODE -ne 0) {
    Write-Error 'adb install 失败'
    exit 1
}
Write-Output "DONE -> 已安装到手机 ($sizeMb MB)"
