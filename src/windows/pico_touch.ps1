<#
  pico_touch.ps1 —— 一键恢复「DP 直连手柄电容触摸」

  ★ 注入在【头显本地】完成（frida-inject），PC 只负责提权和推文件。
    跑完之后可以拔掉 USB 线 / 关掉这个窗口，触摸照常工作。

  流程：
    1. 找头显：USB adb → 无线 adb（缓存 IP / ARP 探测）
    2. 确保无线 adb（adb tcpip 5555），之后拔线也不影响
    3. 用 picohaxx 拿临时 root（免解 BL、保数据）
    4. 推 frida-inject + hook.js + start_touch.sh
    5. 在设备上执行 start_touch.sh（幂等，已挂过会跳过）

  前置：头显与 PC 同一网段（PC 热点 192.168.137.x）。
        依赖二进制（frida-inject / picohaxx.neo3.bin）缺失时会自动调用同目录
        get_deps.ps1 从上游拉取；设备端脚本取自 ..\shared\。

  参数：
    -Adb     adb.exe 路径（默认自动探测 PATH 与常见安装位置）
    -Serial  USB 连接时的设备序列号（默认自动取 adb devices 里首个非 TCP 设备）

  用法：powershell -ExecutionPolicy Bypass -File pico_touch.ps1
#>
[CmdletBinding()]
param(
    [string]$Adb,
    [string]$Serial
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Share  = Join-Path (Split-Path -Parent $Here) 'shared'
$Haxx   = 'picohaxx.neo3.bin'
$Inj    = 'frida-inject'
$IpFile = Join-Path $Here '.headset_ip'

# --- adb：-Adb 参数 > PATH > 常见安装位置 ---
if (-not $Adb) {
    $Adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
    if (-not $Adb) {
        foreach ($c in @("$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
                         "$env:ProgramFiles\Android\platform-tools\adb.exe",
                         'D:\Programs\android-platform-tools\adb.exe')) {
            if (Test-Path $c) { $Adb = $c; break }
        }
    }
}
if (-not $Adb -or -not (Test-Path $Adb)) { Write-Host '[X] 找不到 adb.exe，请用 -Adb <路径> 指定' -ForegroundColor Red; exit 1 }

# 缺二进制（frida-inject / picohaxx）时自动从上游拉取
foreach ($f in @("$Here\$Haxx", "$Here\$Inj")) {
    if (-not (Test-Path $f)) {
        Write-Host "[*] 缺少 $(Split-Path -Leaf $f)，运行 get_deps.ps1 自动拉取..." -ForegroundColor Yellow
        & (Join-Path $Here 'get_deps.ps1')
        break
    }
}
foreach ($f in @("$Here\$Haxx", "$Here\$Inj", "$Share\hook.js", "$Share\start_touch.sh")) {
    if (-not (Test-Path $f)) { Write-Host "[X] 缺少 $f（详见 README）" -ForegroundColor Red; exit 1 }
}

# --- 序列号：-Serial 参数 > 自动取首个非 TCP 设备 ---
if (-not $Serial) {
    $Serial = (& $Adb devices) | Select-Object -Skip 1 |
              ForEach-Object { ($_ -split '\s+')[0] } |
              Where-Object { $_ -and $_ -notmatch ':' } |
              Select-Object -First 1
}

function TcpOpen([string]$h, [int]$p, [int]$ms = 400) {
    $c = New-Object Net.Sockets.TcpClient
    try { return $c.ConnectAsync($h, $p).Wait($ms) -and $c.Connected } catch { return $false } finally { $c.Dispose() }
}

Write-Host '=== 1/4 找头显 ===' -ForegroundColor Cyan
$target = $null

$usb = (& $Adb devices) -join "`n"
if ($Serial -and $usb -match [regex]::Escape($Serial)) {
    Write-Host '[+] USB adb 在线'
    $ip = (((& $Adb -s $Serial shell "ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+'") -join '') -replace 'inet', '').Trim()
    if ($ip -match '^\d+\.\d+\.\d+\.\d+$') {
        Set-Content -Path $IpFile -Value $ip -Encoding ascii
        Write-Host "[+] 头显 wlan0 = $ip"
        $target = "$ip`:5555"
    } else { Write-Host '[!] 取不到 wlan0 地址（Wi-Fi 没连？）' -ForegroundColor Yellow }
}

if (-not $target -and $usb -match '(\d+\.\d+\.\d+\.\d+):5555') {
    $target = "$($Matches[1]):5555"; Write-Host "[+] 已连无线 adb $target"
}
if (-not $target -and (Test-Path $IpFile)) {
    $ip = (Get-Content $IpFile -Raw).Trim()
    if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and (TcpOpen $ip 5555 600)) { $target = "$ip`:5555"; Write-Host "[+] 缓存 IP 可用 $target" }
}
if (-not $target) {
    Write-Host '[*] 扫 ARP 表找 5555...'
    $cand = (arp -a) -split "`n" | ForEach-Object { if ($_ -match '(\d+\.\d+\.\d+\.\d+)\s') { $Matches[1] } } |
            Where-Object { $_ -notmatch '^(127\.|224\.|255\.|192\.168\.137\.1$)' } | Select-Object -Unique
    foreach ($c in $cand) { if (TcpOpen $c 5555 300) { $target = "$c`:5555"; break } }
    if ($target) { Set-Content -Path $IpFile -Value ($target -split ':')[0] -Encoding ascii; Write-Host "[+] ARP 探到 $target" }
}
if (-not $target) { Write-Host '[X] 找不到头显。请先用 USB 线连一次跑本脚本（之后就不用了）。' -ForegroundColor Red; exit 1 }

Write-Host '=== 2/4 确保无线 adb ===' -ForegroundColor Cyan
$cur = (& $Adb devices) -join "`n"
if ($cur -notmatch [regex]::Escape($target)) {
    & $Adb connect $target | Out-Null; Start-Sleep -Seconds 2
    $cur = (& $Adb devices) -join "`n"
}
if ($cur -notmatch [regex]::Escape($target) -and $Serial -and $cur -match [regex]::Escape($Serial)) {
    Write-Host '[*] 用 USB 打开 tcpip 5555...'
    & $Adb -s $Serial tcpip 5555 | Out-Null
    Start-Sleep -Seconds 5
    & $Adb connect $target | Out-Null; Start-Sleep -Seconds 2
    $cur = (& $Adb devices) -join "`n"
}
if ($cur -notmatch [regex]::Escape($target)) { Write-Host '[X] 无线 adb 连不上' -ForegroundColor Red; exit 1 }
Write-Host "[+] 无线 adb 就绪 $target"
$D = $target

Write-Host '=== 3/4 抓设备侧日志 + 检查 / 获取 root ===' -ForegroundColor Cyan

# 设备侧 logcat 写到 /sdcard（nohup 起，adbd 被杀也照样写；重启后文件还在）
$TS = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogDir = '/sdcard/Download/pico_touch/logs'
& $Adb -s $D shell "mkdir -p $LogDir 2>/dev/null; nohup logcat -b all -v threadtime -f $LogDir/logcat_$TS.txt </dev/null >/dev/null 2>&1 &" | Out-Null
Start-Sleep -Seconds 2
Write-Host "[i] 设备侧 logcat -> $LogDir/logcat_$TS.txt"

$id = (& $Adb -s $D shell id) -join ''
if ($id -match 'uid=0') {
    Write-Host '[=] 已是 root，跳过 picohaxx'
} else {
    # ★ picohaxx 只设 persist.adb.tcp.port，而 adbd 重启时读的是易失的 service.adb.tcp.port
    #   ⇒ 先切到 TCP 模式，否则 adbd 重启后无线 adb 就没了
    Write-Host '[*] 先把 adbd 切到 TCP 模式...'
    & $Adb -s $D tcpip 5555 | Out-Null
    Start-Sleep -Seconds 3
    & $Adb disconnect $target 2>$null | Out-Null
    & $Adb connect $target | Out-Null; Start-Sleep -Seconds 2

    Write-Host '[*] 推 picohaxx 并提权（约 50 秒，adbd 会重启）...'
    & $Adb -s $D push "$Here\$Haxx" /data/local/tmp/picohaxx | Out-Null
    & $Adb -s $D shell 'chmod 755 /data/local/tmp/picohaxx'
    & $Adb -s $D shell 'cd /data/local/tmp && ./picohaxx -noftpd -- /system/bin/id' | Out-Null
    Start-Sleep -Seconds 8

    $ok = $false
    for ($i = 1; $i -le 6; $i++) {
        & $Adb disconnect $target 2>$null | Out-Null
        Start-Sleep -Seconds 1
        & $Adb connect $target | Out-Null
        Start-Sleep -Seconds 3
        $cur = (& $Adb devices) -join "`n"
        if ($cur -match ([regex]::Escape($target) + '\s+device')) { $ok = $true; break }
        Write-Host "[*] 重连中（第 $i 次）..."
    }
    if (-not $ok) { Write-Host '[X] adbd 重启后连不回来，请插 USB 线重跑' -ForegroundColor Red; exit 1 }
    $id = (& $Adb -s $D shell id) -join ''
    if ($id -notmatch 'uid=0') { Write-Host '[X] 提权失败' -ForegroundColor Red; exit 1 }
    Write-Host '[+] root 已获得'
}
Write-Host "[i] SELinux = $(((& $Adb -s $D shell getenforce) -join ''))"

Write-Host '=== 4/4 推文件 + 设备端注入 ===' -ForegroundColor Cyan
& $Adb -s $D push "$Here\$Inj" /data/local/tmp/frida-inject | Out-Null
& $Adb -s $D push "$Share\hook.js" /data/local/tmp/hook.js | Out-Null
& $Adb -s $D push "$Share\start_touch.sh" /data/local/tmp/start_touch.sh | Out-Null
& $Adb -s $D shell 'chmod 755 /data/local/tmp/frida-inject /data/local/tmp/start_touch.sh; chmod 644 /data/local/tmp/hook.js'
Write-Host '[+] 文件已就位'

$out = (& $Adb -s $D shell '/data/local/tmp/start_touch.sh') -join "`n"
Write-Host $out
if ($out -match '已注入') {
    Write-Host ''
    Write-Host '[✓] 完成。注入跑在头显本地，现在可以拔掉 USB 线 / 关掉本窗口。' -ForegroundColor Green
    Write-Host '[i] 验证：SteamVR → 设置 → 控制器 → 测试控制器，手指搭在 A/B/X/Y / 扳机 / 摇杆顶'
} else {
    Write-Host '[X] 注入可能失败，看上面输出' -ForegroundColor Red; exit 1
}
