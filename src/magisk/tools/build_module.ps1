<#
build_module.ps1 —— 把 Magisk 模块打包成 zip（产物在 temp\magisk\，不入库）

模块内容全部现场生成：补丁库 = 原厂库 + DT_NEEDED，shim = 用 NDK 编译。
时机、指纹与固件闸门的说明见 docs\notes\11-magisk-module.md。
脚本本身不依赖 Windows：PowerShell 5.1 与 pwsh 7 都能跑，Linux CI 里也能打同一个 zip。

用法：
    pnpm build:magisk                                      # NDK 自动找
    powershell -File src\magisk\tools\build_module.ps1      # PS 5.1
    pwsh -File src/magisk/tools/build_module.ps1           # pwsh 7 / Linux
    pwsh -File src/magisk/tools/build_module.ps1 -Ndk <NDK 路径>
#>
[CmdletBinding()]
param(
    [string]$Ndk
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 从 pwsh 里经 pnpm 调 powershell 时，继承的 PSModulePath 把 PS7 的模块根排在前面，
# 5.1 会加载到 PS7 的副本 ⇒ Get-FileHash / Invoke-Formatter 这些直接消失。5.1 只认自己那三个根。
if ($PSVersionTable.PSVersion.Major -lt 6 -and $env:PSModulePath) {
    $env:PSModulePath = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
        (Join-Path $PSHOME 'Modules')
    ) -join [System.IO.Path]::PathSeparator
}

$OnWindows = $PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows
$OnMac = ($PSVersionTable.PSVersion.Major -ge 6) -and $IsMacOS
if ($OnWindows) { $HostTriple = 'windows-x86_64' } elseif ($OnMac) { $HostTriple = 'darwin-x86_64' } else { $HostTriple = 'linux-x86_64' }

$Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$Magisk = Join-Path $Root 'src/magisk'
$Out = Join-Path $Root 'temp/magisk'
$Build = Join-Path $Out 'build'
$Stage = Join-Path $Out 'stage'
$StageLib = Join-Path (Join-Path $Stage 'system') 'lib64'
$Vendor = Join-Path $Magisk 'tools/resources/libpxrstreamingservice.so'
$ShimSrc = Join-Path $Magisk 'shim/picotouch_shim.c'
$Shim = Join-Path $Build 'picotouch_shim.so'
$Patched = Join-Path $StageLib 'libpxrstreamingservice.so'
$Zip = Join-Path $Out 'pico_dp_touch.zip'
$ShaFile = Join-Path $Magisk 'tools/vendor_lib.sha256'

function Find-Ndk([string]$Hint) {
    if ($Hint) { return $Hint }
    foreach ($name in @('ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }
    $sdks = @()
    foreach ($name in @('ANDROID_HOME', 'ANDROID_SDK_ROOT')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $sdks += $value }
    }
    if ($OnWindows) {
        $value = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
        if ($value) { $sdks += (Join-Path $value 'Android/Sdk') }
    }
    foreach ($sdk in $sdks) {
        $dir = Join-Path $sdk 'ndk'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $cand = @(Get-ChildItem -LiteralPath $dir -Directory | Where-Object { $_.Name -match '^\d+(\.\d+)*$' } | Sort-Object { [version]$_.Name })
        if ($cand.Count -gt 0) { return $cand[-1].FullName }
    }
    return ''
}

function Build-Shim([string]$NdkPath) {
    $bin = Join-Path $NdkPath "toolchains/llvm/prebuilt/$HostTriple/bin"
    $cc = Join-Path $bin 'aarch64-linux-android29-clang'
    if ($OnWindows) { $cc = "$cc.cmd" }  # 无扩展名那个是给 MSYS 的 shell 脚本，PowerShell 起不来
    if (-not (Test-Path -LiteralPath $cc)) { Write-Host "[X] NDK 里找不到 clang：$cc" -ForegroundColor Red; exit 1 }
    New-Item -ItemType Directory -Force -Path $Build | Out-Null
    Write-Host '[i] 编译 shim…'
    & $cc -shared -fPIC -O2 -Wall -Wextra -o $Shim $ShimSrc -llog '-Wl,-z,max-page-size=4096'
    if ($LASTEXITCODE -ne 0) { Write-Host "[X] 编译 shim 失败（rc=$LASTEXITCODE）" -ForegroundColor Red; exit 1 }
}

if (-not (Test-Path -LiteralPath $Vendor)) { Write-Host "[X] 找不到原厂库：$Vendor" -ForegroundColor Red; exit 1 }
$expect = (Get-Content -LiteralPath $ShaFile -Raw).Trim()
$actual = (Get-FileHash -LiteralPath $Vendor -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expect) {
    Write-Host "[X] 原厂库指纹不符（$actual）" -ForegroundColor Red
    Write-Host '[i] 只接受 PUI 5.9.9-202409100313 的 libpxrstreamingservice.so' -ForegroundColor Yellow
    exit 1
}

if ((-not (Test-Path -LiteralPath $Shim)) -or ((Get-Item -LiteralPath $ShimSrc).LastWriteTimeUtc -gt (Get-Item -LiteralPath $Shim).LastWriteTimeUtc)) {
    $Ndk = Find-Ndk $Ndk
    if (-not $Ndk) {
        Write-Host '[X] 要编译 shim，但找不到 NDK：用 -Ndk，或设 ANDROID_NDK_HOME / ANDROID_HOME。' -ForegroundColor Red
        exit 1
    }
    Build-Shim $Ndk
}

if (Test-Path -LiteralPath $Stage) { Remove-Item -Recurse -Force -LiteralPath $Stage }
New-Item -ItemType Directory -Force -Path $StageLib | Out-Null

& uv run --no-project (Join-Path $Magisk 'tools/inject_needed.py') $Vendor $Patched
if ($LASTEXITCODE -ne 0) { Write-Host "[X] 补 DT_NEEDED 失败（rc=$LASTEXITCODE）" -ForegroundColor Red; exit 1 }

Copy-Item -LiteralPath $Shim -Destination (Join-Path $StageLib 'picotouch_shim.so')
Copy-Item -LiteralPath (Join-Path $Magisk 'module.prop'), (Join-Path $Magisk 'customize.sh') -Destination $Stage
Copy-Item -Recurse -LiteralPath (Join-Path $Magisk 'META-INF') -Destination $Stage

$patchedText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($Patched))
if (-not $patchedText.Contains('picotouch_shim.so')) { Write-Host '[X] 补丁库没有 DT_NEEDED picotouch_shim.so' -ForegroundColor Red; exit 1 }

if ($PSVersionTable.PSVersion.Major -lt 6) { Add-Type -AssemblyName System.IO.Compression.FileSystem }
if (Test-Path -LiteralPath $Zip) { Remove-Item -Force -LiteralPath $Zip }
[System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $Zip)
Write-Host "[+] $Zip"
