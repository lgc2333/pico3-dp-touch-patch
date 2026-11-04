<#
lint_ps.ps1 —— 对仓库里的 .ps1 跑 PSScriptAnalyzer（规则裁剪见仓库根 PSScriptAnalyzerSettings.psd1）

单独成文件而不是写在 package.json 的命令行里：从 pwsh 里调 powershell 时，继承的 PSModulePath 把 PS7 的模块根
排在前面，5.1 会加载到 PS7 的 PSScriptAnalyzer 副本 ⇒ Invoke-ScriptAnalyzer 直接不存在（见 AGENTS.md）。

用法：powershell -NoProfile -File scripts\lint_ps.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 5.1 只认自己那三个模块根；从 pwsh 继承来的 PS7 路径必须丢掉
if ($PSVersionTable.PSVersion.Major -lt 6 -and $env:PSModulePath) {
    $env:PSModulePath = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
        (Join-Path $PSHOME 'Modules')
    ) -join [System.IO.Path]::PathSeparator
}

$Root = Split-Path -Parent $PSScriptRoot
$Settings = Join-Path $Root 'PSScriptAnalyzerSettings.psd1'
$Failed = $false
foreach ($dir in @('src/windows/src', 'src/magisk/tools', 'scripts')) {
    $target = Join-Path $Root $dir
    Write-Host "[i] 检查 $dir"
    foreach ($issue in @(Invoke-ScriptAnalyzer -Path $target -Recurse -Settings $Settings)) {
        $Failed = $true
        Write-Host ('[X] {0}:{1} {2} ({3})' -f $Issue.ScriptName, $Issue.Line, $Issue.Message, $Issue.RuleName) -ForegroundColor Red
    }
}
if ($Failed) { exit 1 }
Write-Host '[+] 无问题'
