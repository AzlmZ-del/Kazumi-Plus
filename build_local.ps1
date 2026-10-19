# 本地编译注入 Kazumi 的两套接口凭据
#   弹弹play  → DANDANAPI_APPID / DANDANAPI_KEY
#   Bangumi镜像 → KAZUMI_APPID / KAZUMI_KEY
# 用法: .\build_local.ps1            (release 编译 + 启动)
#       .\build_local.ps1 -NoLaunch  (只编译不启动)
param([switch]$NoLaunch)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$envFile = Join-Path $root 'build_local.env'

if (-not (Test-Path $envFile)) {
    Write-Host "缺少 $envFile" -ForegroundColor Red
    Write-Host '格式（四行）:'
    Write-Host 'DANDAN_APPID=xxx'
    Write-Host 'DANDAN_KEY=xxx'
    Write-Host 'MIRROR_APPID=xxx'
    Write-Host 'MIRROR_KEY=xxx'
    exit 1
}

$cred = @{}
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_]+)\s*=\s*(.+?)\s*$') { $cred[$Matches[1]] = $Matches[2] }
}
# 兼容旧的两行写法
if (-not $cred['DANDAN_APPID'] -and $cred['APPID']) { $cred['DANDAN_APPID'] = $cred['APPID'] }
if (-not $cred['DANDAN_KEY'] -and $cred['SECRET']) { $cred['DANDAN_KEY'] = $cred['SECRET'] }

if (-not $cred['DANDAN_APPID'] -or -not $cred['DANDAN_KEY']) {
    Write-Host 'build_local.env 缺 DANDAN_APPID 或 DANDAN_KEY' -ForegroundColor Red
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

Write-Host "注入 $($defines.Count) 个 dart-define：" -ForegroundColor Cyan
$defines | ForEach-Object { Write-Host "  $_" }

Push-Location $root
try {
    flutter build windows --release @defines
    if ($LASTEXITCODE -ne 0) { throw "flutter build 失败" }
} finally {
    Pop-Location
}

if (-not $NoLaunch) {
    Start-Process -FilePath "$root\build\windows\x64\runner\Release\kazumi.exe" `
        -WorkingDirectory "$root\build\windows\x64\runner\Release"
    Write-Host '已启动 kazumi.exe' -ForegroundColor Green
}
