<#
push.ps1 —— 把头显要用的文件一次性推上去（不提权、不注入、不碰分区）

推这些：
    /data/local/tmp/{frida-inject,hook.js,start_touch.sh}   设备端注入三件套
    /sdcard/Download/pico_touch/{termux_touch.sh,get_deps.sh,install.sh,launch.sh,hook.js,start_touch.sh,picohaxx.neo3.bin}
                                                        Termux kit（细节见 docs/notes/09-termux.md）
依赖二进制缺了会自动调 get_deps.ps1 下载；没连设备时会问头显 IP（或自动探测后请你确认）。
adbd 是 root 时（跑过 pico_touch.bat 就一定是）顺手把 kit 直接装进头显 Termux 家目录 + 装好短命令 dptouch。

用法：双击上层目录的 push.bat（或直接跑本脚本）
        powershell -ExecutionPolicy Bypass -File push.ps1 [-Adb <adb.exe>] [-Serial <序列号>]
#>
[CmdletBinding()]
param(
    # adb.exe 路径；不传就自动找
    [string]$Adb,
    # 有多台设备时指定序列号
    [string]$Serial
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. "$PSScriptRoot\_utils.ps1"

$P = Get-RepoPaths -ScriptDir $PSScriptRoot
$Adb = Get-AdbPath -Adb $Adb  # 找不到 adb 直接退出
Ensure-Deps -Cache $P.Cache  # 缺依赖自动拉

$DirName = 'pico_touch'
$Sd = "/sdcard/Download/$DirName"

# --- 认头显：现有设备让用户认，没有就问 IP / 自动探测后确认 ---
$IpFile = Join-Path $P.Cache '.headset_ip'
$sel = Select-Headset -Adb $Adb -Serial $Serial -IpFile $IpFile
if (-not $sel) { Write-Host '[X] 没找到头显（已取消）' -ForegroundColor Red; exit 1 }
$target = $sel.Target
Write-Host "[+] 设备 $target" -ForegroundColor Cyan

# --- 推文件 ---
& $Adb -s $target shell "mkdir -p $Sd" | Out-Null
$jobs = @(
    @{ Src = Join-Path $P.Cache 'frida-inject'; Dst = '/data/local/tmp/frida-inject' }
    @{ Src = Join-Path $P.Share 'hook.js'; Dst = '/data/local/tmp/hook.js' }
    @{ Src = Join-Path $P.Share 'start_touch.sh'; Dst = '/data/local/tmp/start_touch.sh' }
    @{ Src = Join-Path $P.Termux 'termux_touch.sh'; Dst = "$Sd/termux_touch.sh" }
    @{ Src = Join-Path $P.Termux 'get_deps.sh'; Dst = "$Sd/get_deps.sh" }
    @{ Src = Join-Path $P.Termux 'install.sh'; Dst = "$Sd/install.sh" }
    @{ Src = Join-Path $P.Termux 'launch.sh'; Dst = "$Sd/launch.sh" }
    @{ Src = Join-Path $P.Share 'hook.js'; Dst = "$Sd/hook.js" }
    @{ Src = Join-Path $P.Share 'start_touch.sh'; Dst = "$Sd/start_touch.sh" }
    @{ Src = Join-Path $P.Cache 'picohaxx.neo3.bin'; Dst = "$Sd/picohaxx.neo3.bin" }
)
foreach ($j in $jobs) {
    $s = $j.Src; $d = $j.Dst
    if (-not (Test-Path $s)) { Write-Host "[X] 缺少 $s" -ForegroundColor Red; exit 1 }
    & $Adb -s $target push $s $d | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "[X] 推送失败：$s -> $d" -ForegroundColor Red; exit 1 }
    Write-Host "    -> $d"
}
& $Adb -s $target shell 'chmod 755 /data/local/tmp/frida-inject /data/local/tmp/start_touch.sh; chmod 644 /data/local/tmp/hook.js'
Write-Host '[+] 文件已就位' -ForegroundColor Green

Write-Host ''
# Termux 侧的话术以 docs/notes/09-termux.md 为准（流程的唯一权威在那边）
# 函数自己会把结论打出来：root 时装好并给短命令；没 root 给兜底命令；没装 Termux 就不提 Termux
Push-TermuxKit -Adb $Adb -Target $target -Paths $P
