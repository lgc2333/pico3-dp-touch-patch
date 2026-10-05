<#
pico_touch.ps1 —— 一键恢复「DP 直连手柄电容触摸」

★ 注入在【头显本地】完成（frida-inject），PC 只负责提权和推文件。
    跑完之后可以拔掉 USB 线 / 关掉这个窗口，触摸照常工作。

流程：
    1. 找头显：USB adb → 无线 adb（缓存 IP / ARP 探测）；有 USB 就用 USB，不会自己换传输方式
    2. 开 TCP 端口（adb tcpip 5555）：adbd 重启后头显本机也还连得上（Termux 走 127.0.0.1:5555）
    3. 用 picohaxx 拿临时 root（免解 BL、保数据）
    4. 推 frida-inject + hook.js + start_touch.sh
    5. 在设备上执行 start_touch.sh（幂等，已挂过会跳过）

前置：头显与 PC 同一网段（PC 热点 192.168.137.x）。
        依赖二进制（frida-inject / picohaxx.neo3.bin）缺失时会自动调用同目录
        get_deps.ps1 从上游拉取；设备端脚本取自 ..\shared\。

参数：
    -Adb     adb.exe 路径（默认自动探测 PATH 与常见安装位置；都没有就自动下载到 temp）
    -Serial  USB 连接时的设备序列号

用法：双击 src\windows\pico_touch.bat（或直接跑本脚本）
#>
[CmdletBinding()]
param(
    [string]$Adb,
    [string]$Serial
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. "$PSScriptRoot\_utils.ps1"

$P = Get-RepoPaths -ScriptDir $PSScriptRoot
$Share = $P.Share
$Cache = $P.Cache
$Haxx = 'picohaxx.neo3.bin'
$Inj = 'frida-inject'
$IpFile = Join-Path $Cache '.headset_ip'

$Adb = Get-AdbPath -Adb $Adb
Ensure-Deps -Cache $Cache

foreach ($f in @("$Cache\$Haxx", "$Cache\$Inj", "$Share\hook.js", "$Share\start_touch.sh")) {
    if (-not (Test-Path $f)) { Write-Host "[X] 缺少 $f（详见 README）" -ForegroundColor Red; exit 1 }
}

Write-Host '=== 1/3 认头显 ===' -ForegroundColor Cyan
$sel = Select-Headset -Adb $Adb -Serial $Serial -IpFile $IpFile
if (-not $sel) { Write-Host '[X] 没找到头显（已取消）' -ForegroundColor Red; exit 1 }
$D = $sel.Target
$Serial = $sel.Serial
Write-Host "[+] 用 $D" -ForegroundColor Green

Write-Host '=== 2/3 抓设备侧日志 + 检查 / 获取 root ===' -ForegroundColor Cyan

# nohup 起，adbd 被杀也照样写；重启后文件还在
$TS = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogDir = '/sdcard/Download/pico_touch/logs'
& $Adb -s $D shell "mkdir -p $LogDir 2>/dev/null; nohup logcat -b all -v threadtime -f $LogDir/logcat_$TS.txt </dev/null >/dev/null 2>&1 &" | Out-Null
Start-Sleep -Seconds 2
Write-Host "[i] 设备侧 logcat -> $LogDir/logcat_$TS.txt"

$id = (& $Adb -s $D shell id) -join ''
if ($id -match 'uid=0') {
    Write-Host '[=] 已是 root，跳过 picohaxx'
}
else {
    # adbd 重启后读的是易失的 service.adb.tcp.port（picohaxx 只设 persist.*）⇒ 先开这个端口，
    # 否则提权后头显本机的 Termux 连不上 127.0.0.1:5555
    $wireless = $D -match '^\d+\.\d+\.\d+\.\d+:\d+$'
    Write-Host '[*] 先开 TCP 端口 5555 ...'
    & $Adb -s $D tcpip 5555 | Out-Null
    if ($wireless) {
        Start-Sleep -Seconds 3
        & $Adb disconnect $D 2>$null | Out-Null
        & $Adb connect $D | Out-Null; Start-Sleep -Seconds 2
    }
    else {
        Write-Host '[i] adbd 会重启，USB 线短断几秒（等它自己回来）'
        $back = $false
        for ($i = 1; $i -le 10; $i++) {
            Start-Sleep -Seconds 2
            if ((Get-AdbDeviceState -Adb $Adb -Target $D) -eq 'device') { $back = $true; break }
            Write-Host "[*] 还在等 USB 回来（第 $i/10 轮）..."
        }
        if (-not $back) { Write-Host '[X] USB 没回来：把数据线拔下来重插一次，再从头跑本脚本' -ForegroundColor Red; exit 1 }
        Write-Host '[+] USB 已回来'
    }

    Write-Host '[*] 开始提权（约 50 秒）'  # 推 picohaxx 执行 exploit；它会重启 adbd，输出全量打印
    Write-Host '[i] 2 秒后开始提权'
    Start-Sleep -Seconds 2  # picohaxx 一开刷日志就会把上面的提示顶出屏幕，停 2 秒让人看清
    # 只用来拿 root：父进程 adbd 会被重启带走，注入必须放到下一步另起 adb shell
    & $Adb -s $D push "$Cache\$Haxx" /data/local/tmp/picohaxx | Out-Null
    & $Adb -s $D shell 'chmod 755 /data/local/tmp/picohaxx'
    & $Adb -s $D shell 'cd /data/local/tmp && ./picohaxx -noftpd -- /system/bin/id'
    Start-Sleep -Seconds 8

    # exploit 偶发在提权阶段自己中止（FATAL: SPINLOCK TIMEOUT at root.c:206）：adbd 没被动过、
    # 也不会变成 root ⇒ 别去等「adbd 回来」，按中止处理
    $uidNow = ((& $Adb -s $D shell 'id -u' 2>$null) -join '').Trim()
    if ($uidNow -match '^\d+$' -and $uidNow -ne '0') {
        Write-Host "[X] picohaxx 在提权阶段自己中止了（偶发：FATAL: SPINLOCK TIMEOUT at root.c:206）；adbd 没被动过（id -u = $uidNow）" -ForegroundColor Red
        Write-Host '[i] 再跑一次本脚本通常就成；还不行就重启头显'  # 重启后 exploit 状态最干净
        exit 1
    }

    $ok = $uidNow -eq '0'
    for ($i = 1; (-not $ok) -and $i -le 6; $i++) {
        if ($wireless) {
            & $Adb disconnect $D 2>$null | Out-Null
            Start-Sleep -Seconds 1
            & $Adb connect $D | Out-Null
            Start-Sleep -Seconds 3
        }
        else {
            Start-Sleep -Seconds 3  # USB：等 adbd 自己回来，别 connect
        }
        $cur = (& $Adb devices) -join "`n"
        if ($cur -match ([regex]::Escape($D) + '\s+device')) { $ok = $true; break }
        Write-Host "[*] 重连中（第 $i 次）..."
    }
    if (-not $ok) { Write-Host '[X] adbd 重启后连不回来，请插 USB 线重跑' -ForegroundColor Red; exit 1 }
    $id = (& $Adb -s $D shell id) -join ''
    if ($id -notmatch 'uid=0') { Write-Host '[X] 提权失败' -ForegroundColor Red; exit 1 }
    Write-Host '[+] root 已获得'
}
Write-Host "[i] SELinux = $(((& $Adb -s $D shell getenforce) -join ''))"

Write-Host '=== 3/3 推文件 + 设备端注入 ===' -ForegroundColor Cyan
& $Adb -s $D push "$Cache\$Inj" /data/local/tmp/frida-inject | Out-Null
& $Adb -s $D push "$Share\hook.js" /data/local/tmp/hook.js | Out-Null
& $Adb -s $D push "$Share\start_touch.sh" /data/local/tmp/start_touch.sh | Out-Null
& $Adb -s $D shell 'chmod 755 /data/local/tmp/frida-inject /data/local/tmp/start_touch.sh; chmod 644 /data/local/tmp/hook.js'
Write-Host '[+] 文件已就位'

$out = (& $Adb -s $D shell '/data/local/tmp/start_touch.sh') -join "`n"
Write-Host $out
if ($out -match '已注入') {
    Write-Host ''
    Write-Host '[+] 完成。现在可以拔掉 USB 线 / 关掉本窗口。' -ForegroundColor Green
    Write-Host '[i] 验证：SteamVR → 设置 → 控制器 → 测试控制器，手指搭在 A/B/X/Y / 扳机 / 摇杆顶'
    Write-Host ''
    # adbd 已是 root：顺手把 Termux 侧也装好（以后头显里敲 dptouch 就行）
    Push-TermuxKit -Adb $Adb -Target $D -Paths $P
}
else {
    Write-Host '[X] 注入可能失败，看上面输出' -ForegroundColor Red; exit 1
}
