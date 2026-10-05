<#
get_deps.ps1 —— 从上游自动拉取并准备依赖二进制

产物（下载到 src/windows/temp/，整目录被 .gitignore 忽略）：
    temp/frida-inject        frida 官方 release 16.7.19 · android-arm64（.xz 解压）
    temp/picohaxx.neo3.bin   上游 picohaxx（仓库根预编译二进制）+ Neo 3 适配补丁
    temp/platform-tools/     platform-tools 37.0.1（仅 adb.exe + AdbWinApi.dll + AdbWinUsbApi.dll）
        —— 只在 -PlatformTools 时；由 _utils.ps1 的 Get-AdbPath 在本机没装 adb 时按需调用

Neo 3 补丁（对上游二进制逐字节校验后原地改写）：
    0x34b6  18B  '5.9.9-202408300028' → '202409100313' + 6×NUL
        固件串改短，兼容 '-' / '_' 两种分隔符（见 docs/notes/06-root.md）
    0x164ef9  1B  0xB0 → 0x50
        selinux_state 0xffffff800aabb000 → 0xffffff800aab5000

用法：powershell -ExecutionPolicy Bypass -File src\windows\get_deps.ps1 [-Force] [-PlatformTools]
#>
[CmdletBinding()]
param(
    # 即使已存在也重新下载
    [switch]$Force,
    # 额外准备 platform-tools（adb）；本机没装 adb 时 Get-AdbPath 会自己带这个开关调进来
    [switch]$PlatformTools
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. "$PSScriptRoot\_utils.ps1"
$Cache = (Get-RepoPaths -ScriptDir $PSScriptRoot).Cache
$Inj = Join-Path $Cache 'frida-inject'
$Haxx = Join-Path $Cache 'picohaxx.neo3.bin'
New-Item -ItemType Directory -Force $Cache | Out-Null

$FridaVer = '16.7.19'
$InjName = "frida-inject-$FridaVer-android-arm64"
# 直链优先；GitHub 不通时回退镜像
$InjUrls = @(
    "https://github.com/frida/frida/releases/download/$FridaVer/$InjName.xz",
    "https://ghfast.top/https://github.com/frida/frida/releases/download/$FridaVer/$InjName.xz"
)
$HaxxMd5 = '734ddd6f8157378b2785183c5cfafa94'
$HaxxUrls = @(
    'https://raw.githubusercontent.com/264312431/picohaxx/main/picohaxx',
    'https://ghfast.top/https://raw.githubusercontent.com/264312431/picohaxx/main/picohaxx'
)

function Download([string[]]$urls, [string]$out) {
    foreach ($u in $urls) {
        Write-Host "[*] 下载 $u"
        try {
            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                & curl.exe -fL --retry 3 --connect-timeout 15 -o $out $u
                if ($LASTEXITCODE -eq 0 -and (Test-Path $out)) { return $true }
            }
            else {
                Invoke-WebRequest -Uri $u -OutFile $out -UseBasicParsing
                if (Test-Path $out) { return $true }
            }
        }
        catch { Write-Host "[!] 失败：$($_.Exception.Message)" -ForegroundColor Yellow }
    }
    return $false
}

# 外部命令的可执行路径；找不到返回 $null（StrictMode 下对 $null 取 .Source 会抛 PropertyNotFoundException）
function Get-ExePath([string]$name) {
    return (Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
}

# 解 xz：依次尝试 7z / tar / xz（Windows 自带 tar 对多 block xz 可能失败）
function Expand-Xz([string]$xz, [string]$out) {
    $sevenz = @(
        (Get-ExePath 7z),
        (Get-ExePath 7za),
        (Get-ExePath 7zz),
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\7z.exe",
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    if ($sevenz) {
        & $sevenz x -y -aoa "-o$out" "$xz" *> $null
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-Host '[!] 7z 解压失败，尝试 tar…' -ForegroundColor Yellow
    }
    try {
        & tar -xf $xz -C $out 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    catch {
        Write-Verbose "tar 起不来（$($_.Exception.Message)），换 xz 解压"
    }
    Write-Host '[!] tar 解压失败，尝试 xz…' -ForegroundColor Yellow
    $xzc = Get-ExePath xz
    if ($xzc) {
        & $xzc -dc "$xz" > (Join-Path $out $InjName)
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    return $false
}

# --- frida-inject ---
if ($Force -or -not (Test-Path $Inj)) {
    $tmp = Join-Path $env:TEMP 'pico-deps'
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $xz = Join-Path $tmp "$InjName.xz"
    if (-not (Download $InjUrls $xz)) { Write-Host '[X] frida-inject 下载失败' -ForegroundColor Red; exit 1 }
    $out = Join-Path $tmp 'x'
    Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $out | Out-Null
    if (-not (Expand-Xz $xz $out)) {
        Write-Host '[X] 解压 .xz 失败：请安装 7-Zip（或确保 tar/xz 可用）' -ForegroundColor Red; exit 1
    }
    $raw = Join-Path $out $InjName
    if (-not (Test-Path $raw)) { Write-Host "[X] 解压后找不到 $InjName" -ForegroundColor Red; exit 1 }
    Move-Item -Force $raw $Inj
    Write-Host "[+] frida-inject -> $Inj"
}

# --- picohaxx + Neo 3 补丁 ---
if ($Force -or -not (Test-Path $Haxx)) {
    $raw = Join-Path $env:TEMP 'picohaxx.upstream'
    if (-not (Download $HaxxUrls $raw)) { Write-Host '[X] picohaxx 下载失败' -ForegroundColor Red; exit 1 }

    $md5 = (Get-FileHash $raw -Algorithm MD5).Hash.ToLower()
    if ($md5 -ne $HaxxMd5) {
        Write-Host "[X] 上游 picohaxx md5 = $md5，预期 $HaxxMd5" -ForegroundColor Red
        Write-Host '    上游已更新，补丁偏移需重新确认（见 docs/notes/06-root.md）；已中止，未写入。' -ForegroundColor Red
        exit 1
    }

    $bytes = [System.IO.File]::ReadAllBytes($raw)

    $fw = -join (0x34b6..0x34c7 | ForEach-Object { [char]$bytes[$_] })
    if ($fw -ne '5.9.9-202408300028') {
        Write-Host "[X] 固件串不符：'$fw'（预期 '5.9.9-202408300028'）；已中止。" -ForegroundColor Red; exit 1
    }
    if ($bytes[0x164ef9] -ne 0xB0) {
        Write-Host ("[X] 0x164ef9 = 0x{0:X2}（预期 0xB0）；已中止。" -f $bytes[0x164ef9]) -ForegroundColor Red; exit 1
    }

    [byte[]]$new = [System.Text.Encoding]::ASCII.GetBytes('202409100313') + [byte[]](0, 0, 0, 0, 0, 0)
    [Array]::Copy($new, 0, $bytes, 0x34b6, 18)
    $bytes[0x164ef9] = 0x50
    [System.IO.File]::WriteAllBytes($Haxx, $bytes)
    Write-Host '[+] picohaxx.neo3.bin 已生成（Neo 3 补丁已应用）'
}

# --- platform-tools（adb）---
# 只在本机确实没有 adb 时才需要；Get-AdbPath 找不到 adb 就带 -PlatformTools 调进来
$PtVer = '37.0.1'
$PtZip = "platform-tools_r$PtVer-win.zip"
$PtMd5 = '2ec4ec3af6f4779b23c7fe34e4662e85'
$PtDir = Join-Path $Cache 'platform-tools'
$PtExe = Join-Path $PtDir 'adb.exe'
$PtUrls = @(
    "https://mirrors.cloud.tencent.com/AndroidSDK/$PtZip",  # 国内镜像（repository2-3.xml 与官方逐字节一致）
    "https://dl.google.com/android/repository/$PtZip"
)
if ($PlatformTools -and ($Force -or -not (Test-Path $PtExe))) {
    $tmp = Join-Path $env:TEMP 'pico-deps'
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $zip = Join-Path $tmp $PtZip
    if (-not (Download $PtUrls $zip)) { Write-Host '[X] platform-tools 下载失败' -ForegroundColor Red; exit 1 }

    $md5 = (Get-FileHash $zip -Algorithm MD5).Hash.ToLower()
    if ($md5 -ne $PtMd5) {
        Write-Host "[X] platform-tools md5 = $md5，预期 $PtMd5" -ForegroundColor Red
        Write-Host '    （新版本需重新确认 md5；已中止，未写入。）' -ForegroundColor Red
        exit 1
    }

    $x = Join-Path $tmp 'pt'
    Remove-Item -Recurse -Force $x -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $x -Force
    Remove-Item -Recurse -Force $PtDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $PtDir | Out-Null
    # adb.exe 只依赖这两个 DLL，其余（fastboot / mke2fs …）不装
    foreach ($f in 'adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll') {
        $src = Join-Path $x "platform-tools\$f"
        if (-not (Test-Path $src)) { Write-Host "[X] 解压后找不到 $f" -ForegroundColor Red; exit 1 }
        Copy-Item $src (Join-Path $PtDir $f)
    }
    Remove-Item -Force $zip -ErrorAction SilentlyContinue
    Write-Host "[+] platform-tools $PtVer -> $PtDir"
}

Write-Host ''
Write-Host '[+] 依赖就绪：' -ForegroundColor Green
$items = @($Inj, $Haxx)
if (Test-Path $PtExe) { $items += $PtExe }
Get-Item $items | ForEach-Object { Write-Host ("    {0}  ({1:N0} B)" -f $_.FullName, $_.Length) }
if (Test-Path $PtExe) { Write-Host ("    {0}" -f ((& $PtExe version | Select-Object -First 1))) }
