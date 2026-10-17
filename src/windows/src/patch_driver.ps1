<#
patch_driver.ps1 —— 给 PICO DP 驱动打补丁

改动 A（零长度变化）：
    /input/trigger/touch   ← 键值字 bit5   (原: 扳机模拟量 != 0)
    /input/joystick/touch  ← 键值字 bit7   (原: 摇杆偏离中位)
    kTriggerTouch 调试打印 ← 恒跳过        (厂商遗留：拉扳机时以 ~200 Hz 刷 SteamVR Console；见 docs/notes/04_c-driver-touch-patch.md)

改动 B（新增一个 PE 段 .pitouch，DLL 变大 ~63 KB）：
    补上 DP 驱动缺的 pose/raw + skeleton 输出（Alyx 的手指动画走 skeleton，不是 capsense 绑定）。
    `driver_patch\dp_skeleton_payload.bin` 是从 v2 驱动整段搬来的骨架代码（生成器 + 姿势表 + slerp +
    每帧更新器）加上两段跳板；本脚本把它作为一个新段塞进 DLL，再把「建组件」和「输入更新」两处改成
    跳进跳板。算法、位映射、为什么这么搬：见 docs/notes/04_d-driver-skeleton.md。

改动 C（零长度变化）：**修掉「游戏里手柄偏 ~4cm / 10°」**
    PC 侧 host 检测到 Steam 游戏启动后，会通过本机 socket 反复给驱动发 `apprun <n>`；驱动用 atoi
    存进 dword_18009B080，发布手柄位姿时读这个标志，于是游戏态的手柄位姿被额外偏了一段。
    把这次 atoi 调用换成 `xor eax, eax`，标志恒 0，游戏里的位姿与桌面/待机一致。
    实测：补完用真游戏（The Lab）验证，模型不再并到一起。详见 docs/notes/04_e-driver-offset.md。

改动 D（只改两个文本资源，不改 DLL）：**让虚拟手落在握把上，模型仍和实物对齐**
    驱动把 device pose 报在跟踪环附近，而 VRChat 这类 app 的虚拟手吃的是同一个 device pose
    ⇒ 手比握把低 ~4cm / 10°。这里把发布的位姿挪到握把点（RVRPlugin.ini 的 [controller] 偏移），
    再把渲染模型顶点做反向平移+旋转（从 .orig 重算），于是手落在握把上、模型仍留在物理位置。
    改动 C 的 apprun 是同一件事的「只移位姿、不补模型」版本；本项是它的正解。
    数值、公式、证伪记录：见 docs/notes/04_f-driver-hand-grip.md。

顺手修 profile：`resources\input\pico_controller_profile.json` 里的 `"input/application_menu"` 少一个 `/`，
    这条声明不生效 ⇒ menu 键在 SteamVR 里没反应；补成 `"/input/application_menu"`（实测补完 menu / system 键都正常）。
    只改 JSON 文本，DLL 不读这个文件；备份为同名 `.orig`。

顺手修渲染模型：`resources\rendermodels\*\*.json` 里 `tip` 的角度笔误改回 `-1.282`
    （UW / v2 / neo2 都是这个值；DP 那份写成了 `-21.282,3,0`）。每个文件备份为同名 `.orig`。
    游戏里手柄偏的是「app 位姿」那条路，由改动 C 修；与这里的几何无关（SteamVR 菜单与游戏用的是同一份几何）。

补厂商漏发的 input profile：`resources\input\pico_hmd_profile.json`（驱动每次启动都在找这个文件，
    找不到就报 `Failed to load input profile`）。新版 UW 驱动自带这份，内容照抄，只去掉 DP 里不存在的图标引用。

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
                # StrictMode：不存在的属性直接读会抛 PropertyNotFoundException，先问属性表
                $names = $it.PSObject.Properties.Name
                if ($names -contains 'Inno Setup: App Path') { $roots += $it.'Inno Setup: App Path' }
                if ($names -contains 'InstallLocation') { $roots += $it.InstallLocation }
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
    Write-Host '[!] 没找到 driver_pico.dll（注册表 / OpenVR / 常见安装位置都试过了）' -ForegroundColor Yellow
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
    Write-Host '[i] 需要管理员权限，正在请求提权（请在 UAC 弹窗点「是」）'
    # 提权进程的起始目录是 System32：相对路径必须在这里先转成绝对路径，否则会退化成「自己找驱动」
    $dllArg = if ($Dll) { [System.IO.Path]::GetFullPath($Dll) } else { '' }
    # Windows PowerShell 5.1 的 ArgumentList 不会自己加引号，带空格的路径必须手动包
    Start-Process cmd.exe -Verb RunAs -ArgumentList @(
        '/k', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath), '-Dll', ('"{0}"' -f $dllArg)
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

# --- 备份：`.orig` = 「动手前那一刻」的副本，不保证是厂商原件（全脚本统一这个约定，见 AGENTS.md）---
if (-not (Test-Path $orig)) {
    Copy-Item $dll $orig -Force
    Write-Host "[+] 已备份 -> $orig"
}
else {
    Write-Host "[=] 备份已存在，跳过"
}

# --- 校验 md5（以 .orig 为准）---
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
    @{ off = 0x18c6f; old = '740C'; new = 'EB0C'; what = 'kTriggerTouch 打印 <- 恒跳过' },
    @{ off = 0x18d1d; old = '0F57DB'; new = '4188F0'; what = 'joystick/touch <- bit7 (mov)' },
    @{ off = 0x18d27; old = '450FB6C7'; new = '4180E080'; what = 'joystick/touch <- bit7 (and)' },
    @{ off = 0x2c896; old = 'E839B60200'; new = '31C0909090'; what = 'apprun 位姿偏移 <- 恒 0（游戏里手柄偏 4cm/10°）' }
)

foreach ($p in $patch) {
    $n = $p.old.Length / 2
    $got = -join ($b[$p.off..($p.off + $n - 1)] | ForEach-Object { $_.ToString('X2') })
    if ($got -ne $p.old) {
        Die ("补丁点 0x{0:X} 不是原字节 —— 这个 driver_pico.dll 不是支持的那版（已中止，未写入）`n  期望 {1}`n  实际 {2}" -f $p.off, $p.old, $got)
    }
}
Write-Host '[+] 驱动字节校验通过' -ForegroundColor Green

# --- 写入 ---
foreach ($p in $patch) {
    $n = $p.new.Length / 2
    for ($i = 0; $i -lt $n; $i++) {
        $b[$p.off + $i] = [Convert]::ToByte($p.new.Substring($i * 2, 2), 16)
    }
}

# --- 改 B：骨架 / pose 支持（新增 .pitouch 段；见文件头与 docs/notes/04_d-driver-skeleton.md）---
# payload 里的绝对地址（段内 + DP 全局）在打包时已按 段 RVA = 原 SizeOfImage 算好，
# 所以这里先卡死 SizeOfImage，落在别处就中止（版本变了别硬上）。
function PeU16([byte[]]$Arr, [int]$Off) { return [BitConverter]::ToUInt16($Arr, $Off) }
function PeU32([byte[]]$Arr, [int]$Off) { return [BitConverter]::ToUInt32($Arr, $Off) }
function PePutU16([byte[]]$Arr, [int]$Off, [uint16]$Val) { [Array]::Copy([BitConverter]::GetBytes($Val), 0, $Arr, $Off, 2) }
function PePutU32([byte[]]$Arr, [int]$Off, [uint32]$Val) { [Array]::Copy([BitConverter]::GetBytes($Val), 0, $Arr, $Off, 4) }
function AlignUp([int]$Val, [int]$To) { return [int]([math]::Ceiling($Val / [double]$To) * $To) }
function Sha256Of([byte[]]$Arr, [int]$Off, [int]$Len) {
    $slice = New-Object byte[] $Len
    [Array]::Copy($Arr, $Off, $slice, 0, $Len)
    return (([System.Security.Cryptography.SHA256]::Create().ComputeHash($slice) | ForEach-Object { $_.ToString('x2') }) -join '')
}
# 段表里找 RVA 对应的文件偏移（找不到返回 -1）
function FileOffsetOfRva([byte[]]$Arr, [int]$SecTab, [int]$NSec, [int]$Rva) {
    for ($i = 0; $i -lt $NSec; $i++) {
        $h = $SecTab + $i * 40
        $sRva = [int](PeU32 $Arr ($h + 12))
        $sSize = [int][Math]::Max((PeU32 $Arr ($h + 8)), (PeU32 $Arr ($h + 16)))
        if ($Rva -ge $sRva -and $Rva -lt $sRva + $sSize) { return ([int](PeU32 $Arr ($h + 20)) + ($Rva - $sRva)) }
    }
    return -1
}

$plDir = Join-Path $PSScriptRoot 'driver_patch'
$plBin = Join-Path $plDir 'dp_skeleton_payload.bin'
$plMan = Join-Path $plDir 'dp_skeleton_payload.json'
if (-not (Test-Path -LiteralPath $plBin) -or -not (Test-Path -LiteralPath $plMan)) {
    Die "缺少骨架 payload：$plBin（从仓库里补回来，或按 docs/notes/artifacts/build_dp_skeleton_payload.py 重建）"
}
$man = Get-Content -LiteralPath $plMan -Raw | ConvertFrom-Json
$payload = [System.IO.File]::ReadAllBytes($plBin)
if ($payload.Length -ne [int]$man.payload_size) { Die '骨架 payload 长度与清单不符（文件被改过？）' }
$plSha = (Get-FileHash -LiteralPath $plBin -Algorithm SHA256).Hash.ToLower()
if ($plSha -ne $man.payload_sha256) { Die '骨架 payload 校验不过（文件被改过？）；用仓库里原版的那份，或按 docs/notes/artifacts/build_dp_skeleton_payload.py 重建' }

function Build-DpSkeletonImage {
    param([byte[]]$Bytes)

    $peOff = PeU32 $Bytes 0x3C
    if ((PeU32 $Bytes $peOff) -ne 0x00004550) { Die "不是合法 PE：$dll" }
    $nSec = PeU16 $Bytes ($peOff + 6)
    $optSize = PeU16 $Bytes ($peOff + 20)
    $optOff = $peOff + 24
    $secAlign = PeU32 $Bytes ($optOff + 32)
    $fileAlign = PeU32 $Bytes ($optOff + 36)
    $sizeOfImage = PeU32 $Bytes ($optOff + 56)
    $sizeOfHeaders = PeU32 $Bytes ($optOff + 60)
    $secTab = $optOff + $optSize

    if ($nSec -ne 7 -or $sizeOfImage -ne [uint32]$man.section.rva) {
        Die ("这个 driver_pico.dll 不是支持的那版（段数 = {0}、SizeOfImage = 0x{1:X}）；先把原版放回来再打（重装 DP 驱动 / 从安装包取）" -f $nSec, $sizeOfImage)
    }
    $slot = $secTab + $nSec * 40
    if ($slot + 40 -gt $sizeOfHeaders) { Die '没法加段：PE 头里没有空的段表项（不是支持的那版？）' }
    for ($i = 0; $i -lt 40; $i++) { if ($Bytes[$slot + $i] -ne 0) { Die '没法加段：PE 头里的段表项不是空的（不是支持的那版？）' } }

    $vSize = AlignUp $payload.Length $secAlign
    $rawPtr = AlignUp $Bytes.Length $fileAlign
    $rawSize = AlignUp $payload.Length $fileAlign

    # 段表项：名字 / VirtualSize / VirtualAddress / SizeOfRawData / PointerToRawData / relocs / linenums / Characteristics
    # 0xE0000060 = CODE | INITIALIZED_DATA | MEM_EXECUTE | MEM_READ | MEM_WRITE（跳板里有每只手的句柄和暂存区）
    $new = New-Object byte[] ($rawPtr + $rawSize)
    [Array]::Copy($Bytes, 0, $new, 0, $Bytes.Length)
    [Array]::Copy($payload, 0, $new, $rawPtr, $payload.Length)
    $nameBytes = [System.Text.Encoding]::ASCII.GetBytes([string]$man.section.name)
    [Array]::Copy($nameBytes, 0, $new, $slot, [Math]::Min(8, $nameBytes.Length))
    PePutU32 -Arr $new -Off ($slot + 8) -Val ([uint32]$payload.Length)
    PePutU32 -Arr $new -Off ($slot + 12) -Val ([uint32]$sizeOfImage)
    PePutU32 -Arr $new -Off ($slot + 16) -Val ([uint32]$rawSize)
    PePutU32 -Arr $new -Off ($slot + 20) -Val ([uint32]$rawPtr)
    PePutU32 -Arr $new -Off ($slot + 36) -Val ([uint32]3758096480)  # 0xE0000060 = CODE|INITIALIZED_DATA|EXECUTE|READ|WRITE
    PePutU16 -Arr $new -Off ($peOff + 6) -Val ([uint16]($nSec + 1))
    PePutU32 -Arr $new -Off ($optOff + 56) -Val ([uint32]([int]$sizeOfImage + $vSize))

    foreach ($p in $man.patches) {
        $fileOff = FileOffsetOfRva -Arr $new -SecTab $secTab -NSec $nSec -Rva ([int]$p.rva)
        if ($fileOff -lt 0) { Die ("段表里找不到 RVA 0x{0:X}（不是支持的那版？）" -f [int]$p.rva) }
        $got = -join ($new[$fileOff..($fileOff + $p.old.Length / 2 - 1)] | ForEach-Object { $_.ToString('X2') })
        if ($got -ne $p.old) {
            Die ("挂钩点 0x{0:X} 的原字节不符 —— 这个 driver_pico.dll 不是支持的那版（已中止，未写入）`n  期望 {1}`n  实际 {2}" -f [int]$p.rva, $p.old, $got)
        }
        for ($i = 0; $i -lt $p.new.Length / 2; $i++) { $new[$fileOff + $i] = [Convert]::ToByte($p.new.Substring($i * 2, 2), 16) }
    }
    return $new
}

function DieVerify([string]$What) {
    Die "复核失败：$What（把 $orig 覆盖回 $(Split-Path $dll -Leaf) 即可还原）"
}

$b = Build-DpSkeletonImage -Bytes $b

[System.IO.File]::WriteAllBytes($dll, $b)
Write-Host '[+] 驱动补丁已写入 driver_pico.dll：' -ForegroundColor Green
Write-Host '      · 扳机 / 摇杆顶的电容触摸（顺带去掉厂商的调试打印）'
Write-Host '      · 手柄骨架（手指搭在按键 / 扳机 / 摇杆顶上时，游戏里的手会跟着动）'

# --- 复核 ---
$c = [System.IO.File]::ReadAllBytes($dll)
foreach ($p in $patch) {
    $n = $p.new.Length / 2
    $got = -join ($c[$p.off..($p.off + $n - 1)] | ForEach-Object { $_.ToString('X2') })
    if ($got -ne $p.new) { Die "复核失败：0x$($p.off.ToString('X')) = $got" }
}
$peOff = PeU32 $c 0x3C
$optOff = $peOff + 24
$optSize = PeU16 $c ($peOff + 20)
$secTab = $optOff + $optSize
$nSec = PeU16 $c ($peOff + 6)
if ($nSec -ne 8) { DieVerify "段数 = $nSec" }
$secAlign = PeU32 $c ($optOff + 32)
$hdr = $secTab + 7 * 40
$secRva = [int](PeU32 $c ($hdr + 12))
$secRaw = [int](PeU32 $c ($hdr + 20))
$secRawSize = [int](PeU32 $c ($hdr + 16))
if ($secRva -ne [int]$man.section.rva) { DieVerify "新段 RVA = 0x$('{0:X}' -f $secRva)" }
if ((PeU32 $c ($optOff + 56)) -ne [uint32]($secRva + (AlignUp $payload.Length $secAlign))) { DieVerify 'SizeOfImage 不对' }
if ((Sha256Of -Arr $c -Off $secRaw -Len $payload.Length) -ne $man.payload_sha256) { DieVerify '段里的骨架代码和 payload 对不上' }
if ($secRaw + $secRawSize -gt $c.Length) { DieVerify '段超出文件' }
foreach ($p in $man.patches) {
    $fileOff = FileOffsetOfRva -Arr $c -SecTab $secTab -NSec $nSec -Rva ([int]$p.rva)
    if ($fileOff -lt 0) { DieVerify '找不到挂钩点' }
    $got = -join ($c[$fileOff..($fileOff + $p.new.Length / 2 - 1)] | ForEach-Object { $_.ToString('X2') })
    if ($got -ne $p.new) { DieVerify "挂钩点 0x$('{0:X}' -f [int]$p.rva) 不对" }
}
Write-Host '[+] 复核通过。重启 SteamVR 后生效。' -ForegroundColor Green

# --- 顺手修 profile 里的 application_menu 笔误（见文件头；纯 JSON 文本，DLL 不读它）---
$prof = Join-Path (Split-Path (Split-Path (Split-Path $dll -Parent) -Parent) -Parent) 'resources\input\pico_controller_profile.json'
$badKey = '"input/application_menu"'
$goodKey = '"/input/application_menu"'
if (-not (Test-Path -LiteralPath $prof)) {
    Write-Host "[!] 没找到 $prof（换过版本？），跳过 profile 修补" -ForegroundColor Yellow
}
else {
    $txt = [System.IO.File]::ReadAllText($prof)
    if (-not $txt.Contains($badKey)) {
        Write-Host '[=] profile 里的 application_menu 已经是对的，跳过'
    }
    elseif ($txt.Contains($goodKey)) {
        Write-Host "[!] $prof 里同时存在正确与错误的 application_menu，跳过（人工看一眼）" -ForegroundColor Yellow
    }
    else {
        $porig = "$prof.orig"
        if (-not (Test-Path -LiteralPath $porig)) {
            Copy-Item -LiteralPath $prof -Destination $porig -Force
            Write-Host "[+] 已备份 -> $porig"
        }
        # 原文件的 BOM 有无照原样保留（厂商这份是无 BOM UTF-8）
        $bytes = [System.IO.File]::ReadAllBytes($prof)
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        [System.IO.File]::WriteAllText($prof, $txt.Replace($badKey, $goodKey), (New-Object System.Text.UTF8Encoding($bom)))
        $chk = [System.IO.File]::ReadAllText($prof)
        if ($chk.Contains($badKey) -or -not $chk.Contains($goodKey)) { Die "application_menu 修补复核失败：$prof" }
        Write-Host '[+] profile 已补上 /input/application_menu（menu 键在 SteamVR 里从此可用）' -ForegroundColor Green
        Write-Host "[i] 还原：把 $porig 复制回 $(Split-Path $prof -Leaf)"
    }
}

# --- 顺手修手柄渲染模型（见文件头；纯 JSON 文本，DLL 不读它）---
# 只修 tip 的角度笔误：就地改，不从 .orig 重算、不做回滚（见 docs/notes/04_e-driver-offset.md）。
$resRoot = Join-Path (Split-Path (Split-Path (Split-Path $dll -Parent) -Parent) -Parent) 'resources'
$rmRoot = Join-Path $resRoot 'rendermodels'
$tipBad = '[-21.282,3.0,0.0]'  # DP 独有；UW / v2 / neo2 都是 -1.282
$tipGood = '[-1.282,0.0,0.0]'

# 组件块的首末行号（缩进 ≤8 空格的 `}` 收尾，厂商的 component_local 收尾缩进是乱的）
function Get-ComponentRange {
    param([string[]]$Lines, [string]$Name)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch ('^\s*"' + [regex]::Escape($Name) + '"\s*:\s*\{')) { continue }
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            if ($Lines[$j] -match '^\s{0,8}\}\s*,?\s*$') { return @($i, $j) }
        }
        return @($i, $Lines.Count - 1)
    }
    return $null
}

if (-not (Test-Path -LiteralPath $rmRoot)) {
    Write-Host "[!] 没找到 $rmRoot（换过版本？），跳过渲染模型修补" -ForegroundColor Yellow
}
else {
    $models = @(Get-ChildItem -LiteralPath $rmRoot -Directory | Where-Object { $_.Name -match '^pico_[a-z0-9_]+_(left|right)controller$' })
    if (-not $models) { Write-Host '[!] rendermodels 里没有 pico 手柄模型，跳过' -ForegroundColor Yellow }
    foreach ($m in $models) {
        $json = Join-Path $m.FullName ($m.Name + '.json')
        if (-not (Test-Path -LiteralPath $json)) {
            Write-Host "[!] $($m.Name) 里没有 $(Split-Path $json -Leaf)，跳过" -ForegroundColor Yellow
            continue
        }
        $jorig = "$json.orig"
        $live = [System.IO.File]::ReadAllText($json)
        try { $null = $live | ConvertFrom-Json } catch {
            Write-Host "[!] $(Split-Path $json -Leaf) 不是合法 JSON（厂商原件即如此），跳过" -ForegroundColor Yellow
            continue
        }
        if (-not (Test-Path -LiteralPath $jorig)) {
            Copy-Item -LiteralPath $json -Destination $jorig -Force
            Write-Host "[+] 已备份 -> $(Split-Path $jorig -Leaf)"
        }
        $text = $live  # 就地改当前文件（不重算、不回滚）
        $nb = [System.IO.File]::ReadAllBytes($json)
        $bom = $nb.Length -ge 3 -and $nb[0] -eq 0xEF -and $nb[1] -eq 0xBB -and $nb[2] -eq 0xBF
        $nl = "`n"
        if ($text.Contains("`r`n")) { $nl = "`r`n" }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.AddRange([string[]]$text.Split([string[]]@($nl), [System.StringSplitOptions]::None))

        $rt = Get-ComponentRange -Lines $lines.ToArray() -Name 'tip'
        if (-not $rt) {
            Write-Host "[!] $(Split-Path $json -Leaf) 缺 tip 组件，跳过" -ForegroundColor Yellow
            continue
        }

        $changes = @()
        for ($i = $rt[0]; $i -le $rt[1]; $i++) {
            if ($lines[$i] -notmatch '"rotate_xyz"\s*:') { continue }
            if ($lines[$i].Contains($tipBad)) {
                $lines[$i] = $lines[$i].Replace($tipBad, $tipGood)
                $changes += 'tip 角度'
            }
            break
        }
        $out = ($lines -join $nl)
        if ([System.IO.File]::ReadAllText($json) -eq $out) {
            Write-Host "[=] $($m.Name)：已经是目标内容，跳过"
            continue
        }

        [System.IO.File]::WriteAllText($json, $out, (New-Object System.Text.UTF8Encoding($bom)))

        # 复核：JSON 仍然合法、笔误已消失
        $chk = [System.IO.File]::ReadAllText($json)
        try { $null = $chk | ConvertFrom-Json } catch { Die "$(Split-Path $json -Leaf) 写坏了（不再是合法 JSON）" }
        if ($chk.Contains($tipBad)) { Die "$(Split-Path $json -Leaf) 复核失败：tip 角度没改掉" }
        Write-Host "[+] $($m.Name)：$($changes -join ' / ')（备份 $(Split-Path $jorig -Leaf)）" -ForegroundColor Green
    }
}

# --- 改动 D：手柄握把位姿（见文件头与 docs/notes/04_f-driver-hand-grip.md）---
# 位姿与模型必须成对改：ini 把 device pose 挪到握把点，顶点做反向平移+旋转留在物理位置。
# 顶点从 .orig 重算；17 个原始文件的指纹必须匹配（换了版本就中止，别硬移）。
$handObjSha = '6a6e82bfda8ac4ad7937905bb8cf2691db51c6e22674ce6ec6afecff110dc208'
$handCfgs = @(
    [pscustomobject]@{ Dir = 'pico_neo3_leftcontroller'; Tx = 0.0099; Ty = 0.0115; Tz = -0.0401; Yaw = -0.99; Roll = 10.23 },
    [pscustomobject]@{ Dir = 'pico_neo3_rightcontroller'; Tx = -0.0099; Ty = 0.0115; Tz = -0.0401; Yaw = 0.99; Roll = -10.23 }
)
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Get-HandObjSha {
    $ms = New-Object System.IO.MemoryStream
    try {
        foreach ($c in $handCfgs) {
            $d = Join-Path $rmRoot $c.Dir
            if (-not (Test-Path -LiteralPath $d)) { return $null }
            foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.obj' | Sort-Object Name)) {
                $bo = "$($f.FullName).orig"
                $src = if (Test-Path -LiteralPath $bo) { $bo } else { $f.FullName }
                $bytes = [System.IO.File]::ReadAllBytes($src)
                $ms.Write($bytes, 0, $bytes.Length)
                $rel = [System.Text.Encoding]::ASCII.GetBytes($c.Dir + '/' + $f.Name)
                $ms.Write($rel, 0, $rel.Length)
                $ms.WriteByte(0)
            }
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash($ms.ToArray()) } finally { $sha.Dispose() }
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $ms.Dispose() }
}

if (-not (Test-Path -LiteralPath $rmRoot)) { Die "找不到 $rmRoot（换过版本？）—— 改动 D 需要它，已中止" }
$shaGot = Get-HandObjSha
if ($shaGot -ne $handObjSha) {
    Die ("手柄渲染模型不是支持的那版（指纹 {0}，预期 {1}）；先把 rendermodels\pico_neo3_*\*.obj.orig 还原回去再跑（已中止，未写入）" -f $shaGot, $handObjSha)
}
Write-Host '[+] 手柄渲染模型校验通过' -ForegroundColor Green

# 备份：`.orig` = 动手前那一刻（这里已验过是支持的那版）
foreach ($c in $handCfgs) {
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $rmRoot $c.Dir) -Filter '*.obj')) {
        if (-not (Test-Path -LiteralPath "$($f.FullName).orig")) { Copy-Item -LiteralPath $f.FullName -Destination "$($f.FullName).orig" -Force }
    }
}

function Convert-HandObj {
    param($Cfg)
    $deg = [math]::PI / 180.0
    $cy = [math]::Cos(-$Cfg.Yaw * $deg); $sy = [math]::Sin(-$Cfg.Yaw * $deg)
    $cz = [math]::Cos(-$Cfg.Roll * $deg); $sz = [math]::Sin(-$Cfg.Roll * $deg)
    $changed = 0
    $d = Join-Path $rmRoot $Cfg.Dir
    foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.obj' | Sort-Object Name)) {
        $orig = "$($f.FullName).orig"
        $text = [System.IO.File]::ReadAllText($orig, [System.Text.Encoding]::ASCII)
        $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $lines = $text -split "\r?\n"
        $cnt = 0
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i] -notmatch '^v\s+(\S+)\s+(\S+)\s+(\S+)\s*$') { continue }
            $x = [double]::Parse($Matches[1], $inv)
            $y = [double]::Parse($Matches[2], $inv)
            $z = [double]::Parse($Matches[3], $inv)
            $x1 = $x * $cy + $z * $sy
            $z1 = - $x * $sy + $z * $cy
            $x2 = $x1 * $cz - $y * $sz
            $y2 = $x1 * $sz + $y * $cz
            $lines[$i] = 'v  {0} {1} {2}' -f ($x2 - $Cfg.Tx).ToString('F6', $inv), ($y2 - $Cfg.Ty).ToString('F6', $inv), ($z1 - $Cfg.Tz).ToString('F6', $inv)
            $cnt++
        }
        if ($cnt -eq 0) { Die "$($f.Name) 里没有顶点，已中止（不是支持的那版？）" }
        $out = $lines -join $nl
        if ([System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::ASCII) -ne $out) {
            [System.IO.File]::WriteAllText($f.FullName, $out, [System.Text.Encoding]::ASCII)
            $changed++
        }
        $vc = ([regex]::Matches([System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::ASCII), '(?m)^v\s')).Count
        if ($vc -ne $cnt) { Die "$($f.Name) 顶点数复核失败" }
    }
    return $changed
}

$handChanged = $false
foreach ($c in $handCfgs) {
    $n = Convert-HandObj -Cfg $c
    if ($n -gt 0) {
        $handChanged = $true
        Write-Host "[+] $($c.Dir)：顶点已反向补偿（$n 个文件）" -ForegroundColor Green
    }
    else {
        Write-Host "[=] $($c.Dir)：顶点已是目标值，跳过"
    }
}

# ini：把 [controller] 段换成目标值（只动这一段，其它配置原样保留）
$ini = Join-Path (Split-Path $dll -Parent) 'RVRPlugin.ini'
$iniChanged = $false
if (-not (Test-Path -LiteralPath $ini)) {
    Write-Host "[!] 没找到 $ini（换过版本？），跳过 [controller] 偏移" -ForegroundColor Yellow
}
else {
    $iniOrig = "$ini.orig"
    if (-not (Test-Path -LiteralPath $iniOrig)) {
        Copy-Item -LiteralPath $ini -Destination $iniOrig -Force
        Write-Host "[+] 已备份 -> $(Split-Path $iniOrig -Leaf)"
    }
    $text = [System.IO.File]::ReadAllText($ini, [System.Text.Encoding]::ASCII)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($ln in ($text -split "\r?\n")) {
        if ($ln -match '^\s*\[controller\]\s*$') { $skip = $true; continue }
        if ($skip -and $ln -match '^\s*\[') { $skip = $false }
        if (-not $skip) { $out.Add($ln) }
    }
    while ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { $out.RemoveAt($out.Count - 1) }
    $sec = New-Object System.Collections.Generic.List[string]
    $sec.Add('[controller]')
    foreach ($c in $handCfgs) {
        $side = if ($c.Dir -like '*left*') { 'left' } else { 'right' }
        $sec.Add(('{0}x={1}' -f $side, $c.Tx.ToString($inv)))
        $sec.Add(('{0}y={1}' -f $side, $c.Ty.ToString($inv)))
        $sec.Add(('{0}z={1}' -f $side, $c.Tz.ToString($inv)))
        $sec.Add(('{0}pitch=0.0' -f $side))
        $sec.Add(('{0}yaw={1}' -f $side, $c.Yaw.ToString($inv)))
        $sec.Add(('{0}roll={1}' -f $side, $c.Roll.ToString($inv)))
    }
    $new = (($out -join $nl).TrimEnd("`r", "`n")) + $nl + ($sec -join $nl) + $nl
    if ([System.IO.File]::ReadAllText($ini, [System.Text.Encoding]::ASCII) -ne $new) {
        [System.IO.File]::WriteAllText($ini, $new, [System.Text.Encoding]::ASCII)
        $iniChanged = $true
        Write-Host '[+] RVRPlugin.ini：[controller] 偏移已写入' -ForegroundColor Green
    }
    else { Write-Host '[=] RVRPlugin.ini：[controller] 偏移已是最新，跳过' }
    $chk = [System.IO.File]::ReadAllText($ini, [System.Text.Encoding]::ASCII)
    if (-not $chk.Contains('[controller]') -or -not $chk.Contains('leftz=-0.0401')) { Die 'RVRPlugin.ini 复核失败：没写进 [controller] 偏移' }
}
if ($handChanged -or $iniChanged) {
    Write-Host '[+] 手柄握把位置已修正：虚拟手落在握把上，模型仍和实物对齐' -ForegroundColor Green
}
else {
    Write-Host '[=] 手柄握把位置已经是最新，跳过'
}

# --- 补厂商漏发的 HMD profile（见文件头）---
$inRoot = Join-Path $resRoot 'input'
$hmdProf = Join-Path $inRoot 'pico_hmd_profile.json'
if (-not (Test-Path -LiteralPath $inRoot)) {
    Write-Host "[!] 没找到 $inRoot（换过版本？），跳过 HMD profile 修补" -ForegroundColor Yellow
}
elseif (Test-Path -LiteralPath $hmdProf) {
    Write-Host '[=] pico_hmd_profile.json 已存在，跳过'
}
else {
    $hmdText = @'
{
  "jsonid": "input_profile",
  "controller_type": "pico_hmd",
  "input_bindingui_mode": "hmd",
  "input_source": {
    "/input/system": {
      "type": "button",
      "binding_image_point": [ 180, 110 ]
    },
    "/pose/raw": {
      "type": "pose",
      "binding_image_point": [ 63, 148 ]
    }
  }
}
'@
    $hmdText = $hmdText.Replace("`r`n", "`n").Replace("`n", "`r`n").TrimEnd([char[]]"`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($hmdProf, $hmdText, (New-Object System.Text.UTF8Encoding($false)))
    try { $null = [System.IO.File]::ReadAllText($hmdProf) | ConvertFrom-Json } catch { Die "$(Split-Path $hmdProf -Leaf) 写坏了（不是合法 JSON）" }
    Write-Host '[+] 已补上 input\pico_hmd_profile.json（驱动不再报 profile 缺失，头显也不再被模拟成 Rift）' -ForegroundColor Green
}

Write-Host '[i] 还原：把同名 .orig 覆盖回去'
Write-Host '      · driver_pico.dll'
Write-Host '      · RVRPlugin.ini'
Write-Host '      · profile'
Write-Host '      · rendermodels\*.json'
Write-Host '      · rendermodels\*\*.obj'

