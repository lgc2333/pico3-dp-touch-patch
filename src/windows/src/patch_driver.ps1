<#
patch_driver.ps1 —— 给 PICO DP 驱动打补丁：让扳机 / 摇杆顶的电容触摸生效

改动（零长度变化）：
    /input/trigger/touch   ← 键值字 bit5   (原: 扳机模拟量 != 0)
    /input/joystick/touch  ← 键值字 bit7   (原: 摇杆偏离中位)
    kTriggerTouch 调试打印 ← 恒跳过        (厂商遗留：拉扳机时以 ~200 Hz 刷 SteamVR Console；见 docs/notes/04-driver.md)

顺手修 profile：`resources\input\pico_controller_profile.json` 里的 `"input/application_menu"` 少一个 `/`，
    这条声明不生效 ⇒ menu 键在 SteamVR 里没反应；补成 `"/input/application_menu"`（实测补完 menu / system 键都正常）。
    只改 JSON 文本，DLL 不读这个文件；备份为同名 `.orig`。

顺手修渲染模型：`resources\rendermodels\*\*.json` 补上 SteamVR 兼容层要取的 pose 组件
    （`grip` / `aim` / `openxr_grip` / `openxr_aim`，值取该模型自己的 `handgrip` / `tip`），
    并把 `tip` 的角度笔误改回 `-1.282`（UW / v2 / neo2 都是这个值）。
    缺这些组件时 SteamVR 取到 0 ⇒ 被模拟成 Oculus 的游戏里手柄模型错位（SteamVR 菜单不受影响）。见 docs/notes/04-driver.md。

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
    @{ off = 0x18c6f; old = '740C'; new = 'EB0C'; what = 'kTriggerTouch 打印 <- 恒跳过' },
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
Write-Host '[i] 还原：把同名 .orig 覆盖回去（driver_pico.dll / profile / rendermodels\*.json 三处都有）。'

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
# 兼容层模拟成 Oculus 时 SteamVR 去取 grip / aim / openxr_*，厂商模型只有 handgrip / tip ⇒ 取到 0、模型错位。
$resRoot = Join-Path (Split-Path (Split-Path (Split-Path $dll -Parent) -Parent) -Parent) 'resources'
$rmRoot = Join-Path $resRoot 'rendermodels'

# 要补的组件 ← 取哪个现成组件的值（都是同一套模型坐标）
$addFrom = @(
    @{ name = 'grip'; src = 'handgrip' },
    @{ name = 'openxr_grip'; src = 'handgrip' },
    @{ name = 'aim'; src = 'tip' },
    @{ name = 'openxr_aim'; src = 'tip' }
)
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

# 取组件里的 origin / rotate_xyz 原文（按厂商的 16 空格缩进重排）
function Get-ComponentLocalLine {
    param([string[]]$Lines, [int]$From, [int]$To, [string]$Key)
    for ($i = $From; $i -le $To; $i++) {
        if ($Lines[$i] -match ('"' + [regex]::Escape($Key) + '"\s*:')) { return ('                ' + $Lines[$i].Trim()) }
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
        $text = [System.IO.File]::ReadAllText($jorig)  # 从 .orig 重算，重复跑得到同一结果
        $nb = [System.IO.File]::ReadAllBytes($jorig)
        $bom = $nb.Length -ge 3 -and $nb[0] -eq 0xEF -and $nb[1] -eq 0xBB -and $nb[2] -eq 0xBF
        $nl = "`n"
        if ($text.Contains("`r`n")) { $nl = "`r`n" }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.AddRange([string[]]$text.Split([string[]]@($nl), [System.StringSplitOptions]::None))

        $rg = Get-ComponentRange -Lines $lines.ToArray() -Name 'handgrip'
        $rt = Get-ComponentRange -Lines $lines.ToArray() -Name 'tip'
        if (-not $rg -or -not $rt) {
            Write-Host "[!] $(Split-Path $json -Leaf) 缺 handgrip / tip 组件，跳过" -ForegroundColor Yellow
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

        $compIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*"components"\s*:\s*\{') { $compIdx = $i; break }
        }
        if ($compIdx -lt 0) {
            Write-Host "[!] $(Split-Path $json -Leaf) 没有 components 块，跳过" -ForegroundColor Yellow
            continue
        }
        $rg = Get-ComponentRange -Lines $lines.ToArray() -Name 'handgrip'
        $rt = Get-ComponentRange -Lines $lines.ToArray() -Name 'tip'
        $ins = New-Object System.Collections.Generic.List[string]
        foreach ($a in $addFrom) {
            if (Get-ComponentRange -Lines $lines.ToArray() -Name $a.name) { continue }
            $src = $rg
            if ($a.src -eq 'tip') { $src = $rt }
            $origin = Get-ComponentLocalLine -Lines $lines.ToArray() -From $src[0] -To $src[1] -Key 'origin'
            $rot = Get-ComponentLocalLine -Lines $lines.ToArray() -From $src[0] -To $src[1] -Key 'rotate_xyz'
            if (-not $origin -or -not $rot) {
                Write-Host "[!] $(Split-Path $json -Leaf)：$($a.name) 取不到源组件值，跳过这一条" -ForegroundColor Yellow
                continue
            }
            $ins.Add('        "' + $a.name + '": {')
            $ins.Add('            "component_local" : {')
            $ins.Add($origin)
            $ins.Add($rot)
            $ins.Add('            }')
            $ins.Add('        },')
            $changes += $a.name
        }
        if ($ins.Count) { $lines.InsertRange($compIdx + 1, $ins) }
        if (-not $changes.Count) {
            Write-Host "[=] $($m.Name)：组件与角度都已是对的，跳过"
            continue
        }
        $out = ($lines -join $nl)
        if ([System.IO.File]::ReadAllText($json) -eq $out) {
            Write-Host "[=] $($m.Name)：已经补过，跳过"
            continue
        }

        [System.IO.File]::WriteAllText($json, $out, (New-Object System.Text.UTF8Encoding($bom)))

        $chk = [System.IO.File]::ReadAllText($json)
        $j = $null
        try { $j = $chk | ConvertFrom-Json } catch { Die "$(Split-Path $json -Leaf) 写坏了（不再是合法 JSON）" }
        foreach ($a in $addFrom) {
            if (@($j.components.PSObject.Properties.Name) -notcontains $a.name) { Die "$(Split-Path $json -Leaf) 复核失败：缺 $($a.name)" }
        }
        if ($chk.Contains($tipBad)) { Die "$(Split-Path $json -Leaf) 复核失败：tip 角度没改掉" }
        Write-Host "[+] $($m.Name)：$($changes -join ' / ')（备份 $(Split-Path $jorig -Leaf)）" -ForegroundColor Green
    }
}
