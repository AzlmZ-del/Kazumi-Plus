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
#   .\build_apk.ps1 -WithAnalyze 先跑 flutter analyze 再编译
#
# 每一步都计时并打印耗时表，同时追加到 D:\Work Folder\tools\timing.log
# （CSV：时间,项目,步骤,秒）。用户 2026-10-21 要求：构建/推送必须逐步计时。
param(
    [switch]$NoInstall,
    [switch]$WithAnalyze
)

$ErrorActionPreference = 'Continue'
$Repo = 'D:\Kazumi'
Set-Location $Repo
$env:PATH = 'D:\Tools\nuget;' + $env:PATH
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'

$Adb = 'D:\Tools\dev\android-sdk\platform-tools\adb.exe'
$TimingLog = 'D:\Work Folder\tools\timing.log'

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Timing([string]$label, $sw) {
    $sw.Stop()
    $rows.Add([pscustomobject]@{
            步骤 = $label
            秒   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        })
}
$swTotal = [Diagnostics.Stopwatch]::StartNew()

# ---- 读取凭据 ----
$sw = [Diagnostics.Stopwatch]::StartNew()
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
Add-Timing '读取凭据' $sw

$defines = @(
    "--dart-define=DANDANAPI_APPID=$($cred['DANDAN_APPID'])",
    "--dart-define=DANDANAPI_KEY=$($cred['DANDAN_KEY'])"
)
if ($cred['MIRROR_APPID'] -and $cred['MIRROR_KEY']) {
    $defines += "--dart-define=KAZUMI_APPID=$($cred['MIRROR_APPID'])"
    $defines += "--dart-define=KAZUMI_KEY=$($cred['MIRROR_KEY'])"
}
$def = $defines -join ' '

# ---- 可选：静态检查 ----
if ($WithAnalyze) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    cmd /c "flutter analyze > build_analyze_log.txt 2>&1"
    $analyzeCode = $LASTEXITCODE
    $analyzeText = Get-Content -LiteralPath 'build_analyze_log.txt' -Raw
    Remove-Item -LiteralPath 'build_analyze_log.txt' -Force -ErrorAction SilentlyContinue
    Add-Timing 'flutter analyze' $sw
    # 本仓库存在 17 条历史 info 级 lint（unnecessary_underscores /
    # use_null_aware_elements / avoid_print），flutter analyze 会因此返回 1。
    # 只有真正的 error 才阻断构建，info/warning 只提示。
    $hasError = $analyzeText -match '(?m)^\s*error\s+-'
    $issueCount = ([regex]::Matches($analyzeText, '(?m)^\s*(info|warning|error)\s+-')).Count
    if ($analyzeCode -ne 0 -and $hasError) {
        Write-Error "flutter analyze 有 error 级问题，构建中止"
        exit 1
    }
    if ($issueCount -gt 0) {
        Write-Output "ANALYZE -> 无 error，另有 $issueCount 条历史 info/warning（不阻断）"
    }
}

# 单架构 arm64：--split-per-abi 让 Gradle 只产出含 arm64-v8a 的那个 APK。
# 注意这个标志是必须的 —— 没有它，flutter 工具链会去找 app-release.apk，
# 而 ABI 分裂后的产物叫 app-arm64-v8a-release.apk，找不到就判定构建失败。
$sw = [Diagnostics.Stopwatch]::StartNew()
cmd /c "flutter build apk --release --split-per-abi --target-platform android-arm64 $def > build_apk_log.txt 2>&1"
$buildCode = $LASTEXITCODE
Add-Timing 'flutter build apk' $sw
if ($buildCode -ne 0) {
    Write-Error 'APK 构建失败，日志见 build_apk_log.txt'
    exit 1
}

$apkDir = 'D:\Kazumi\build\app\outputs\flutter-apk'
$apk = Join-Path $apkDir 'app-arm64-v8a-release.apk'
if (-not (Test-Path -LiteralPath $apk)) {
    Write-Error "构建产物不存在: $apk"
    exit 1
}

# ---- 产物名归一（用户 2026-10-22 要求：只构建 arm64，包名统一为 app-arm64-v8a-release.apk）----
# 有人（含子代理）若直接跑 `flutter build apk --release --target-platform android-arm64`
# 而不带 --split-per-abi，会产出无 ABI 后缀的 app-release.apk，与正式产物混淆。
# 这里在构建成功后统一清掉，保证目录里只有 app-arm64-v8a-release.apk 这一个包。
Get-ChildItem -LiteralPath $apkDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'app-release.apk*' } |
    ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        Write-Output "CLEAN -> 已删除非 ABI 命名产物 $($_.Name)"
    }
$sizeMb = [math]::Round((Get-Item -LiteralPath $apk).Length / 1MB, 1)
Remove-Item -LiteralPath 'D:\Kazumi\build_apk_log.txt' -Force -ErrorAction SilentlyContinue
Write-Output "BUILD OK -> $apk ($sizeMb MB)"

if ($NoInstall) {
    $swTotal.Stop()
    $rows.Add([pscustomobject]@{ 步骤 = '合计'; 秒 = [math]::Round($swTotal.Elapsed.TotalSeconds, 1) })
    $rows | Format-Table -AutoSize | Out-String | Write-Output
    Write-Output 'SKIP INSTALL (-NoInstall)'
    exit 0
}

# 设备检查
$sw = [Diagnostics.Stopwatch]::StartNew()
$devices = & $Adb devices |
    Select-Object -Skip 1 |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -match '\sdevice$' }
Add-Timing 'adb devices' $sw
if (-not $devices) {
    Write-Output 'NO DEVICE: 没有检测到已授权的设备，产物保留在 build 目录'
    exit 2
}

Write-Output "INSTALL -> $($devices -join ', ')"
$sw = [Diagnostics.Stopwatch]::StartNew()
& $Adb install -r -d $apk 2>&1 | ForEach-Object { Write-Output "  $_" }
$installCode = $LASTEXITCODE
Add-Timing 'adb install' $sw
if ($installCode -ne 0) {
    Write-Error 'adb install 失败'
    exit 1
}
$swTotal.Stop()
$rows.Add([pscustomobject]@{ 步骤 = '合计'; 秒 = [math]::Round($swTotal.Elapsed.TotalSeconds, 1) })

$table = $rows | Format-Table -AutoSize | Out-String
Write-Output $table

# ---- 追加持久计时日志（表头只写一次）----
$enc = New-Object System.Text.UTF8Encoding $false
if (-not (Test-Path -LiteralPath $TimingLog)) {
    [IO.File]::WriteAllText($TimingLog, "时间,项目,步骤,秒`r`n", $enc)
}
$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
foreach ($r in $rows) {
    [IO.File]::AppendAllText($TimingLog, "$ts,Kazumi-Plus,$($r.步骤),$($r.秒)`r`n", $enc)
}

Write-Output "DONE -> 已安装到手机 ($sizeMb MB)"
