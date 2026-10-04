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
    $p = (Get-Command adb -ErrorAction SilentlyContinue).Source
    if (-not $p) {
        foreach ($c in @("$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
                "$env:ProgramFiles\Android\platform-tools\adb.exe",
                'D:\Programs\android-platform-tools\adb.exe')) {
            if (Test-Path $c) { $p = $c; break }
        }
    }
    if (-not $p) { Write-Host '[X] 找不到 adb.exe，请用 -Adb <路径> 指定' -ForegroundColor Red; exit 1 }
    $p
}

function Ensure-Deps {
    param([string]$Cache)
    New-Item -ItemType Directory -Force $Cache | Out-Null
    foreach ($f in 'frida-inject', 'picohaxx.neo3.bin') {
        if (-not (Test-Path (Join-Path $Cache $f))) {
            Write-Host "[*] 缺少 $f，运行 get_deps.ps1 自动拉取..." -ForegroundColor Yellow
            & (Join-Path $PicoUtilsDir 'get_deps.ps1')
            break
        }
    }
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
        Write-Host "[*] adb connect $Target ..."
        & $Adb connect $Target | Out-Null; Start-Sleep -Seconds 2; $tried = $true
    }
    if ((Get-AdbDeviceState -Adb $Adb -Target $Target) -ne 'device' -and
        $Serial -and (Get-AdbDeviceState -Adb $Adb -Target $Serial) -eq 'device') {
        Write-Host '[*] 用 USB 打开 tcpip 5555 ...'
        & $Adb -s $Serial tcpip 5555 | Out-Null; Start-Sleep -Seconds 5
        & $Adb connect $Target | Out-Null; Start-Sleep -Seconds 2
    }
    $st = Get-AdbDeviceState -Adb $Adb -Target $Target
    if ($st -ne 'device') {
        if ($st) { Write-Host "[!] $Target 的状态是 $st，不可用" -ForegroundColor Yellow }
        if ($tried -and $wireless) { & $Adb disconnect $Target 2>$null | Out-Null }
        return $false
    }
    if ($IpFile -and $wireless) { Set-Content -Path $IpFile -Value ($Target -split ':')[0] -Encoding ascii }
    $true
}

function Get-UsbWirelessTarget {
    # USB 直连时问它 wlan0 的地址（无线目标能扛住 picohaxx 重启 adbd）
    param([string]$Adb, [string]$Serial, [string]$IpFile)
    $ip = (((& $Adb -s $Serial shell "ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+'") -join '') -replace 'inet', '').Trim()
    if ($ip -match '^\d+\.\d+\.\d+\.\d+$') {
        if ($IpFile) { Set-Content -Path $IpFile -Value $ip -Encoding ascii }
        return "$ip`:5555"
    }
    $null
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
    Write-Host "[*] 扫本机私有网段里开着 5555 的邻居（$($all.Count) 个候选）..."
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
    Write-Host "[X] 连不上 $t" -ForegroundColor Red
    $null
}

function Select-Headset {
    # 返回 @{ Target = <喂给 adb 的目标>; Serial = <USB 序列号或 ''> }；用户取消返回 $null
    # -Wireless：认下来是 USB 直连就优先换它的无线地址（picohaxx 会重启 adbd）
    param([string]$Adb, [string]$Serial, [string]$IpFile, [switch]$Wireless)

    if ($Serial) {
        if (Connect-AdbTarget -Adb $Adb -Target $Serial -IpFile $IpFile) { return @{ Target = $Serial; Serial = $Serial } }
        return $null
    }

    # --- 1) 本地已有设备 ---
    $devs = @(Get-AdbDevices -Adb $Adb)
    if ($devs.Count -gt 0) {
        Write-Host ''
        Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
        Write-Host ' 电脑上已经连着 adb 设备，先确认哪台是头显' -ForegroundColor Cyan
        Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
        for ($i = 0; $i -lt $devs.Count; $i++) { Write-Host ('   [{0}] {1}' -f ($i + 1), $devs[$i].Serial) -ForegroundColor Yellow }
        Write-Host ''
        Write-Host ' 是第 1 台 → 直接按回车' -ForegroundColor Cyan
        Write-Host ' 是别的   → 输入它前面的序号（例如 2）' -ForegroundColor Cyan
        Write-Host ' 不在上面 → 直接填头显的 IP，例如 192.168.137.108' -ForegroundColor Cyan
        Write-Host ' 不想继续 → 输入 q' -ForegroundColor Cyan
        while ($true) {
            $a = "$(Read-Host '请选择（回车=第 1 台 / 序号 / 头显 IP / q=退出）')".Trim()
            if ($a -match '^(q|quit|取消)$') { return $null }
            if ($a -match '^\d{1,3}(\.\d{1,3}){3}$') {
                $t = Select-ByIp -Adb $Adb -Text $a -IpFile $IpFile
                if (-not $t) { return $null }
                return @{ Target = $t; Serial = '' }
            }
            if (-not $a) { $n = 1 }
            elseif ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $devs.Count) { $n = [int]$a }
            else {
                Write-Host ("[X] 没看懂「{0}」。请输入 1-{1} 之间的序号，或直接填头显 IP（只要 IP 那一段），或 q" -f $a, $devs.Count) -ForegroundColor Red
                continue
            }
            $pick = $devs[$n - 1].Serial
            break
        }
        Write-Host "[+] 认定头显 = $pick" -ForegroundColor Green

        if ($pick -match ':') { return @{ Target = $pick; Serial = '' } }  # 已经是无线目标

        if ($Wireless) {
            # USB：优先换成无线
            $w = Get-UsbWirelessTarget -Adb $Adb -Serial $pick -IpFile $IpFile
            if ($w -and (Connect-AdbTarget -Adb $Adb -Target $w -Serial $pick -IpFile $IpFile)) {
                return @{ Target = $w; Serial = $pick }
            }
            if ((((& $Adb -s $pick shell id) -join '') -match 'uid=0')) {
                Write-Host '[!] 没有可用无线地址，但 adbd 已是 root —— 直接用 USB' -ForegroundColor Yellow
            }
            else {
                Write-Host '[!] 没有可用无线地址（Wi-Fi 没连？）—— 用 USB；提权时可能断线' -ForegroundColor Yellow
            }
        }
        return @{ Target = $pick; Serial = $pick }
    }

    # --- 2) 没有设备：让用户填头显 IPv4，或自动探测后确认 ---
    Write-Host ''
    Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ' 当前头显 adb 未连接，改用无线 adb 连它' -ForegroundColor Cyan
    Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ' 头显 IP 在哪看：在头显里打开 投屏 APP → 点「投至浏览器」，' -ForegroundColor Cyan
    Write-Host '                页面上会显示一串地址，形如 192.168.137.108' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ' 填的时候只填 IP 那一段（不带端口和路径）；' -ForegroundColor Cyan
    Write-Host ' 不想找？直接回车，我扫一遍网络去找（找到会再问你一次）' -ForegroundColor Cyan
    Write-Host ' 想放弃：输入 q' -ForegroundColor Cyan
    $ip = ''
    while (-not $ip) {
        $a = "$(Read-Host '头显 IP（回车=自动扫描 / q=退出）')".Trim()
        if ($a -match '^(q|quit|取消)$') { return $null }
        if (-not $a) { break }
        if ($a -match '^\d{1,3}(\.\d{1,3}){3}$') { $ip = $a; break }
        Write-Host ("[X] 没看懂「{0}」。只填 IP 那一段，比如 192.168.137.108" -f $a) -ForegroundColor Red
    }
    if ($ip) {
        $t = Select-ByIp -Adb $Adb -Text $ip -IpFile $IpFile
        if (-not $t) { return $null }
        return @{ Target = $t; Serial = '' }
    }

    $cand = @(Get-WirelessCandidates -IpFile $IpFile)
    if ($cand.Count -eq 0) { Write-Host '[X] 自动探测没找到候选（可以重跑并手动填 IP）' -ForegroundColor Red; return $null }
    # 探测只为确认「这台能不能当 adb 用」：验完立刻断开，选中哪台再正式连一次
    # （否则用户不认它 / 没选它时，刚连上的设备会留在 adb devices 里）
    $ok = @()
    foreach ($c in $cand) {
        if (Connect-AdbTarget -Adb $Adb -Target $c -IpFile '') {
            $ok += $c
            & $Adb disconnect $c 2>$null | Out-Null
        }
    }
    if ($ok.Count -eq 0) { Write-Host '[X] 候选里没有能连的（开着 5555 的不一定是头显）' -ForegroundColor Red; return $null }
    if ($ok.Count -eq 1) {
        Write-Host ''
        Write-Host (' 我在网络里扫描到一台设备：{0}' -f $ok[0]) -ForegroundColor Yellow
        while ($true) {
            $b = "$(Read-Host '它就是你的头显吗？（回车=是 / n=不是，退出）')".Trim()
            if ($b -match '^(n|no|否|q|quit|取消)$') { return $null }
            if ($b -match '^(y|yes|是)?$') { $chosen = $ok[0]; break }
            Write-Host '[X] 直接回车表示「是」，输入 n 表示「不是」' -ForegroundColor Red
        }
    }
    else {
        Write-Host ''
        Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
        Write-Host ' 我在网络里扫描到下面几台设备，哪台是头显？' -ForegroundColor Cyan
        Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
        for ($i = 0; $i -lt $ok.Count; $i++) { Write-Host ('   [{0}] {1}' -f ($i + 1), $ok[$i]) -ForegroundColor Yellow }
        Write-Host ''
        Write-Host ' 是第 1 台 → 直接按回车；是别的 → 输入它前面的序号；不想继续 → 输入 q' -ForegroundColor Cyan
        while ($true) {
            $b = "$(Read-Host '请选择（回车=第 1 台 / 序号 / q=退出）')".Trim()
            if ($b -match '^(q|quit|取消)$') { return $null }
            if (-not $b) { $chosen = $ok[0]; break }
            if ($b -match '^\d+$' -and [int]$b -ge 1 -and [int]$b -le $ok.Count) { $chosen = $ok[[int]$b - 1]; break }
            Write-Host ("[X] 没看懂「{0}」。请输入 1-{1} 之间的序号，或 q" -f $b, $ok.Count) -ForegroundColor Red
        }
    }
    if (-not (Connect-AdbTarget -Adb $Adb -Target $chosen -IpFile $IpFile)) {
        Write-Host "[X] 连不上 $chosen" -ForegroundColor Red
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
        Write-Host '[i] 这次 adb 不是 root，Termux 侧没法自动装。头显里打开 Termux，初始化一次：'
        Write-Host '    termux-setup-storage               # 授权存储，弹窗点允许'
        Write-Host "    sh $Sd/install.sh                  # 把 kit 装进 ~/pico_touch，可重复跑"
        Write-Host "以后每次开机："
        Write-Host "    $Launch"
        return
    }

    if ((((& $Adb -s $Target shell "[ -d $Prefix/home ] && echo yes") -join '').Trim()) -ne 'yes') {
        Write-Host '[i] 头显上没装 Termux：跳过安装头显侧 Termux 本地 patch 脚本'
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
        if (-not (Test-Path $f.Src)) { Write-Host "[i] 缺 $($f.Src)，跳过 Termux 侧安装" -ForegroundColor Yellow; return }
        & $Adb -s $Target push $f.Src "$Dh/$($f.Name)" | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "[!] 推 $($f.Name) 到头显 Termux 失败" -ForegroundColor Yellow; return }
    }
    # 短命令：$PREFIX/bin/$Launch -> ~/pico_touch/dptouch.sh（symlink）。
    # ★ root 建出来的条目必须带上 app 的 SELinux 类别，否则 app 连 stat 都 Permission denied（实测踩过：
    #   少了 s0:c126,c256,c512,c768 ⇒ install.sh 报 cp cannot stat）。用 --reference 抄一份 app 自己的类别。
    & $Adb -s $Target shell "chown -R $uid`:$uid $Dh; chmod 755 $Dh $Dh/*; rm -f $Prefix/usr/bin/$Launch; ln -sf $Dh/dptouch.sh $Prefix/usr/bin/$Launch; chown -h $uid`:$uid $Prefix/usr/bin/$Launch; chcon -h --reference=$Prefix/home $Prefix/usr/bin/$Launch; restorecon -R $Dh" | Out-Null
    Write-Host "[+] Termux 侧已装好：开 Termux 敲 $Launch 就能跑" -ForegroundColor Green
}
