# 本地编译注入 Kazumi 的两套接口凭据
#   弹弹play  → DANDANAPI_APPID / DANDANAPI_KEY
#   Bangumi镜像 → KAZUMI_APPID / KAZUMI_KEY
#
# 目标平台必须显式指定，脚本不替你选：
#   .\build_local.ps1 -Windows     编译 Windows 桌面版并启动
#   .\build_local.ps1 -Windows -NoLaunch
#   .\build_local.ps1 -Android     转交 build_apk.ps1（编译 + 装机）
#   .\build_local.ps1 -Android -NoInstall
#   .\build_local.ps1 -Android -WithAnalyze
#
# 桌面包（仅 -Windows 有效，可叠加；不传就一个包都不打）：
#   .\build_local.ps1 -Windows -Msix -NoLaunch   出 msix 安装包
#   .\build_local.ps1 -Windows -Zip  -NoLaunch   出 zip 便携版
#   .\build_local.ps1 -Windows -Msix -Zip        两个都出
#
# 并行（两路同时跑，省一半墙钟）：
#   .\build_local.ps1 -Parallel -Zip              Android APK + Windows 编译/打包 同时跑
#   .\build_local.ps1 -Parallel -Msix -Zip        Android APK + Windows(msix+zip) 同时跑
#   .\build_local.ps1 -Parallel -WithAnalyze -NoInstall
#
#   -Parallel 自带 Android 与 Windows 两路，不能与 -Windows / -Android 叠加。
#   -NoInstall / -WithAnalyze / -Msix / -Zip 照常生效；
#   -WithAnalyze 在并行模式下由主进程只跑一次（analyze 与平台无关），失败则两路都不启动。
#   Windows 那路强制 -NoLaunch（后台构建，不弹 GUI）。
#   两路日志分别写 build\parallel\{android,windows}.log，不污染仓库根目录。
#
# 不带 -Windows / -Android / -Parallel 时直接报错退出 —— 构建哪个版本由用户决定。
param(
    [switch]$Windows,
    [switch]$Android,
    [switch]$Parallel,
    [switch]$NoLaunch,
    [switch]$NoInstall,
    [switch]$WithAnalyze,
    [switch]$Msix,
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$envFile = Join-Path $root 'build_local.env'
$TimingLog = 'D:\Work Folder\tools\timing.log'

# ---- 平台必须明示 ----
if ($Windows -and $Android) {
    Write-Host '-Windows 与 -Android 只能选一个' -ForegroundColor Red
    exit 1
}
if ($Parallel -and ($Windows -or $Android)) {
    Write-Host '-Parallel 已包含 Android 与 Windows 两路，不要再叠加 -Windows / -Android' -ForegroundColor Red
    exit 1
}
if (-not $Windows -and -not $Android -and -not $Parallel) {
    Write-Host '未指定构建目标。构建哪个版本由你决定，脚本不替你选：' -ForegroundColor Yellow
    Write-Host '  .\build_local.ps1 -Windows   # Windows 桌面版'
    Write-Host '  .\build_local.ps1 -Android   # Android APK'
    Write-Host '  .\build_local.ps1 -Parallel -Zip   # 两路并行（APK + Windows）'
    exit 1
}

# ---- 读取凭据 ----
if (-not (Test-Path -LiteralPath $envFile)) {
    Write-Host "缺少 $envFile" -ForegroundColor Red
    Write-Host '格式（四行）:'
    Write-Host 'DANDAN_APPID=xxx'
    Write-Host 'DANDAN_KEY=xxx'
    Write-Host 'MIRROR_APPID=xxx'
    Write-Host 'MIRROR_KEY=xxx'
    exit 1
}

$cred = @{}
Get-Content -LiteralPath $envFile | ForEach-Object {
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
# 只打印键名，不打印值，避免凭据进终端历史/日志
$defines | ForEach-Object { Write-Host "  $(($_ -split '=')[1])=***" }

# ---- Android：转交 build_apk.ps1 ----
if ($Android) {
    $apkScript = Join-Path $root 'build_apk.ps1'
    if (-not (Test-Path -LiteralPath $apkScript)) {
        Write-Host "缺少 $apkScript" -ForegroundColor Red
        exit 1
    }
    Write-Host '转交 build_apk.ps1（Android arm64）' -ForegroundColor Cyan
    $apkArgs = @('-NoProfile', '-File', $apkScript)
    if ($NoInstall) { $apkArgs += '-NoInstall' }
    if ($WithAnalyze) { $apkArgs += '-WithAnalyze' }
    & pwsh @apkArgs
    exit $LASTEXITCODE
}

# ---- 并行：Android 与 Windows 两路同时跑 ----
# 实测（2026-10-22）：单路串行约 547 s（apk 402 + windows 145），两路并行墙钟 403.6 s。
# 收益来自「apk 与 windows 用不同工具链、不同 build 子目录」;
# msix 与 zip 共享同一次 Windows 编译产物，所以只能在 Windows 这一路内部串行，不能各开一路。
if ($Parallel) {
    $apkScript = Join-Path $root 'build_apk.ps1'
    foreach ($s in @($apkScript, (Join-Path $root 'build_local.ps1'))) {
        if (-not (Test-Path -LiteralPath $s)) {
            Write-Host "缺少 $s" -ForegroundColor Red
            exit 1
        }
    }

    $parDir = Join-Path $root 'build\parallel'
    New-Item -ItemType Directory -Path $parDir -Force | Out-Null
    $logApk = Join-Path $parDir 'android.log'
    $logWin = Join-Path $parDir 'windows.log'
    $errApk = Join-Path $parDir 'android.err.log'
    $errWin = Join-Path $parDir 'windows.err.log'
    foreach ($f in @($logApk, $logWin, $errApk, $errWin)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    # analyze 与平台无关，并行时由主进程只跑一次；有 error 则两路都不启动。
    # （否则两路各跑一遍 analyze，既重复又在抢 CPU，实测并行下 analyze 会从 16 s 涨到 76 s）
    $analyzeSeconds = $null
    if ($WithAnalyze) {
        Write-Host ''
        Write-Host '======== flutter analyze（两路共用，只跑一次） ========' -ForegroundColor Cyan
        # 走 cmd /c 重定向到文件：与 build_apk.ps1 一致，也让本脚本的
        # $ErrorActionPreference='Stop' 不会把 flutter 写 stderr 的进度行当成异常抛出。
        $analyzeLog = Join-Path $parDir 'analyze.log'
        if (Test-Path -LiteralPath $analyzeLog) { Remove-Item -LiteralPath $analyzeLog -Force -ErrorAction SilentlyContinue }
        $swA = [Diagnostics.Stopwatch]::StartNew()
        Push-Location $root
        try {
            cmd /c "flutter analyze > `"$analyzeLog`" 2>&1"
            $analyzeCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $analyzeSeconds = [math]::Round($swA.Elapsed.TotalSeconds, 1)
        $analyzeText = if (Test-Path -LiteralPath $analyzeLog) {
            Get-Content -LiteralPath $analyzeLog -Raw -Encoding utf8
        } else { '' }
        if ($analyzeText) { Write-Host $analyzeText.TrimEnd() }
        $hasError = $analyzeText -match '(?m)^\s*error\s+-'
        $issueCount = ([regex]::Matches($analyzeText, '(?m)^\s*(info|warning|error)\s+-')).Count
        if ($analyzeCode -ne 0 -and $hasError) {
            Write-Host "flutter analyze 有 error 级问题（${analyzeSeconds}s），两路都不启动" -ForegroundColor Red
            exit 1
        }
        if ($issueCount -gt 0) {
            Write-Host "ANALYZE -> 无 error，另有 $issueCount 条 info/warning（不阻断），${analyzeSeconds}s" -ForegroundColor Yellow
        } else {
            Write-Host "ANALYZE -> No issues（${analyzeSeconds}s）" -ForegroundColor Green
        }
    }

    $pwshExe = (Get-Process -Id $PID).Path
    $apkArgs = @('-NoProfile', '-File', $apkScript)
    if ($NoInstall) { $apkArgs += '-NoInstall' }
    $winArgs = @('-NoProfile', '-File', (Join-Path $root 'build_local.ps1'), '-Windows', '-NoLaunch')
    if ($Msix) { $winArgs += '-Msix' }
    if ($Zip) { $winArgs += '-Zip' }

    Write-Host ''
    Write-Host '======== 两路并行启动 ========' -ForegroundColor Cyan
    Write-Host "  路 1  Android APK$(if ($NoInstall) { '（只编译不装机）' } else { '（编译 + 装机）' })"
    Write-Host "  路 2  Windows 编译$(if ($Msix -or $Zip) { ' + 打包' } else { '' })$(if ($Msix) { ' msix' })$(if ($Zip) { ' zip' })"
    Write-Host "  日志  $parDir" -ForegroundColor DarkGray

    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $parStartTime = Get-Date
    $swWall = [Diagnostics.Stopwatch]::StartNew()
    $swApk = [Diagnostics.Stopwatch]::StartNew()
    $procApk = Start-Process -FilePath $pwshExe -ArgumentList $apkArgs -WorkingDirectory $root `
        -NoNewWindow -PassThru -RedirectStandardOutput $logApk -RedirectStandardError $errApk
    $swWin = [Diagnostics.Stopwatch]::StartNew()
    $procWin = Start-Process -FilePath $pwshExe -ArgumentList $winArgs -WorkingDirectory $root `
        -NoNewWindow -PassThru -RedirectStandardOutput $logWin -RedirectStandardError $errWin

    # 两路各自一个秒表：谁先结束都能拿到自己的真实耗时。
    # ExitCode 只在 WaitForExit() 之后有效，且中途不要 Refresh()。
    $procApk.WaitForExit()
    $apkCode = $procApk.ExitCode
    $swApk.Stop()
    $apkSeconds = [math]::Round($swApk.Elapsed.TotalSeconds, 1)
    Write-Host ("  [路 1 完成] Android  {0} s  exit={1}" -f $apkSeconds, $apkCode) -ForegroundColor $(
        if ($apkCode -eq 0) { 'Green' } else { 'Red' })

    $procWin.WaitForExit()
    $winCode = $procWin.ExitCode
    $swWin.Stop()
    $swWall.Stop()
    $winSeconds = [math]::Round($swWin.Elapsed.TotalSeconds, 1)
    $wallSeconds = [math]::Round($swWall.Elapsed.TotalSeconds, 1)
    Write-Host ("  [路 2 完成] Windows  {0} s  exit={1}" -f $winSeconds, $winCode) -ForegroundColor $(
        if ($winCode -eq 0) { 'Green' } else { 'Red' })

    # ---- 计时汇总（两路的明细由各自脚本写进 timing.log，这里只记墙钟与并行收益） ----
    Write-Host ''
    Write-Host '======== 并行耗时 ========' -ForegroundColor Cyan
    $apkDisp = if ($null -ne $apkSeconds) { $apkSeconds } else { 0 }
    $parRows = @(
        [pscustomobject]@{ 步骤 = 'flutter analyze（共用一次）'; 秒 = $(if ($null -ne $analyzeSeconds) { $analyzeSeconds } else { 0 }) }
        [pscustomobject]@{ 步骤 = '路 1 Android'; 秒 = $apkDisp }
        [pscustomobject]@{ 步骤 = '路 2 Windows'; 秒 = $winSeconds }
        [pscustomobject]@{ 步骤 = '并行墙钟'; 秒 = $wallSeconds }
    )
    # 串行估算 = analyze + 两路各自耗时（不用墙钟，用各自实际耗时）
    $serialEstimate = [math]::Round($apkDisp + $winSeconds, 1)
    $parRows | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host ("两路并行墙钟 {0} s（取两路较长者）；串行约 {1} s，省 {2} s" -f `
        $wallSeconds, $serialEstimate, [math]::Round($serialEstimate - $wallSeconds, 1)) -ForegroundColor Cyan

    try {
        if (-not (Test-Path -LiteralPath $TimingLog)) {
            '时间,项目,步骤,秒' | Out-File -LiteralPath $TimingLog -Encoding utf8 -Append
        }
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        foreach ($r in $parRows) {
            "$stamp,并行构建,$($r.步骤),$($r.秒)" | Out-File -LiteralPath $TimingLog -Encoding utf8 -Append
        }
    } catch {
        Write-Host "写 timing.log 失败：$($_.Exception.Message)" -ForegroundColor Yellow
    }

    # ---- 两路产物 ----
    Write-Host ''
    Write-Host '======== 产物 ========' -ForegroundColor Cyan
    $parPackages = @()
    $apkPath = Join-Path $root 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
    if (Test-Path -LiteralPath $apkPath) {
        $parPackages += [pscustomobject]@{
            类型 = 'APK'; 路径 = $apkPath
            MB = [math]::Round((Get-Item -LiteralPath $apkPath).Length / 1MB, 2)
        }
    }
    $distDir = Join-Path $root 'build\windows\dist'
    # 只列本次真正打出来的包：按开关过滤，否则上一轮的 msix 会被当成这次的产物报出来。
    $wantExt = @()
    if ($Msix) { $wantExt += '.msix' }
    if ($Zip) { $wantExt += '.zip' }
    if ($wantExt.Count -gt 0) {
        Get-ChildItem -LiteralPath $distDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in $wantExt -and $_.LastWriteTime -ge $parStartTime } |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                $parPackages += [pscustomobject]@{
                    类型 = $_.Extension.TrimStart('.').ToUpper(); 路径 = $_.FullName
                    MB = [math]::Round($_.Length / 1MB, 2)
                }
            }
    }
    if ($parPackages.Count -gt 0) {
        $parPackages | Format-Table -AutoSize | Out-String | Write-Host
    } else {
        Write-Host '  未找到产物，检查 build\parallel\ 下的日志' -ForegroundColor Yellow
    }

    # build_apk.ps1 的退出码约定：0=构建并装机成功，2=构建成功但没装成（没设备），1=失败。
    # 手机常拔线，exit=2 不该让整条并行命令判红 —— 包已经出来了，只提示没装机。
    $apkBuiltNoInstall = ($apkCode -eq 2)
    $apkRealFail = ($apkCode -ne 0 -and $apkCode -ne 2)
    if ($apkBuiltNoInstall) {
        Write-Host '  [路 1 提示] APK 构建成功，但没有可用设备装机（产物已保留）' -ForegroundColor Yellow
    }

    if ($apkRealFail -or $winCode -ne 0) {
        Write-Host ''
        Write-Host "PARALLEL FAILED（Android exit=$apkCode, Windows exit=$winCode）" -ForegroundColor Red
        Write-Host "  日志：$logApk  /  $logWin" -ForegroundColor Yellow
        exit 1
    }
    Write-Host ''
    Write-Host "PARALLEL OK  ${wallSeconds}s" -ForegroundColor Green
    exit 0
}

# ---- Windows：本脚本自己构建 ----
$rows = [System.Collections.Generic.List[object]]::new()
function Add-Timing([string]$label, $sw) {
    $sw.Stop()
    $rows.Add([pscustomobject]@{
            步骤 = $label
            秒   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        })
}
$swTotal = [Diagnostics.Stopwatch]::StartNew()
$buildFailed = $false

Push-Location $root
try {
    if ($WithAnalyze) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $analyzeText = & flutter analyze 2>&1 | Out-String
        $analyzeCode = $LASTEXITCODE
        Write-Host $analyzeText
        Add-Timing 'flutter analyze' $sw
        # 与 build_apk.ps1 口径一致：只有 error 级阻断，info/warning 仅提示
        $hasError = $analyzeText -match '(?m)^\s*error\s+-'
        $issueCount = ([regex]::Matches($analyzeText, '(?m)^\s*(info|warning|error)\s+-')).Count
        if ($analyzeCode -ne 0 -and $hasError) {
            Write-Host 'flutter analyze 有 error 级问题，构建中止' -ForegroundColor Red
            throw 'analyze 失败'
        }
        if ($issueCount -gt 0) {
            Write-Host "ANALYZE -> 无 error，另有 $issueCount 条 info/warning（不阻断）" -ForegroundColor Yellow
        }
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    & flutter build windows --release @defines
    $buildCode = $LASTEXITCODE
    Add-Timing 'flutter build windows' $sw
    if ($buildCode -ne 0) { throw "flutter build 失败" }
} catch {
    $buildFailed = $true
    Write-Host $_.Exception.Message -ForegroundColor Red
} finally {
    Pop-Location
    # 注意：$swTotal 在下面的「计时表」之前才 Stop，好把打包耗时也算进合计
}

$outDir = Join-Path $root 'build\windows\x64\runner\Release'
# BINARY_NAME 在 windows/CMakeLists.txt 里是 KazumiPlus（无空格），故 exe 名如下。
# 带空格的 "Kazumi Plus.exe" 只在打 zip 时于 staging 目录内产生。
$exeName = 'KazumiPlus.exe'
$exe = Join-Path $outDir $exeName
$sizeMB = 'n/a'
if (Test-Path -LiteralPath $exe) {
    # 桌面产物是文件夹（exe + dll + data），量整个目录才反映真实体积
    $bytes = (Get-ChildItem -LiteralPath $outDir -Recurse -File |
            Measure-Object -Property Length -Sum).Sum
    $sizeMB = [math]::Round($bytes / 1MB, 2)
}

# ---- 计时表在打包之后统一打印（见文件末尾） ----

if ($buildFailed) {
    Write-Host 'BUILD FAILED' -ForegroundColor Red
    exit 1
}

Write-Host "BUILD OK  $exe  ($sizeMB MB)" -ForegroundColor Green

# ---- 版本号（用于产物命名） ----
$versionLine = (Select-String -LiteralPath (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value
$version = $versionLine.Split('+')[0].Trim()
$baseName = "KazumiPlus-$version-windows"

# ---- 打包（只在显式传 -Msix / -Zip 时才做） ----
$distDir = Join-Path $root 'build\windows\dist'
$packages = @()

if ($Msix -or $Zip) {
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Host "打包失败：找不到 $exe" -ForegroundColor Red
        exit 1
    }
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null

    # BINARY_NAME 从 kazumi 改成 KazumiPlus 后，CMake 不会删掉旧 target 的产物，
    # Release 里可能残留 kazumi.exe。打包前清掉，免得被打进 msix/zip。
    $legacyExe = Join-Path $outDir 'kazumi.exe'
    if (Test-Path -LiteralPath $legacyExe) {
        try {
            Remove-Item -LiteralPath $legacyExe -Force
            Write-Host '已清理遗留产物 kazumi.exe' -ForegroundColor Yellow
        } catch {
            Write-Host "清理遗留 kazumi.exe 失败（可能正在运行）：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# ---- MSIX ----
if ($Msix) {
    Write-Host ''
    Write-Host '======== 打包 MSIX ========' -ForegroundColor Cyan
    $msixCode = 1
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Push-Location $root
    try {
        # build_windows=false（见 pubspec.yaml），不重跑 flutter build，直接用现成产物
        & dart run msix:create --output-path $distDir --output-name $baseName
        $msixCode = $LASTEXITCODE
    } finally {
        Pop-Location
        Add-Timing 'msix:create' $sw
    }
    if ($msixCode -ne 0) { Write-Host 'MSIX 打包失败' -ForegroundColor Red; exit 1 }
    $msixPath = Join-Path $distDir "$baseName.msix"
    if (Test-Path -LiteralPath $msixPath) {
        $packages += [pscustomobject]@{
            类型 = 'MSIX'
            路径 = $msixPath
            MB   = [math]::Round((Get-Item -LiteralPath $msixPath).Length / 1MB, 2)
        }
    } else {
        Write-Host "MSIX 未生成预期文件：$msixPath" -ForegroundColor Yellow
        Get-ChildItem -LiteralPath $distDir -Filter '*.msix' | ForEach-Object {
            $packages += [pscustomobject]@{ 类型 = 'MSIX'; 路径 = $_.FullName; MB = [math]::Round($_.Length / 1MB, 2) }
        }
    }
}

# ---- ZIP 便携版 ----
if ($Zip) {
    Write-Host ''
    Write-Host '======== 打包 ZIP ========' -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $stageDir = Join-Path $distDir 'stage'
    try {
        if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force }
        # 顶层目录名带版本，解压后一眼看出是哪个版本
        $topDir = Join-Path $stageDir $baseName
        New-Item -ItemType Directory -Path $topDir -Force | Out-Null
        Copy-Item -Path (Join-Path $outDir '*') -Destination $topDir -Recurse -Force
        # 便携版要把 exe 显示名改成 "Kazumi Plus.exe"（Release 目录本身保持不动）
        $srcExe = Join-Path $topDir $exeName
        if (Test-Path -LiteralPath $srcExe) {
            Rename-Item -LiteralPath $srcExe -NewName 'Kazumi Plus.exe' -Force
        } else {
            Write-Host "staging 里找不到 $exeName，exe 名将保持原样" -ForegroundColor Yellow
        }
        $zipPath = Join-Path $distDir "$baseName.zip"
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Compress-Archive -Path $topDir -DestinationPath $zipPath -CompressionLevel Optimal
        if (Test-Path -LiteralPath $zipPath) {
            $packages += [pscustomobject]@{
                类型 = 'ZIP'
                路径 = $zipPath
                MB   = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
            }
        }
    } catch {
        $zipFailed = $true
        Write-Host "ZIP 打包失败：$($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Add-Timing 'zip 打包' $sw
        if (Test-Path -LiteralPath $stageDir) {
            Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($zipFailed) { exit 1 }
}

# ---- 计时表 ----
$swTotal.Stop()
Write-Host ''
Write-Host '======== 构建耗时 ========' -ForegroundColor Cyan
$rows | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("合计 {0} s" -f [math]::Round($swTotal.Elapsed.TotalSeconds, 1)) -ForegroundColor Cyan

# 追加持久日志
try {
    if (-not (Test-Path -LiteralPath $TimingLog)) {
        '时间,项目,步骤,秒' | Out-File -LiteralPath $TimingLog -Encoding utf8 -Append
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    foreach ($r in $rows) {
        "$stamp,Windows构建,$($r.步骤),$($r.秒)" | Out-File -LiteralPath $TimingLog -Encoding utf8 -Append
    }
    "$stamp,Windows构建,合计,$([math]::Round($swTotal.Elapsed.TotalSeconds,1))" | Out-File -LiteralPath $TimingLog -Encoding utf8 -Append
} catch {
    Write-Host "写 timing.log 失败：$($_.Exception.Message)" -ForegroundColor Yellow
}

# ---- 产物清单 ----
if ($packages.Count -gt 0) {
    Write-Host ''
    Write-Host '======== 产物 ========' -ForegroundColor Cyan
    $packages | Format-Table -AutoSize | Out-String | Write-Host
}

if (-not $NoLaunch) {
    Start-Process -FilePath $exe -WorkingDirectory $outDir
    Write-Host "已启动 $exeName" -ForegroundColor Green
}
