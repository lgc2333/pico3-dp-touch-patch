<#
format_ps.ps1 —— 按本仓库约定格式化 PowerShell 脚本（只动空白，不做语义改动）

三条规则与「文件头为什么不改」见 AGENTS.md 的 Rules › 编码与文件。
安全闸：结果与输入的「非空白内容」不一致、头部没能逐字节搬回、或 ParseFile 报错 —— 任一发生就抛错且不写盘。

用法：
    powershell -File scripts\format_ps.ps1           # 就地格式化 src\windows\src\*.ps1
    powershell -File scripts\format_ps.ps1 -Check    # 只检查：有需要改动的文件就 exit 1（层级警告不影响退出码）
    powershell -File scripts\format_ps.ps1 -Path <文件或目录> [...]
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Split-Path -Parent $PSScriptRoot  # 本文件在 scripts\ 下，仓库根是它的上一级
if (-not $Path) { $Path = @(Join-Path $Root 'src/windows/src') }

$files = @()
foreach ($p in $Path) {
    if (Test-Path -LiteralPath $p -PathType Container) { $files += @(Get-ChildItem -LiteralPath $p -Filter *.ps1) }
    elseif (Test-Path -LiteralPath $p -PathType Leaf) { $files += @(Get-Item -LiteralPath $p) }
    else { Write-Host "[X] 路径不存在：$p" -ForegroundColor Red; exit 1 }
}
if (-not $files) { Write-Host '[X] 没找到要格式化的 .ps1' -ForegroundColor Red; exit 1 }

function Test-HeaderLevel {
    # 只判定文件头是否「顶格起、每级 4 空格」：正文行的缩进去重排序后，期望正好是 0/4/8…
    # 返回告警文本数组（空数组 = 合规）
    param([string]$Header)
    $l = @($Header -split "`r?`n")
    if ($l.Count -lt 3) { return @() }
    $body = @($l[1..($l.Count - 2)] | Where-Object { $_.Trim() })
    if (-not $body) { return @() }
    $inds = @($body | ForEach-Object { $_.Length - $_.TrimStart().Length } | Sort-Object -Unique)
    $want = @(0..($inds.Count - 1) | ForEach-Object { 4 * $_ })
    if (($inds -join ',') -ne ($want -join ',')) {
        return @("文件头块注释层级 {$($inds -join ',')} 不是 4 空格网格（应为 {$($want -join ',')}）—— 本脚本不改文件头，请人工对齐")
    }
    @()
}

function Format-Source {
    # 返回 @{ Text = <结果文本>; Warn = @(<告警>) }；只允许改空白，否则抛错（调用方不写盘）
    param([string]$Text)

    $fmt = Invoke-Formatter -ScriptDefinition $Text
    if ($fmt.StartsWith([char]0xFEFF)) { $fmt = $fmt.Substring(1) }

    $warn = @()
    if ($Text.StartsWith('<#')) {
        $hEnd = $Text.IndexOf('#>')
        if ($hEnd -lt 0) { throw "原文文件头 '<#' 没有闭合的 '#>'" }
        $head = $Text.Substring(0, $hEnd + 2)
        $fEnd = $fmt.IndexOf('#>')
        if ($fEnd -lt 0) { throw '格式化结果里找不到文件头的结尾，拒绝写盘' }
        $fmt = $head + $fmt.Substring($fEnd + 2)  # 头部逐字节搬回，不参与格式化
        $warn = @(Test-HeaderLevel -Header $head)
    }

    $lines = @((($fmt -replace "`r`n", "`n") -replace "`n", "`r`n") -split "`r`n")

    # —— 行尾注释：代码 + 2 空格 + # …
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput(($lines -join "`r`n"), [ref]$tokens, [ref]$errs)
    if ($errs.Count) { throw "Invoke-Formatter 的输出有语法错误：$($errs[0].Message)" }
    foreach ($t in $tokens) {
        if ($t.Kind -ne 'Comment' -or $t.Text.StartsWith('<#')) { continue }
        $i = $t.Extent.StartLineNumber - 1
        $c = $t.Extent.StartColumnNumber - 1
        if ($c -le 0) { continue }  # 独立成行的注释不动
        $code = $lines[$i].Substring(0, $c).TrimEnd()
        if (-not $code) { continue }
        $lines[$i] = $code + '  ' + $lines[$i].Substring($c)
    }

    $fmt = $lines -join "`r`n"

    # —— 安全闸：只有空白允许变
    if (($fmt -replace '\s', '') -cne ($Text -replace '\s', '')) {
        throw '结果与原文的非空白内容不一致，拒绝写盘（Invoke-Formatter 的行为不可信）'
    }
    $t = $null; $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($fmt, [ref]$t, [ref]$e)
    if ($e.Count) { throw "结果语法不合法：$($e[0].Message)" }

    @{ Text = $fmt; Warn = $warn }
}

$changed = 0
foreach ($f in $files) {
    $raw = [IO.File]::ReadAllText($f.FullName)
    $r = Format-Source -Text $raw
    $fmt = $r.Text
    if ($fmt -eq $raw) { Write-Host "[=] $($f.Name)" -ForegroundColor DarkGray }
    else {
        $changed++
        if ($Check) { Write-Host "[!] $($f.Name) 需要格式化" -ForegroundColor Yellow }
        else {
            [IO.File]::WriteAllText($f.FullName, $fmt, (New-Object Text.UTF8Encoding($true)))  # BOM + 已统一 CRLF
            Write-Host "[+] $($f.Name) 已格式化" -ForegroundColor Green
        }
    }
    foreach ($w in $r.Warn) { Write-Host "[!] $($f.Name)：$w" -ForegroundColor Yellow }
}

if ($Check -and $changed) { Write-Host "[X] 有 $changed 个文件不符合格式（跑不带 -Check 的即可修好）" -ForegroundColor Red; exit 1 }
Write-Host "[+] 完成：$($files.Count) 个文件，改动 $changed 个" -ForegroundColor Green
