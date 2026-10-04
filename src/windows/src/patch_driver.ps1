<#
patch_driver.ps1 —— 给 PICO DP 驱动打补丁：让扳机 / 摇杆顶的电容触摸生效

改动（14 字节，零长度变化）：
    /input/trigger/touch   ← 键值字 bit5   (原: 扳机模拟量 != 0)
    /input/joystick/touch  ← 键值字 bit7   (原: 摇杆偏离中位)

前置：必须以管理员运行；SteamVR / Business StreamingDP 必须已退出。
自动备份为 driver_pico.dll.orig，并校验原字节。

参数：
    -Dll  目标 driver_pico.dll 路径（默认自动探测）

用法：双击 src\windows\patch_driver.bat（或直接跑本脚本）
        没提权时脚本会自己弹 UAC 提权，提权窗口用 cmd /k 保住好读输出
#>
[CmdletBinding()]
param(
    [string]$Dll
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 定位 driver_pico.dll ---
# 顺序：-Dll → 注册表卸载项（企业串流是 Inno 安装；DisplayName 是中文，只认 Inno Setup: App Path / InstallLocation）
#       → OpenVR external_drivers → 常见安装位置 → 问用户
$RelApp = 'BusinessStreamingDP\driver\bin\win64\driver_pico.dll'  # 相对安装根
$RelDrv = 'driver\bin\win64\driver_pico.dll'  # 相对 BusinessStreamingDP
$RelBin = 'bin\win64\driver_pico.dll'  # 相对 driver 目录

# 安装根 / BusinessStreamingDP / driver / dll 本身，丢进来都能解析出 dll
function Resolve-Dll([string]$p) {
    $p = "$p".Trim().Trim('"').TrimEnd('\')
    if (-not $p) { return $null }
    if (Test-Path -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).Path }
    foreach ($c in "$p\$RelApp", "$p\$RelDrv", "$p\$RelBin") {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

if (-not $Dll) {
    $roots = @()
    foreach ($h in 'HKLM:', 'HKCU:') {
        # 64 位与 32 位视图都翻
        foreach ($v in 'SOFTWARE', 'SOFTWARE\WOW6432Node') {
            $un = "$h\$v\Microsoft\Windows\CurrentVersion\Uninstall"
            if (-not (Test-Path $un)) { continue }
            foreach ($it in @(Get-ItemProperty "$un\*" -ErrorAction SilentlyContinue)) {
                if ($it.PSObject.Properties.Name -contains 'Inno Setup: App Path') { $roots += $it.'Inno Setup: App Path' }
                if ($it.InstallLocation) { $roots += $it.InstallLocation }
            }
        }
    }
    $vp = Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'
    if (Test-Path $vp) {
        $j = Get-Content $vp -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($j) { $roots += @($j.external_drivers) }
    }
    $roots += @(
        "$env:ProgramFiles\BusinessStreaming",
        "${env:ProgramFiles(x86)}\BusinessStreaming",
        'D:\Program Files\BusinessStreaming'
    )
    foreach ($r in $roots) { if ($Dll = Resolve-Dll $r) { break } }
}
while (-not $Dll) {
    Write-Host '[*] 没找到 driver_pico.dll（注册表 / OpenVR / 常见安装位置都试过了）' -ForegroundColor Yellow
    Write-Host '    粘贴 driver_pico.dll 的路径，或 Business Streaming DP 的安装目录；直接回车退出'
    $in = Read-Host '> '
    if (-not $in) { Write-Host '[X] 已取消' -ForegroundColor Red; exit 1 }
    $Dll = Resolve-Dll $in
    if (-not $Dll) { Write-Host "[!] $in 里没有 driver_pico.dll" -ForegroundColor Red }
}

$dll = $Dll
$orig = "$dll.orig"
$md5Expect = '9017439d560747678b4550fcf6726808'

function Die($m) { Write-Host "[X] $m" -ForegroundColor Red; exit 1 }

# --- 管理员检查：没提权就自我提权 ---
# 提权窗口用 cmd /k 保住，跑完不关好读结果。
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[*] 需要管理员权限，正在请求提权（请在 UAC 弹窗点「是」）...'
    # Windows PowerShell 5.1 的 ArgumentList 不会自己加引号，带空格的路径必须手动包
    Start-Process cmd.exe -Verb RunAs -ArgumentList @(
        '/k', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath), '-Dll', ('"{0}"' -f $Dll)
    )
    exit
}

# --- 进程检查 ---
foreach ($p in 'vrserver', 'vrmonitor', 'vrdashboard', 'Business StreamingDP', 'BusinessStreamingDP') {
    if (Get-Process -Name $p -ErrorAction SilentlyContinue) {
        Die "检测到进程 $p 正在运行。请先完全退出 SteamVR 和 Business StreamingDP。"
    }
}
if (-not (Test-Path $dll)) { Die "找不到 $dll" }

# --- 备份 ---
if (-not (Test-Path $orig)) {
    Copy-Item $dll $orig -Force
    Write-Host "[+] 已备份 -> $orig"
}
else {
    Write-Host "[=] 备份已存在，跳过"
}

# --- 校验 md5 ---
$md5 = (Get-FileHash $orig -Algorithm MD5).Hash.ToLower()
if ($md5 -ne $md5Expect) {
    Write-Host "[!] 原始 DLL md5 = $md5（预期 $md5Expect）" -ForegroundColor Yellow
    Write-Host "[!] 版本可能不同，继续前请确认偏移仍然正确。" -ForegroundColor Yellow
}
else {
    Write-Host "[+] md5 校验通过"
}

$b = [System.IO.File]::ReadAllBytes($orig)

# (文件偏移, 期望原字节, 新字节, 说明)
$patch = @(
    @{ off = 0x18bb8; old = '0F57DB410F95C0'; new = '4188F04180E020'; what = 'trigger/touch  <- bit5' },
    @{ off = 0x18d1d; old = '0F57DB'; new = '4188F0'; what = 'joystick/touch <- bit7 (mov)' },
    @{ off = 0x18d27; old = '450FB6C7'; new = '4180E080'; what = 'joystick/touch <- bit7 (and)' }
)

foreach ($p in $patch) {
    $n = $p.old.Length / 2
    $got = -join ($b[$p.off..($p.off + $n - 1)] | ForEach-Object { $_.ToString('X2') })
    if ($got -ne $p.old) {
        Die ("偏移 0x{0:X} 原字节不符`n  期望 {1}`n  实际 {2}`n（DLL 版本可能已变，已中止，未做任何修改）" -f $p.off, $p.old, $got)
    }
    Write-Host ("[+] 0x{0:X} 校验通过  {1}" -f $p.off, $p.what)
}

# --- 写入 ---
foreach ($p in $patch) {
    $n = $p.new.Length / 2
    for ($i = 0; $i -lt $n; $i++) {
        $b[$p.off + $i] = [Convert]::ToByte($p.new.Substring($i * 2, 2), 16)
    }
}
[System.IO.File]::WriteAllBytes($dll, $b)
Write-Host "[+] 已写入 $dll" -ForegroundColor Green

# --- 复核 ---
$c = [System.IO.File]::ReadAllBytes($dll)
foreach ($p in $patch) {
    $n = $p.new.Length / 2
    $got = -join ($c[$p.off..($p.off + $n - 1)] | ForEach-Object { $_.ToString('X2') })
    if ($got -ne $p.new) { Die "复核失败：0x$($p.off.ToString('X')) = $got" }
}
Write-Host '[+] 复核通过。重启 SteamVR 后生效。' -ForegroundColor Green
Write-Host '[i] 还原：把 driver_pico.dll.orig 复制回 driver_pico.dll 即可。'
