<#
_utils.ps1 —— Windows 侧脚本共用的部分（脚本里用 . "$PSScriptRoot\_utils.ps1" 点源进来）
#>

Set-StrictMode -Version Latest  # 点源时会把调用方也一起罩上
$PicoUtilsDir = $PSScriptRoot

function Get-RepoPaths {
    param([string]$ScriptDir)
    $win = Split-Path -Parent $ScriptDir
    $src = Split-Path -Parent $win
    @{
        WinDir = $win  # src/windows（wrapper 所在）
        Cache  = Join-Path $win 'temp'  # src/windows/temp（运行期缓存，整目录被 .gitignore 忽略）
        Share  = Join-Path $src 'shared'
        Termux = Join-Path $src 'termux'
    }
}

function Get-AdbPath {
    param([string]$Adb)
    if ($Adb) {
        if (Test-Path $Adb) { return (Resolve-Path $Adb).Path }
        Write-Host "[X] 指定的 adb 不存在：$Adb" -ForegroundColor Red; exit 1
    }
    # Get-Command 没找到时是 $null：StrictMode 下不能直接取 .Source
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    $p = if ($cmd) { $cmd.Source } else { $null }
    if (-not $p) {
        foreach ($c in @("$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
                "$env:ProgramFiles\Android\platform-tools\adb.exe",
                'D:\Programs\android-platform-tools\adb.exe')) {
            if (Test-Path $c) { $p = $c; break }
        }
    }
    if ($p) { return $p }
    # 哪里都没有：让 get_deps.ps1 按需拉一份到 temp/platform-tools（md5 逐字节校验，见该脚本）
    $cached = Join-Path (Get-RepoPaths -ScriptDir $PicoUtilsDir).Cache 'platform-tools\adb.exe'
    if (-not (Test-Path $cached)) {
        Write-Host '[i] 本机未安装 adb，正在下载 platform-tools。'
        & (Join-Path $PicoUtilsDir 'get_deps.ps1') -PlatformTools
    }
    if (-not (Test-Path $cached)) { Write-Host '[X] adb 下载失败，请手动安装 platform-tools，或用 -Adb <路径> 指定。' -ForegroundColor Red; exit 1 }
    $cached
}

function Ensure-Deps {
    param([string]$Cache)
    New-Item -ItemType Directory -Force $Cache | Out-Null
    foreach ($f in 'frida-inject', 'picohaxx.neo3.bin') {
        if (-not (Test-Path (Join-Path $Cache $f))) {
            Write-Host "[i] 缺少 $f，正在下载依赖。"
            & (Join-Path $PicoUtilsDir 'get_deps.ps1')
            break
        }
    }
}

function Get-RemoteFile {
    # 单 URL 下载到 $Out；curl.exe（Win10 自带）优先，回退 Invoke-WebRequest；返回 $true/$false
    # 多 URL 的调用方（get_deps.ps1）自己套一层循环
    param([string]$Url, [string]$Out)
    Write-Host "[i] 正在下载 $(Split-Path $Out -Leaf)。"
    try {
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -fL --retry 3 --connect-timeout 15 -o $Out $Url
            if ($LASTEXITCODE -eq 0 -and (Test-Path $Out)) { return $true }
        }
        else {
            $ProgressPreference = 'SilentlyContinue'  # PS 5.1 的进度条会让大文件慢一个数量级
            Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing
            if (Test-Path $Out) { return $true }
        }
    }
    catch { Write-Host "[!] 下载失败：$($_.Exception.Message)" -ForegroundColor Yellow }
    return $false
}

function Test-TcpOpen {
    param([string]$Server, [int]$Port, [int]$TimeoutMs = 400)
    $c = New-Object Net.Sockets.TcpClient
    try { return $c.ConnectAsync($Server, $Port).Wait($TimeoutMs) -and $c.Connected }
    catch { return $false } finally { $c.Dispose() }
}

function Get-AdbDevices {
    # adb 上已知的设备；-State 传 '' 表示不过滤状态
    param([string]$Adb, [string]$State = 'device')
    foreach ($ln in (& $Adb devices)) {
        if ($ln -match '^\s*(\S+)\s+(device|offline|unauthorized|bootloader|recovery|sideload)\s*$') {
            if (-not $State -or $Matches[2] -eq $State) { @{ Serial = $Matches[1]; State = $Matches[2] } }
        }
    }
}

function Get-AdbDeviceState {
    param([string]$Adb, [string]$Target)
    foreach ($d in @(Get-AdbDevices -Adb $Adb -State '')) { if ($d.Serial -eq $Target) { return $d.State } }
    ''
}

function Connect-AdbTarget {
    # 无线目标失败要 disconnect 收回，别留 offline 残条
    param([string]$Adb, [string]$Target, [string]$Serial, [string]$IpFile)
    $wireless = $Target -match '^\d+\.\d+\.\d+\.\d+:\d+$'
    $tried = $false
    if ((Get-AdbDeviceState -Adb $Adb -Target $Target) -ne 'device') {
        Write-Host "[i] 正在连接 $Target。"
        & $Adb connect $Target | Out-Null; Start-Sleep -Seconds 2; $tried = $true
    }
    if ((Get-AdbDeviceState -Adb $Adb -Target $Target) -ne 'device' -and
        $Serial -and (Get-AdbDeviceState -Adb $Adb -Target $Serial) -eq 'device') {
        Write-Host '[i] 正在通过 USB 打开 TCP 端口 5555。'
        & $Adb -s $Serial tcpip 5555 | Out-Null; Start-Sleep -Seconds 5
        & $Adb connect $Target | Out-Null; Start-Sleep -Seconds 2
    }
    $st = Get-AdbDeviceState -Adb $Adb -Target $Target
    if ($st -ne 'device') {
        if ($st) { Write-Host "[!] $Target 的状态是 $st，设备不可用。" -ForegroundColor Yellow }
        if ($tried -and $wireless) { & $Adb disconnect $Target 2>$null | Out-Null }
        return $false
    }
    if ($IpFile -and $wireless) { Set-Content -Path $IpFile -Value ($Target -split ':')[0] -Encoding ascii }
    $true
}

function Get-WirelessCandidates {
    # 自动探测：缓存里那台 + 本机私有网段里 5555 开着的邻居
    # 只认 192.168/10./172.16-31 —— 把 198.18/15（Clash TUN 之类）和 169.254 直接排除
    param([string]$IpFile)
    $cand = @()
    if ($IpFile -and (Test-Path $IpFile)) {
        $ip = (Get-Content $IpFile -Raw).Trim()
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { $cand += "$ip`:5555" }
    }
    $subnets = @()
    foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($a.IPAddress -match '^(192\.168|10|172\.(1[6-9]|2[0-9]|3[01]))\.' ) {
            $subnets += (($a.IPAddress -split '\.')[0..2] -join '.')
        }
    }
    $seen = @{}
    $all = @()
    foreach ($l in (arp -a)) {
        if ($l -notmatch '^\s*(\d+\.\d+\.\d+\.\d+)\s') { continue }
        $ip = $Matches[1]
        $prefix = ($ip -split '\.')[0..2] -join '.'
        if ($seen[$ip] -or ($subnets -notcontains $prefix)) { continue }
        $seen[$ip] = $true
        $all += $ip
    }
    Write-Host "[i] 正在扫描网络，候选设备 $($all.Count) 台。"
    foreach ($ip in $all) {
        if (Test-TcpOpen -Server $ip -Port 5555 -TimeoutMs 300) { $cand += "$ip`:5555" }
    }
    @($cand | Select-Object -Unique)
}

function Select-ByIp {
    # 调用方已校验是纯 IPv4；adb 端口固定 5555
    param([string]$Adb, [string]$Text, [string]$IpFile)
    $t = "$($Text.Trim()):5555"
    if (Connect-AdbTarget -Adb $Adb -Target $t -IpFile $IpFile) { return $t }
    Write-Host "[X] 无法连接 $t。" -ForegroundColor Red
    $null
}

function Select-Headset {
    # 返回 @{ Target = <喂给 adb 的目标>; Serial = <USB 序列号或 ''> }；用户取消返回 $null
    # USB 直连就用 USB（无线调试要在头显里另外开，不在 USB 下记 IP）；没连接才走无线
    param([string]$Adb, [string]$Serial, [string]$IpFile)

    if ($Serial) {
        if (Connect-AdbTarget -Adb $Adb -Target $Serial -IpFile $IpFile) { return @{ Target = $Serial; Serial = $Serial } }
        return $null
    }

    # --- 1) 本地已有设备 ---
    $devs = @(Get-AdbDevices -Adb $Adb)
    if ($devs.Count -gt 0) {
        Write-Host ''
        Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
        Write-Host ' 电脑上已有 adb 设备，请选择头显。' -ForegroundColor Cyan
        Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
        for ($i = 0; $i -lt $devs.Count; $i++) { Write-Host ('   [{0}] {1}' -f ($i + 1), $devs[$i].Serial) -ForegroundColor Yellow }
        Write-Host ''
        Write-Host ' 第 1 台：按回车。' -ForegroundColor Cyan
        Write-Host ' 其他设备：输入序号，例如 2。' -ForegroundColor Cyan
        Write-Host ' 不在列表中：输入头显 IP，例如 192.168.137.108。' -ForegroundColor Cyan
        Write-Host ' 退出：输入 q。' -ForegroundColor Cyan
        while ($true) {
            $a = "$(Read-Host '请选择：回车=第 1 台，序号，头显 IP，q=退出')".Trim()
            if ($a -match '^(q|quit|取消)$') { return $null }
            if ($a -match '^\d{1,3}(\.\d{1,3}){3}$') {
                $t = Select-ByIp -Adb $Adb -Text $a -IpFile $IpFile
                if (-not $t) { return $null }
                return @{ Target = $t; Serial = '' }
            }
            if (-not $a) { $n = 1 }
            elseif ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $devs.Count) { $n = [int]$a }
            else {
                Write-Host ("[X] 输入无效：{0}，请输入 1-{1} 之间的序号，或输入头显 IP，或输入 q。" -f $a, $devs.Count) -ForegroundColor Red
                continue
            }
            $pick = $devs[$n - 1].Serial
            break
        }
        Write-Host "[+] 已选择头显：$pick" -ForegroundColor Green

        if ($pick -match ':') { return @{ Target = $pick; Serial = '' } }  # 已经是无线目标

        return @{ Target = $pick; Serial = $pick }
    }

    # --- 2) 没有设备：让用户填头显 IPv4，或自动探测后确认 ---
    Write-Host ''
    Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ' 头显的 adb 未连接，请改用无线 adb。' -ForegroundColor Cyan
    Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ' 查看头显 IP：在头显中打开投屏 APP，点「投至浏览器」。' -ForegroundColor Cyan
    Write-Host ' 页面会显示一个地址，例如 192.168.137.108。' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ' 只输入 IP 地址，不要输入端口和路径。' -ForegroundColor Cyan
    Write-Host ' 不知道 IP：按回车，工具会扫描网络，随后再次询问。' -ForegroundColor Cyan
    Write-Host ' 退出：输入 q。' -ForegroundColor Cyan
    $ip = ''
    while (-not $ip) {
        $a = "$(Read-Host '头显 IP：回车=自动扫描，q=退出')".Trim()
        if ($a -match '^(q|quit|取消)$') { return $null }
        if (-not $a) { break }
        if ($a -match '^\d{1,3}(\.\d{1,3}){3}$') { $ip = $a; break }
        Write-Host ("[X] 输入无效：{0}，请只输入 IP 地址，例如 192.168.137.108。" -f $a) -ForegroundColor Red
    }
    if ($ip) {
        $t = Select-ByIp -Adb $Adb -Text $ip -IpFile $IpFile
        if (-not $t) { return $null }
        return @{ Target = $t; Serial = '' }
    }

    $cand = @(Get-WirelessCandidates -IpFile $IpFile)
    if ($cand.Count -eq 0) { Write-Host '[X] 自动扫描未找到候选设备，请重新运行，然后手动输入 IP。' -ForegroundColor Red; return $null }
    # 探测只为确认「这台能不能当 adb 用」：验完立刻断开，选中哪台再正式连一次
    # （否则用户不认它 / 没选它时，刚连上的设备会留在 adb devices 里）
    $ok = @()
    foreach ($c in $cand) {
        if (Connect-AdbTarget -Adb $Adb -Target $c -IpFile '') {
            $ok += $c
            & $Adb disconnect $c 2>$null | Out-Null
        }
    }
    if ($ok.Count -eq 0) { Write-Host '[X] 候选设备均无法连接，开放 5555 端口的设备不一定是头显。' -ForegroundColor Red; return $null }
    if ($ok.Count -eq 1) {
        Write-Host ''
        Write-Host (' 网络扫描到 1 台设备：{0}。' -f $ok[0]) -ForegroundColor Yellow
        while ($true) {
            $b = "$(Read-Host '这是头显吗？回车=是，n=不是，q=退出')".Trim()
            if ($b -match '^(n|no|否|q|quit|取消)$') { return $null }
            if ($b -match '^(y|yes|是)?$') { $chosen = $ok[0]; break }
            Write-Host '[!] 输入无效，按回车表示「是」，输入 n 表示「不是」。' -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ''
        Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
        Write-Host ' 网络扫描到多台设备，请选择头显。' -ForegroundColor Cyan
        Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
        for ($i = 0; $i -lt $ok.Count; $i++) { Write-Host ('   [{0}] {1}' -f ($i + 1), $ok[$i]) -ForegroundColor Yellow }
        Write-Host ''
        Write-Host ' 第 1 台：按回车。其他设备：输入序号。退出：输入 q。' -ForegroundColor Cyan
        while ($true) {
            $b = "$(Read-Host '请选择：回车=第 1 台，序号，q=退出')".Trim()
            if ($b -match '^(q|quit|取消)$') { return $null }
            if (-not $b) { $chosen = $ok[0]; break }
            if ($b -match '^\d+$' -and [int]$b -ge 1 -and [int]$b -le $ok.Count) { $chosen = $ok[[int]$b - 1]; break }
            Write-Host ("[X] 输入无效：{0}，请输入 1-{1} 之间的序号，或输入 q。" -f $b, $ok.Count) -ForegroundColor Red
        }
    }
    if (-not (Connect-AdbTarget -Adb $Adb -Target $chosen -IpFile $IpFile)) {
        Write-Host "[X] 无法连接 $chosen。" -ForegroundColor Red
        return $null
    }
    return @{ Target = $chosen; Serial = '' }
}

function Push-TermuxKit {
    # 只有 adbd 已是 root 才装得进 Termux 家目录；装不了就把用户接下来要做什么打出来
    # -Prefix 只为测试/非标准安装，默认即 Termux 标准路径
    param(
        [string]$Adb, [string]$Target, [hashtable]$Paths,
        [string]$Launch = 'dptouch', [string]$Prefix = '/data/data/com.termux/files'
    )
    $Sd = '/sdcard/Download/pico_touch'  # 中转目录，与 push.ps1 / install.sh 保持一致

    if ((((& $Adb -s $Target shell id) -join '') -notmatch 'uid=0')) {
        Write-Host '[i] 当前 adb 不是 root，无法自动安装 Termux 侧组件。请在头显中打开 Termux，然后初始化一次：'
        Write-Host '    termux-setup-storage               # 授权存储。在弹窗中允许。'
        Write-Host "    sh $Sd/install.sh                  # 安装 kit 到 ~/pico_touch。可重复运行。"
        Write-Host "以后每次开机，运行："
        Write-Host "    $Launch"
        return
    }

    if ((((& $Adb -s $Target shell "[ -d $Prefix/home ] && echo yes") -join '').Trim()) -ne 'yes') {
        Write-Host '[i] 头显未安装 Termux，跳过 Termux 侧安装。'
        return
    }

    $uid = (((& $Adb -s $Target shell "stat -c %u $Prefix/home") -join '')).Trim()
    $Dh = "$Prefix/home/pico_touch"
    $files = @(
        @{ Src = Join-Path $Paths.Termux 'dptouch.sh'; Name = 'dptouch.sh' }
        @{ Src = Join-Path $Paths.Termux 'install.sh'; Name = 'install.sh' }
        @{ Src = Join-Path $Paths.Share 'hook.js'; Name = 'hook.js' }
        @{ Src = Join-Path $Paths.Share 'start_touch.sh'; Name = 'start_touch.sh' }
        @{ Src = Join-Path $Paths.Cache 'picohaxx.neo3.bin'; Name = 'picohaxx.neo3.bin' }
        @{ Src = Join-Path $Paths.Cache 'frida-inject'; Name = 'frida-inject' }
    )
    & $Adb -s $Target shell "mkdir -p $Dh" | Out-Null
    foreach ($f in $files) {
        if (-not (Test-Path $f.Src)) { Write-Host "[i] 缺少 $($f.Src)，跳过 Termux 侧安装。" -ForegroundColor Yellow; return }
        & $Adb -s $Target push $f.Src "$Dh/$($f.Name)" | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "[!] 推送 $($f.Name) 到 Termux 失败。" -ForegroundColor Yellow; return }
    }
    # 短命令：$PREFIX/bin/$Launch -> ~/pico_touch/dptouch.sh（symlink）。
    # ★ root 建出来的条目必须抄上 app 的 SELinux 类别：默认只有 u:object_r:app_data_file:s0，
    #   少了 s0:c126,c256,c512,c768 ⇒ app 连 stat 都 Permission denied（实测踩过两次：
    #   install.sh 报 cp cannot stat / 敲 dptouch 直接 Permission denied）。
    #   Android 的 toybox chcon 没有 --reference，只能显式喂上下文（取自同样是 app 建的 $Prefix/home）。
    $ctx = (((& $Adb -s $Target shell "ls -Zd $Prefix/home") -join '').Split(' ')[0]).Trim()
    $mk = "chown -R $uid`:$uid $Dh; chmod 755 $Dh $Dh/*; rm -f $Prefix/usr/bin/$Launch; " +
    "ln -sf $Dh/dptouch.sh $Prefix/usr/bin/$Launch; chown -h $uid`:$uid $Prefix/usr/bin/$Launch; " +
    "chcon -h $ctx $Prefix/usr/bin/$Launch; restorecon -R $Dh"
    & $Adb -s $Target shell $mk | Out-Null
    $entry = ((& $Adb -s $Target shell "ls -lZ $Prefix/usr/bin/$Launch") -join '').Trim()
    if ($entry -notmatch [regex]::Escape($ctx)) {
        Write-Host "[X] $Prefix/usr/bin/$Launch 的 SELinux 上下文不正确。应用会收到 Permission denied：" -ForegroundColor Red
        Write-Host "    $entry"
        Write-Host "    备选方案：在头显中运行 sh $Sd/install.sh，由应用创建这个 symlink，上下文正确。"
    }
    else {
        Write-Host "[+] Termux 侧安装完成，打开 Termux 运行 $Launch 即可。" -ForegroundColor Green
    }
}
