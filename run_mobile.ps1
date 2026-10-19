# 部署 Kazumi 到已连接的安卓手机（跳过打包成 apk 文件那步）。
# 凭据从 build_local.env 读取（已 gitignore，切勿提交）。
# 用法：手机 USB 连好 + 开 USB 调试后，后台跑本脚本。
# 想退出调试会话：在运行它的终端按 q，或直接 job_kill。
$ErrorActionPreference = 'Continue'
$Repo = 'D:\Kazumi'
Set-Location $Repo
$env:PATH = 'D:\Tools\nuget;' + $env:PATH

# 当前手机设备 ID（PLR110 / Android 16 / arm64）。换手机时改这一行。
$device = '3B65C200QRF00000'

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

# --release：带凭据签名编译，弹幕/镜像正常；只看 UI 可改 --debug 热重载。
cmd /c "flutter run --release -d $device $def"
if ($LASTEXITCODE -ne 0) { Write-Error '部署失败，确认手机已连且 USB 调试已开' }
