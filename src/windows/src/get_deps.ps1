<#
get_deps.ps1 —— 从上游自动拉取并准备依赖二进制

产物（下载到 src/windows/temp/，整目录被 .gitignore 忽略）：
    temp/frida-inject        frida 官方 release 16.7.19 · android-arm64（.xz 解压）
    temp/picohaxx.neo3.bin   上游 picohaxx（仓库根预编译二进制）+ Neo 3 适配补丁

Neo 3 补丁（对上游二进制逐字节校验后原地改写）：
    0x34b6  18B  '5.9.9-202408300028' → '202409100313' + 6×NUL
        固件串改短，兼容 '-' / '_' 两种分隔符（见 docs/notes/06-root.md）
    0x164ef9  1B  0xB0 → 0x50
        selinux_state 0xffffff800aabb000 → 0xffffff800aab5000

用法：powershell -ExecutionPolicy Bypass -File src\windows\get_deps.ps1 [-Force]
#>
[CmdletBinding()]
param(
    # 即使已存在也重新下载
    [switch]$Force
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

# 解 xz：依次尝试 7z / tar / xz（Windows 自带 tar 对多 block xz 可能失败）
function Expand-Xz([string]$xz, [string]$out) {
    $sevenz = @(
        (Get-Command 7z   -ErrorAction SilentlyContinue).Source,
        (Get-Command 7za  -ErrorAction SilentlyContinue).Source,
        (Get-Command 7zz  -ErrorAction SilentlyContinue).Source,
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
    $xzc = (Get-Command xz -ErrorAction SilentlyContinue).Source
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

Write-Host ''
Write-Host '[+] 依赖就绪：' -ForegroundColor Green
Get-Item $Inj, $Haxx | ForEach-Object { Write-Host ("    {0}  ({1:N0} B)" -f $_.FullName, $_.Length) }
