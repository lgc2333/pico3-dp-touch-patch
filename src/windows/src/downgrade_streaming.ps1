<#
downgrade_streaming.ps1 —— 把「企业串流」(Business Streaming) 的头显端 app 换回实测可用的版本

为什么会有这个脚本：这个 app 的版本是用户自己装的（系统内置 1.2.0，平时跑的是 /data 里那份
用户态更新；头显不会替它升级，只会被覆盖安装成别的版本）。本项目只对头显端 1.2.10 验证过
（见 README「适用条件」、docs/notes/01-device.md）；装了别的版本之后 DP 直连可能就不对了。

流程：
    1. 取头显端安装包：缓存里有、sha256 对得上就跳过；否则下载并逐字节校验（上游换文件直接中止，不装）
    2. 认头显：USB adb → 无线 adb（同 push.ps1 / pico_touch.ps1）
    3. adb uninstall：卸掉用户态更新（回落到系统内置版，app 数据也一并清掉）
    4. adb install -r -d：装上目标版本
    5. 读回 dumpsys 的 versionName / versionCode / flags 当凭证
    6. PC 端安装包问过你才下：只有 PC 端软件也要跟着换版本时才需要

参数：
    -Adb      adb.exe 路径（默认自动探测 PATH 与常见安装位置；都没有就下载到 temp，同其它脚本）
    -Serial   USB 连接时的设备序列号
    -PcClient 连 PC 端安装包一起下（不传就现场问，回车 = 不下）

用法：双击 src\windows\downgrade_streaming.bat，或设备已连好时直接跑本脚本
#>
[CmdletBinding()]
param(
    # adb.exe 路径；不传就自动找（PATH / 常见安装位置 / 自动下载到 temp）
    [string]$Adb,
    # 有多台设备时指定序列号
    [string]$Serial,
    # 连 PC 端安装包一起下（不传就现场问你）
    [switch]$PcClient
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. "$PSScriptRoot\_utils.ps1"

$P = Get-RepoPaths -ScriptDir $PSScriptRoot
$Adb = Get-AdbPath -Adb $Adb

# 上游产物与 sha256 一一对应：换了就一起改（上游换文件必须当场发现，见 AGENTS.md 硬门槛）
$Hs = @{
    Pkg  = 'com.picoxr.bstreamassistant'
    Ver  = '1.2.10'
    File = 'bstreamassistant-1.2.10.apk'
    Url  = 'https://p9-arcosite.byteimg.com/obj/tos-cn-i-goo7wpa0wc/86f42d8ba318499b8deb692be7ab3013'
    Sha  = 'cb67c0ccf89feddbe5b58941f5f34799311d57069e4fc8a8ff2767095164326e'
}
$Pc = @{
    File = 'bstream_pc_installer.exe'
    Url  = 'https://p9-arcosite.byteimg.com/obj/tos-cn-i-goo7wpa0wc/b7d8d1f9ca8b48c6ac448d356b88f7a8'
    Sha  = '901802bd84d606001564af99ccc94e9c6b299d340d98492cb85fae4998adf271'
}

function Get-VerifiedFile {
    # 缓存命中就看 sha256，下载完也看 sha256：对不上就删掉文件、退非零，绝不放没验过的东西过去
    param([hashtable]$Spec)
    $out = Join-Path $P.Cache $Spec.File
    if (Test-Path $out) {
        if ((Get-FileHash -Path $out -Algorithm SHA256).Hash -eq $Spec.Sha) {
            Write-Host "[=] 用缓存：$($Spec.File)"
            return $out
        }
        Write-Host "[!] 缓存里的 $($Spec.File) sha256 对不上，重下" -ForegroundColor Yellow
    }
    New-Item -ItemType Directory -Force $P.Cache | Out-Null
    if (-not (Get-RemoteFile -Url $Spec.Url -Out $out)) {
        Write-Host "[X] 下载失败：$($Spec.Url)" -ForegroundColor Red
        exit 1
    }
    $got = (Get-FileHash -Path $out -Algorithm SHA256).Hash
    if ($got -ne $Spec.Sha) {
        Remove-Item -Force $out
        Write-Host "[X] $($Spec.File) sha256 对不上（上游换文件了？），已删，不装：" -ForegroundColor Red
        Write-Host "    期望 $($Spec.Sha)"
        Write-Host "    实得 $got"
        exit 1
    }
    Write-Host "[+] 已下载并校验：$out（$((Get-Item $out).Length) 字节）" -ForegroundColor Green
    $out
}

function Get-BStreamInfo {
    # 更新过的系统 app 在 dumpsys 里有两份（生效的 /data 那份 + Hidden system packages 里的内置那份），只认前一份
    param([string]$Adb, [string]$Target)
    $txt = (((& $Adb -s $Target shell "dumpsys package $($Hs.Pkg)") -join "`n") -split 'Hidden system packages:')[0]
    $m = [regex]::Match($txt, 'versionName=(\S+)')
    if (-not $m.Success) { return $null }
    @{
        Ver   = $m.Groups[1].Value
        Code  = [regex]::Match($txt, 'versionCode=(\d+)').Groups[1].Value
        Flags = [regex]::Match($txt, 'flags=\[([^\]]*)\]').Groups[1].Value.Trim()
    }
}

Write-Host '=== 1/4 准备头显端安装包 ===' -ForegroundColor Cyan
$apk = Get-VerifiedFile -Spec $Hs

Write-Host '=== 2/4 认头显 ===' -ForegroundColor Cyan
$sel = Select-Headset -Adb $Adb -Serial $Serial -IpFile (Join-Path $P.Cache '.headset_ip')
if (-not $sel) { Write-Host '[X] 没找到头显（已取消）' -ForegroundColor Red; exit 1 }
$D = $sel.Target
Write-Host "[+] 用 $D" -ForegroundColor Green
$cur = Get-BStreamInfo -Adb $Adb -Target $D
if ($cur) { Write-Host "[i] 现在是 $($cur.Ver)（versionCode $($cur.Code)）" }
else { Write-Host '[!] 读不到当前版本（app 没装？）' -ForegroundColor Yellow }

Write-Host '=== 3/4 卸载更新 + 装目标版本 ===' -ForegroundColor Cyan
if ((((& $Adb -s $D shell "pidof $($Hs.Pkg)") -join '')).Trim()) {
    Write-Host '[!] 头显上企业串流正在跑，下面这步会把它结束掉' -ForegroundColor Yellow
}
$out = ((& $Adb -s $D uninstall $Hs.Pkg) -join ' ').Trim()
if ($out -match 'Success') { Write-Host '[+] 已卸载用户态更新（回落到系统内置版）' }
else { Write-Host "[!] 卸载更新没报 Success（$out），直接装" -ForegroundColor Yellow }

Write-Host "[i] 往 $D 装 $($Hs.Ver)（无线 adb 下十几秒到一分钟，别拔线）"
& $Adb -s $D install -r -d $apk
if ($LASTEXITCODE -ne 0) { Write-Host "[X] adb install 失败（退出码 $LASTEXITCODE）" -ForegroundColor Red; exit 1 }

Write-Host '=== 4/4 校验 ===' -ForegroundColor Cyan
$new = Get-BStreamInfo -Adb $Adb -Target $D
if (-not $new) { Write-Host '[X] 装完读不到版本，头显里自己看一眼企业串流' -ForegroundColor Red; exit 1 }
Write-Host "[i] 装完是 $($new.Ver)（versionCode $($new.Code)）"
if ($new.Ver -ne $Hs.Ver) { Write-Host "[X] 版本不是 $($Hs.Ver)，看上面 adb install 的输出" -ForegroundColor Red; exit 1 }
# 系统级权限来自 UPDATED_SYSTEM_APP 身份；掉成普通 app 串流链路就断了（见 docs/notes/01-device.md）
if ($new.Flags -notmatch 'SYSTEM' -or $new.Flags -notmatch 'UPDATED_SYSTEM_APP') {
    Write-Host "[X] flags 不对（$($new.Flags)）：不是「更新过的系统 app」，串流会断" -ForegroundColor Red
    exit 1
}
Write-Host "[+] 头显端已是 $($Hs.Ver)" -ForegroundColor Green

# PC 端不是降级必须的：头显换好照常用；只有 PC 端软件也要跟着换版本时才要下
if (-not $PcClient) {
    Write-Host ''
    Write-Host '[i] PC 端「企业串流」安装包约 211 MB，只有 PC 端也要一起换版本时才需要'
    $a = "$(Read-Host '要一起下载吗？（y = 下 / 回车 = 不下）')".Trim()
    if ($a -match '^(y|yes|是)$') { $PcClient = $true }
}
if ($PcClient) {
    $exe = Get-VerifiedFile -Spec $Pc
    Write-Host "[+] PC 端安装包：$exe"
    Write-Host ("    文件版本 {0}" -f (Get-Item $exe).VersionInfo.FileVersion)
    Write-Host '[!] 装它之前：先完全卸载新版 PC 端软件，再装这个安装包（别直接覆盖装）；SteamVR 和 Business Streaming DP 也要先完全退出' -ForegroundColor Yellow
}
else {
    Write-Host '[=] 跳过 PC 端安装包'
}
