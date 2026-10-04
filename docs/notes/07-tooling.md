# 07 · 工具链与踩坑合集

## 已安装

| 工具                | 路径                                                                          | 用途                                                |
| ------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------- |
| **IDA Pro 9.4 sp1** | `D:\Program Files\IDA Professional 9.4\`                                      | 反编译（PE x64 / ELF arm64），经 `ida-mcp` 插件可用 |
| Ghidra 12.1.4       | `D:\Programs\ghidra_12.1.4_PUBLIC\support\analyzeHeadless.bat`                | 备用反编译                                          |
| JDK (GraalVM 25)    | `D:\Programs\GraalVM\...`                                                     | Ghidra / jadx 运行                                  |
| jadx 1.5.6          | winget `Skylot.jadx`，CLI 用 `jadx-gui-1.5.6-all.jar` 里的 `jadx.cli.JadxCLI` | 反编译 DEX                                          |
| innoextract 1.9     | `%LOCALAPPDATA%\Microsoft\WinGet\Links\innoextract.exe`                       | 拆 Inno Setup 安装包                                |
| x64dbg              | winget `x64dbg.x64dbg`                                                        | 动态调试                                            |
| LLVM lldb-dap       | `D:\Program Files\LLVM\bin\lldb-dap.exe`                                      | 可作为 `xd://debug` 后端 attach 到 vrserver         |
| Wireshark / USBPcap | `D:\Program Files\Wireshark`、`D:\Program Files\USBPcap\USBPcapCMD.exe`       | 抓包（HID 用 hidapi 直读更简单）                    |
| adb                 | `D:\Programs\android-platform-tools\adb.exe`                                  | 头显 `adb connect <头显IP>:5555`                    |
| dumpbin             | VS BuildTools `VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe`                   | 导入表                                              |
| 7z                  | `%LOCALAPPDATA%\Microsoft\WindowsApps\7z.exe`                                 | 解包（NSIS 载荷在 `$PLUGINSDIR/app-64.7z`）         |
| uv / Python         | `uv run --quiet python ...`                                                   | 全部脚本                                            |

## IDA (ida-mcp) 用法要点

- `ida_open_database(<path>)` → `ida_execute_python(code)`；`db` 与 `ida_domain` 全局可用
- 首次 `decompile` 可能报 `Autoanalysis was cancelled before completion`，**重试即可**
- 打开 `.orig` 后缀会失败 ⇒ 先复制成 `.dll`
- 常用：`db.functions.get_at(ea)` / `get_pseudocode(ea)`、`db.strings.get_all()`、`db.xrefs.to_ea(ea)`、
  `db.functions.get_instructions(func)`（要传函数对象，不能传地址）
- 取指令文本用 `idc.GetDisasm(ea)` + `idc.get_item_size(ea)` 逐条走（IDA 9.4 没有 `idc.find_binary`）
- 别名地址：`db.imports.get_all_imports()` → `.address` / `.name`；`StringItem.address`（不是 `.ea`）

## Ghidra headless 配方

```bash
G="D:/Programs/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat"
# 导入 + 分析 + 跑脚本
"$G" <项目目录> <项目名> -import <目标文件> \
     -scriptPath <脚本目录> -postScript <脚本>.java -analysisTimeoutPerFile 2400
# 复用已分析的程序（快）
"$G" <项目目录> <项目名> -process driver_pico.dll -noanalysis \
     -scriptPath <脚本目录> -postScript <脚本>.java
```

已有脚本（`artifacts/gh-scripts/`）：`FindRefs.java`（**列任意地址的全部引用并反编译引用者**，最准）、
`DumpAsm.java`（指令级反汇编，定位补丁点必备）。其余一次性查找 / dumper 脚本未随仓库发布。

不依赖 Ghidra 的快速扫描：`artifacts/refscan.py <VA>...`（扫 `.text` 的 RIP 相对寻址，2 秒出结果，
但只覆盖部分编码形式）。

## 脚本目录

分析脚本随笔记放在 `artifacts/`（本机临时工作目录已省略）。脚本里的驱动 DLL 路径需按本机安装位置改。

### `artifacts/` 文件

| 文件                              | 说明                                             |
| --------------------------------- | ------------------------------------------------ |
| `hidcap.py`                       | HID 采集                                         |
| `btour.py` / `banalyze.py`        | 按键巡回采集与分析                               |
| `touchtour.py` / `touranalyze.py` | 触摸巡回（HID + OpenVR 同时）                    |
| `refscan.py`                      | 不依赖 Ghidra 的 RIP 相对引用快速扫描            |
| `memread.py` / `readhandles.py`   | 从运行中的 `vrserver.exe` 实读驱动对象/句柄      |
| `ovrread.py`                      | OpenVR 状态读取                                  |
| `msgtypes.py`                     | 曾命名为 `types.py`，改名以免遮蔽标准库          |
| `vrchat_touch_bindings.txt`       | VRChat 的 SteamVR 绑定摘录                       |
| `gh-scripts/`                     | Ghidra 的 `.java` 脚本（`FindRefs` / `DumpAsm`） |

> 其余一次性统计/探测脚本，以及原始抓包日志（`btour.log` / `tour.log` / `act2.log` / `baseline.log` /
> `watch*.log`）、`openvr.h`、`driver_orig.dll`（厂商驱动副本）、`extracted/`、`logs/`，因体积/版权/价值原因
> 不随仓库发布。

---

# 踩坑合集

## Windows / PowerShell

1. **`.ps1` 含中文必须带 UTF-8 BOM**（`utf-8-sig`），否则 PowerShell 5.1 按 GBK 读会把字符拆坏
   —— 症状是莫名其妙的 `数组索引表达式丢失或无效`。**本目录所有 `.ps1` 都已带 BOM。**
2. **`-notmatch` 作用在数组上永远为真**（返回「不匹配的元素数组」）。要先 `-join` 成字符串。
   例：`(adb devices) -notmatch $serial` 恒真。
3. `D:\Program Files` 写入被 ACL 拒绝 ⇒ 改文件必须 UAC 提权（`Start-Process -Verb RunAs`）
4. **改 `driver_pico.dll` 前必须完全退出 SteamVR + Business StreamingDP**，
   否则文件被 `vrserver.exe` 的 image section 占用，**写入静默失败**（不报错！）
5. `Start-Process -Verb RunAs` 的 stdout 拿不到 ⇒ 让被提权的脚本自己写日志文件

## Python / uv

6. **uv 默认解析到 Python 3.14，frida 16.x 的 `_frida.pyd` 在 3.14 上直接访问违例**
   （`exit=5` = `0xC0000005`，无任何输出）。要么固定 `--python 3.12`，要么确保兼容。
7. **工作目录/脚本名不能遮蔽标准库**：
   - 目录叫 `frida` → `import frida` 命中同名目录
   - 脚本叫 `enum.py` → `re` → `import enum` 命中它 ⇒ `import frida` 神秘失败
   - 同理 `types.py` → 已改名 `msgtypes.py`
8. `uv run --quiet` 会吞掉 uv 自己的报错；脚本异常时用 `-u` + `2>&1` 并写文件排查

## Frida

9. **frida-server 17.22.0 在本机启动即崩**：
   `linux-host-session.vala:1164: frida_sigchain_compat_validate_signal: assertion failed`
   ⇒ **用 16.7.19**（16.6.6 / 15.2.2 也正常）
10. PC 侧 Python 包版本必须与设备端 frida-server 对齐（`--with frida==16.7.19`）
11. `adb shell "... &"` 起的后台进程会被回收 ⇒ 用 `nohup ... </dev/null &`
12. **`pkill -f <名字>` 会把执行它的 shell 自己也匹配杀掉**（命令行里含该字符串）⇒ 用 `pkill -x`
13. `frida-inject -e` = eternalize（注入后脚本留下、进程退出）—— 设备端一次性注入的正确姿势
14. 判定 agent 是否在目标进程：`grep frida-agent /proc/<pid>/maps`

## adb / 设备

15. 多设备时必须 `-s`；无线 adb 目标形如 `IP:5555`
16. 头显 IP 是 DHCP 的，会变 ⇒ 脚本用「缓存 IP → ARP 表探测 `:5555`」自动找
17. `adb tcpip 5555` 只设 `service.adb.tcp.port`（易失）；要持久得 `setprop persist.adb.tcp.port 5555`
18. **`adb shell` 退出后子进程被杀** ⇒ 设备端常驻要 `nohup`/`setsid`
19. 设备端 `/proc/<pid>/maps` 是确认「谁加载了什么库 / 谁打开了什么 fd」的最可靠手段
20. **在设备上跑 adb 时，`adb devices` 会把本机 `localhost:5555` 也识别成 `emulator-5554`**
    （adb 固定扫 5554-5585，console 5554 / adb 5555 成对）⇒ 同一台设备出现两个 serial
    ⇒ 必须 `-s` 或 `export ANDROID_SERIAL=127.0.0.1:5555`，否则 `more than one device/emulator`
21. 判定设备本机能否连自己的 adbd：`curl -s -m3 -o/dev/null http://127.0.0.1:5555/`
    —— `rc=7` 是拒绝，`rc=52/56` 是连上但非 HTTP（设备自带 `curl`，没有 `nc`）
22. **`adbd` 重启会丢 TCP 监听**：它读的是易失的 `service.adb.tcp.port`，
    而 `persist.adb.tcp.port` 只在**开机**时被 init 用来初始化 `service.*`
    ⇒ picohaxx 的 `kill_adbd()` 之后无线 adb 就没了。
    **跑 picohaxx 前先 `adb tcpip 5555`**（设的正是 `service.*`）。
23. **adbd 重启后旧设备条目会变 `offline`**，直接 `adb connect` 不刷新它
    ⇒ 必须先 `adb disconnect` 再 `adb connect`，并重试几次
24. **`picohaxx -- <cmd>` 在「原本没 root」时不会执行 `<cmd>`**：
    `patch_ADBD()` 末尾是 `kill_adbd()` = `system("pkill -9 adbd"); exit(21);`
    ⇒ 必须分两步：先 `picohaxx -noftpd` 提权，再 `picohaxx -noftpd -- <cmd>`（第二次已是 root，跳过补丁）
25. **app 域（Termux）读不到 `settings`**：调 `settings get system confirm_smartisan_version`
    被 SELinux 拦，报 `Failure calling service settings: Failed transaction`
    ⇒ picohaxx 的 fallback（读 `ro.pvr.internal.version`）在**编译版实测返回空串**（源码里那个 `_`→`-` 替换没生效）
    ⇒ 用 PATH shim（假 `settings` 直接吐版本串）绕过
26. **app 域能跑 picohaxx 的完整利用链**（实测）：能开 `/dev/kgsl-3d0`、fork 80 进程、
    mmap 2560 GB PTE、赢竞态 ⇒ 提权不需要 adb

## Ghidra / IDA

20. Ghidra 12 的 `.py` 脚本默认走 PyGhidra（未启用会报错）⇒ 一律写 `.java`
21. `import ghidra.program.model.data.Data` 是错的 ⇒ 应为 `ghidra.program.model.listing.Data`
22. `analyzeHeadless` 的项目目录**必须已存在**
23. `dumpbin /dependents` 只能看静态导入；`winusb` / 动态 `LoadLibrary` 不会出现

## OpenVR / 抓包

24. **观测 OpenVR 状态必须用 `VRApplication_Scene(2)`**：
    `Background(3)` / `Overlay(4)` 下 `GetControllerState` 恒返回 false
25. 不能用 `GetControllerState` 的 T 位当端到端证据（它跟随模拟量，见 `04`）
26. HID 输入报文会**广播**给所有已打开的句柄 ⇒ 驱动在跑也能同时抓包
27. MSYS bash 里 `while read` / herestring 容易出 `os error 87`，用简单命令
28. 本机直连 reddit / r.jina.ai 不通；`raw.githubusercontent.com` 时通时不通，`ghfast.top` 镜像可用
