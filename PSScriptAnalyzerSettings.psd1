@{
    # PSScriptAnalyzer 规则裁剪：这里列的都是本仓库「有意为之」的写法，其余规则保持开启
    # 跑法（改动 .ps1 后跑一遍，应无输出）：
    #   Invoke-ScriptAnalyzer -Path src/windows/src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
    ExcludeRules = @(
        # CLI 工具脚本，输出就是打给人看的（还要上色）——Write-Host 是刻意的选择
        'PSAvoidUsingWriteHost'
        # MD5 用于跟固定上游产物 / 已知驱动构建逐字节对齐，不是安全边界（见 AGENTS.md 硬门槛）
        'PSAvoidUsingBrokenHashAlgorithms'
        # 下面是内部函数（不是导出 cmdlet），复数名/Ensure- 比硬套 Get-/Install- 更贴切：
        # Get-RepoPaths / Get-AdbDevices / Get-WirelessCandidates / Ensure-Deps
        'PSUseSingularNouns'
        'PSUseApprovedVerbs'
    )
}
