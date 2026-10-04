<#
device_probe.ps1 —— 设备端只读验证：一个探针一条 adb 命令，不改设备上的任何东西

AGENTS.md「设备端 › 只读验证配方」那几条命令的命名入口（仓库根 package.json 里的 device:* 任务）。
-What 选探针（默认 all）：
    id      adbd 的 uid（uid=0 ⇒ 已被 picohaxx 提权）
    seccomp 这条 adb 线的 seccomp 过滤器计数（0 ⇒ 未过滤）
    hook    pxrstreamingservice 的 maps 里 frida-agent 命中数（>0 ⇒ hook 在）
    kit     设备 ~/pico_touch 与仓库自带 kit 逐文件比 md5（判设备上是不是当前版本）
    logs    设备 ~/pico_touch/logs 里最新一份的尾部 20 行

认设备：-Target → 缓存里记的地址 → adb devices 里唯一一台 device → 问用户。
读 Termux 家目录要 root；读不到就用 PC 侧 pico_touch.bat 跑一次（会把 kit chmod 755），或 adb root。

用法：
    powershell -NoProfile -File scripts\device_probe.ps1 [-What id]
    powershell -NoProfile -File scripts\device_probe.ps1 -What kit -Target 192.168.137.108:5555
#>
[CmdletBinding()]
param(
    # 探针名；all = 依次跑全部，有一条失败就 exit 1
    [ValidateSet('id', 'seccomp', 'hook', 'kit', 'logs', 'all')]
    [string]$What = 'all',
    # 目标设备（ip / ip:port / USB 序列号）；不传就按文件头说的顺序认
    [string]$Target,
    # adb.exe 路径；不传就自动找
    [string]$Adb,
    # Termux 前缀；非标准安装与测试用
    [string]$Prefix = '/data/data/com.termux/files'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. "$PSScriptRoot\..\src\windows\src\_utils.ps1"

$P = Get-RepoPaths -ScriptDir $PicoUtilsDir
$Adb = Get-AdbPath -Adb $Adb
$HomeDir = "$Prefix/home/pico_touch"  # 设备上的 kit 目录（push.bat / install.sh 装的那份）

function Add-Port {
    # 缓存里存的是裸 IPv4，喂给 adb 的无线目标要 ip:port
    param([string]$Value)
    if ($Value -match '^\d{1,3}(\.\d{1,3}){3}$') { return "$Value`:5555" }
    $Value
}

function Resolve-Target {
    # 按「-Target → 缓存 → adb 里唯一一台 → 问用户」认设备；用户取消返回 ''
    param([string]$Adb, [string]$Target, [string]$IpFile)

    if ($Target) { return (Add-Port -Value $Target) }

    if (Test-Path -LiteralPath $IpFile) {
        $saved = (Get-Content -LiteralPath $IpFile -Raw).Trim()
        if ($saved) { return (Add-Port -Value $saved) }
    }

    $devs = @(Get-AdbDevices -Adb $Adb -State 'device')
    if ($devs.Count -eq 1) { return $devs[0].Serial }
    if ($devs.Count -gt 1) {
        Write-Host '[i] adb 上连着多台设备，选一台：'
        for ($i = 0; $i -lt $devs.Count; $i++) { Write-Host ('    [{0}] {1}' -f ($i + 1), $devs[$i].Serial) }
        while ($true) {
            $a = "$(Read-Host '序号（回车=第 1 台）')".Trim()
            if (-not $a) { return $devs[0].Serial }
            if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $devs.Count) { return $devs[[int]$a - 1].Serial }
            Write-Host ("[X] 没看懂「{0}」，请输入 1-{1}" -f $a, $devs.Count) -ForegroundColor Red
        }
    }

    Write-Host '[i] 头显 IP 在哪看：头显里打开投屏 APP → 点「投至浏览器」，页面上那串地址就是它'
    while ($true) {
        $a = "$(Read-Host '头显地址（只填 IP 那段，可带端口；q=退出）')".Trim()
        if ($a -match '^(q|quit|取消)$') { return '' }
        if ($a -match '^\d{1,3}(\.\d{1,3}){3}(:\d+)?$') { return (Add-Port -Value $a) }
        Write-Host ("[X] 没看懂「{0}」，只填 IP 那一段，例如 192.168.137.108" -f $a) -ForegroundColor Red
    }
}

function Connect-Target {
    # 只认状态字段：不是 device 的无线目标先 connect 一次再看
    param([string]$Adb, [string]$Target)
    $st = Get-AdbDeviceState -Adb $Adb -Target $Target
    if ($st -ne 'device' -and $Target -match '^\d+\.\d+\.\d+\.\d+:\d+$') {
        try { & $Adb connect $Target 2>&1 | Out-Null }
        catch { Write-Host "[!] adb connect 报错：$($_.Exception.Message)" -ForegroundColor Yellow }
        Start-Sleep -Seconds 2
        $st = Get-AdbDeviceState -Adb $Adb -Target $Target
    }
    if ($st -eq 'device') { return $true }
    $why = if ($st) { $st } else { '不在 adb devices 里' }
    Write-Host ("[X] 设备 {0} 不可用（{1}）" -f $Target, $why) -ForegroundColor Red
    $false
}

function Invoke-AdbShell {
    # 一条远端命令，返回它的输出行（stderr 一起收：PS 5.1 在 EAP=Stop 下会把原生 stderr 当异常）
    param([string]$Adb, [string]$Target, [string]$Remote)
    try { @(& $Adb -s $Target shell $Remote 2>&1 | ForEach-Object { "$_" }) }
    catch { @("[adb] $($_.Exception.Message)") }
}

function Get-Lines {
    # 去掉空行（设备侧最后那个换行会留一行空的）
    param([string[]]$Text)
    @($Text | Where-Object { "$_".Trim() })
}

function Probe-Id {
    param([string]$Adb, [string]$Target)
    $text = (@(Get-Lines -Text (Invoke-AdbShell -Adb $Adb -Target $Target -Remote 'id')) -join ' ').Trim()
    if ($text -notmatch 'uid=\d+') { Write-Host "[X] id 没拿到 uid（设备掉线？）：$text" -ForegroundColor Red; return $false }
    Write-Host "[i] $text"
    if ($text -notmatch 'uid=0\(') { Write-Host '[!] adbd 不是 root：用 PC 侧 pico_touch.bat 提权（picohaxx）' -ForegroundColor Yellow }
    $true
}

function Probe-Seccomp {
    param([string]$Adb, [string]$Target)
    $remote = "grep -E '^Seccomp:' /proc/self/status"
    $text = (@(Get-Lines -Text (Invoke-AdbShell -Adb $Adb -Target $Target -Remote $remote)) -join ' ').Trim()
    if ($text -notmatch 'Seccomp:\s*(\d+)') { Write-Host "[X] 读不到 Seccomp：$text" -ForegroundColor Red; return $false }
    $n = [int]$Matches[1]
    Write-Host "[i] $text"
    if ($n -ne 0) { Write-Host "[!] 这条 adb 线被 seccomp 过滤（$n ≠ 0）：在它里面注入会被 SIGSYS 打死，换成 adb root 的那条线再跑" -ForegroundColor Yellow }
    $true
}

function Probe-Hook {
    param([string]$Adb, [string]$Target)
    # 一趟问完：进程在不在 + maps 里 frida-agent 的条数（读别人的 maps 要 root）
    # 远端命令里别出现双引号：PowerShell 会把它转义成 \" 原样带给 sh，[ -n "$p" ] 就恒真了（pidof -s 只取一个 pid，[ $p ] 不带引号也安全）
    $remote = 'p=$(pidof -s pxrstreamingservice); if [ $p ]; then echo PID=$p; grep -c frida-agent /proc/$p/maps; else echo NO_PID; fi'
    $lines = @(Get-Lines -Text (Invoke-AdbShell -Adb $Adb -Target $Target -Remote $remote))
    if (-not $lines) { Write-Host '[X] hook 探针没回话（设备掉线？）' -ForegroundColor Red; return $false }
    if ($lines[0] -eq 'NO_PID') {
        Write-Host '[!] pxrstreamingservice 没在跑：先让头显跑起业务串流（SteamVR 连着），再验 hook' -ForegroundColor Yellow
        return $true
    }
    if ($lines[0] -notmatch '^PID=(\d+)$') { Write-Host ("[X] 没看懂设备回的话：{0}" -f ($lines -join ' | ')) -ForegroundColor Red; return $false }
    $procId = $Matches[1]
    $rest = @($lines | Select-Object -Skip 1)
    if (-not $rest -or $rest[0] -notmatch '^\d+$') {
        Write-Host ("[X] 读不到 /proc/{0}/maps（{1}）：需要 adbd 是 root" -f $procId, ($rest -join ' | ')) -ForegroundColor Red
        return $false
    }
    $hits = [int]$rest[0]
    if ($hits -gt 0) {
        Write-Host ("[i] hook: pxrstreamingservice(pid {0}) maps 里 frida-agent 命中 {1} 次" -f $procId, $hits)
    }
    else {
        Write-Host ("[i] hook: pxrstreamingservice(pid {0}) 在跑，frida-agent 命中 0 次" -f $procId)
        Write-Host '[!] hook 没装上：用 PC 侧 pico_touch.bat 重新注入' -ForegroundColor Yellow
    }
    $true
}

function Probe-Kit {
    param([string]$Adb, [string]$Target, [string]$HomeDir, [hashtable]$Paths)
    $names = @('termux_touch.sh', 'install.sh', 'hook.js', 'start_touch.sh', 'picohaxx.neo3.bin')
    # 仓库里那份在哪：kit 四个在 src 下，picohaxx 在运行期缓存里
    $srcOf = @{
        'termux_touch.sh'   = Join-Path $Paths.Termux 'termux_touch.sh'
        'install.sh'        = Join-Path $Paths.Termux 'install.sh'
        'hook.js'           = Join-Path $Paths.Share 'hook.js'
        'start_touch.sh'    = Join-Path $Paths.Share 'start_touch.sh'
        'picohaxx.neo3.bin' = Join-Path $Paths.Cache 'picohaxx.neo3.bin'
    }
    $remote = 'md5sum ' + ((@($names | ForEach-Object { "$HomeDir/$_" })) -join ' ') + ' 2>&1'
    $lines = @(Get-Lines -Text (Invoke-AdbShell -Adb $Adb -Target $Target -Remote $remote))
    $dev = @{}
    foreach ($l in $lines) {
        if ($l -match '^([0-9a-fA-F]{32})\s+(\S+)$') { $dev[($Matches[2] -split '/')[-1]] = $Matches[1].ToLower() }
    }
    if ($dev.Count -eq 0) {
        Write-Host ("[X] 设备上没有可比的 kit：{0}" -f ($lines -join ' | ')) -ForegroundColor Red
        Write-Host "[i] $HomeDir 要么没装 kit（跑 PC 侧 pico_touch.bat），要么 adbd 不是 root 进不去 Termux 家目录（pico_touch.bat 会 chmod 755）" -ForegroundColor Yellow
        return $false
    }
    $same = 0
    foreach ($n in $names) {
        $src = $srcOf[$n]
        if (-not (Test-Path -LiteralPath $src)) { Write-Host ("[!] {0}：本地缺（{1}）" -f $n, $src) -ForegroundColor Yellow; continue }
        $local = (Get-FileHash -LiteralPath $src -Algorithm MD5).Hash.ToLower()
        if (-not $dev.ContainsKey($n)) { Write-Host ("[!] {0}：设备上没有（本地 {1}）" -f $n, $local) -ForegroundColor Yellow; continue }
        if ($dev[$n] -eq $local) {
            Write-Host ("[+] {0}  {1}  一致" -f $n, $local) -ForegroundColor Green
            $same++
        }
        else {
            Write-Host ("[!] {0}  设备 {1} ≠ 本地 {2}" -f $n, $dev[$n], $local) -ForegroundColor Yellow
        }
    }
    Write-Host ("[i] kit: {0}/{1} 与仓库一致（设备 {2}）" -f $same, $names.Count, $HomeDir)
    $true
}

function Probe-Logs {
    param([string]$Adb, [string]$Target, [string]$HomeDir)
    $dir = "$HomeDir/logs"
    # 最新一份 = mtime 最靠后的；读不到要说清是没日志、目录没装还是进不去（同样不带双引号）
    $remote = 'd=' + $dir + '; f=$(ls -t $d/*.log 2>/dev/null | head -n 1); if [ $f ]; then echo FILE=$f; tail -n 20 $f; elif [ ! -d $d ]; then echo NO_DIR; elif [ -r $d ]; then echo NO_LOG; else echo NO_ACCESS; fi'
    $lines = @(Invoke-AdbShell -Adb $Adb -Target $Target -Remote $remote)
    if (-not $lines) { Write-Host '[X] logs 探针没回话（设备掉线？）' -ForegroundColor Red; return $false }
    switch -Regex ("$($lines[0])".Trim()) {
        '^FILE=(.+)$' {
            Write-Host ("[i] 最新日志：{0}" -f $Matches[1])
            @($lines | Select-Object -Skip 1) | ForEach-Object { Write-Host "$_" }
            return $true
        }
        '^NO_LOG$' {
            Write-Host "[i] $dir 里还没有 *.log（在头显 Termux 里跑一次 dptouch 就会写）"
            return $true
        }
        '^NO_DIR$' {
            Write-Host ("[!] 设备上还没有 {0}：kit 没装，跑 PC 侧 pico_touch.bat" -f $dir) -ForegroundColor Yellow
            return $true
        }
        '^NO_ACCESS$' {
            Write-Host ("[X] 读不到 {0}：adbd 不是 root，进不去 Termux 家目录" -f $dir) -ForegroundColor Red
            Write-Host '[i] 用 PC 侧 pico_touch.bat 跑一次（会把 kit chmod 755），或 adb root' -ForegroundColor Yellow
            return $false
        }
        default {
            Write-Host ("[X] 没看懂设备回的话：{0}" -f ($lines -join ' | ')) -ForegroundColor Red
            return $false
        }
    }
}

$IpFile = Join-Path $P.Cache '.headset_ip'
$target = Resolve-Target -Adb $Adb -Target $Target -IpFile $IpFile
if (-not $target) { Write-Host '[X] 没认下设备（已取消）' -ForegroundColor Red; exit 1 }
if (-not (Connect-Target -Adb $Adb -Target $target)) { exit 1 }

$probes = @(switch ($What) {
        'all' { 'id', 'seccomp', 'hook', 'kit', 'logs' }
        default { $What }
    })
Write-Host "[i] 设备 $target" -ForegroundColor Cyan

$failed = @()
foreach ($name in $probes) {
    if ($probes.Count -gt 1) { Write-Host "[i] ===== $name =====" }
    $ok = switch ($name) {
        'id' { Probe-Id -Adb $Adb -Target $target }
        'seccomp' { Probe-Seccomp -Adb $Adb -Target $target }
        'hook' { Probe-Hook -Adb $Adb -Target $target }
        'kit' { Probe-Kit -Adb $Adb -Target $target -HomeDir $HomeDir -Paths $P }
        'logs' { Probe-Logs -Adb $Adb -Target $target -HomeDir $HomeDir }
    }
    if (-not $ok) { $failed += $name }
}
if ($failed.Count) {
    Write-Host ("[X] 失败：{0}" -f ($failed -join ' / ')) -ForegroundColor Red
    exit 1
}
exit 0
