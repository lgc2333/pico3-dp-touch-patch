# AGENTS.md

PICO Neo 3 Pro（企业版）在「Business Streaming DP 直连」下补回手柄电容触摸：头显端 Frida hook + PC 驱动 14 字节补丁。面向用户的说明在 `README.md`；完整逆向记录在 `docs/`。

## Structure

```text
src/
  windows/            PC（Windows）侧：wrapper 在外面，实现和缓存都在里面
    pico_touch.bat / patch_driver.bat / push.bat   双击即用的入口，只负责调 src/ 下的脚本
    src/              实现脚本（PowerShell 5.1+）
      _utils.ps1      公用：仓库路径、找 adb.exe、拉依赖、认/连头显、装 Termux kit（被下面几个点源）
      pico_touch.ps1  一键：找头显 → 无线 adb → picohaxx 提权 → 推送 → 设备端注入
      push.ps1        只推文件：设备端三件套 + Termux 要用的（不提权、不注入）
      patch_driver.ps1 驱动 14 字节补丁（自己定位 DLL：注册表/OpenVR/问用户；未提权自己弹 UAC）
      get_deps.ps1    从上游拉 frida-inject / picohaxx 并打 Neo 3 补丁
    temp/             运行期缓存：依赖二进制、`.headset_ip`（整目录被 .gitignore 忽略）
  termux/             头显端（Termux）的 kit：装进 ~/pico_touch 即用，运行期不碰 /sdcard
    get_deps.sh       拉依赖二进制到 ./temp/（Termux 里缺 curl/xz 会自己 pkg install）
    termux_touch.sh   每次开机跑：借本机 adbd 跑 picohaxx 提权 + 注入（幂等）；日志写 ./logs/
    install.sh        兜底安装（PC 侧 adbd 非 root 时）：/sdcard 的 kit → ~/pico_touch，并装好短命令
    launch.sh         被装成 $PREFIX/bin/dptouch：头显里敲 `dptouch` == 跑 termux_touch.sh（VR 里少打字）
  shared/             两端共用的设备端脚本
    hook.js           Frida 脚本：键值字 bit1/3/5/7 ← controller_data_t +32/+36/+40/+44
    start_touch.sh    幂等启动（检查 /proc/<pid>/maps 是否已有 frida-agent）
scripts/              仓库工具（不被脚本运行期依赖）
  format_ps.ps1       按本仓库约定格式化 .ps1（默认风格 + 行尾注释 2 空格 + 文件头只判定只警告）
docs/notes/           逆向笔记 01 → 09（设备 / HID 协议 / 链路 / 驱动 / 注入 / root / 工具 / 死路 / Termux）
  artifacts/          笔记引用的分析脚本（已脱敏）
temp/                 本地工作区（安装了原始材料）；`src/*/temp/` 是各脚本的运行期缓存（依赖二进制、`.headset_ip`）。两级都靠 `temp/` 一条规则忽略
```

## Commands

本仓库无可构建产物；改动脚本后做语法检查（在仓库根运行）：

```powershell
# PowerShell：仅解析、不执行
powershell -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('src/windows/src/pico_touch.ps1',[ref]$null,[ref]$null)"

# 静态检查（规则裁剪及理由见仓库根 PSScriptAnalyzerSettings.psd1）；改动 .ps1 后跑一遍，应无输出
Invoke-ScriptAnalyzer -Path src/windows/src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1

# 格式化：scripts\format_ps.ps1（只动空白；文件头只判定不修改）
powershell -File scripts\format_ps.ps1          # 就地格式 src\windows\src\*.ps1
powershell -File scripts\format_ps.ps1 -Check   # 只检查，有需改动的文件才 exit 1（文件头层级警告不影响退出码）
```

```sh
sh -n src/shared/start_touch.sh src/termux/*.sh   # POSIX 语法
node --check src/shared/hook.js                   # Frida 脚本（JS）
```

拉取依赖二进制（联网，写入 `src/windows/temp/`，不入库）：

```powershell
powershell -ExecutionPolicy Bypass -File src\windows\src\get_deps.ps1
```

### 设备端（动真机时看这里）

| 路径                                                                                                             | 谁放的                                 | 作用                                                                                          |
| ---------------------------------------------------------------------------------------------------------------- | -------------------------------------- | --------------------------------------------------------------------------------------------- |
| `/data/local/tmp/{frida-inject,hook.js,start_touch.sh}`                                                          | `push.bat` / `pico_touch.ps1`          | 注入三件套（必须 root 才能执行）                                                              |
| `/data/local/tmp/picohaxx`                                                                                       | `pico_touch.ps1` 提权时                | 临时 root（重启失效）                                                                         |
| `/sdcard/Download/pico_touch/{*.sh,hook.js,start_touch.sh,picohaxx.neo3.bin}`                                    | `push.bat`                             | 传输中转：root 时 PC 直接装进 Termux；非 root 时用户在里面跑 `install.sh`                     |
| `~/pico_touch/{termux_touch.sh,get_deps.sh,install.sh,launch.sh,hook.js,start_touch.sh,picohaxx.neo3.bin,logs/}` | `Push-TermuxKit`（root）/ `install.sh` | Termux 方案的 kit（运行期只认自己所在目录，不碰 /sdcard；frida-inject 缺了由 get_deps.sh 拉） |
| `$PREFIX/bin/dptouch`                                                                                            | `Push-TermuxKit` / `install.sh`        | 短命令：头显里敲 `dptouch` 就跑 kit（VR 里少打字）                                            |
| `/data/local/tmp/start_touch.log`                                                                                | `start_touch.sh`                       | 注入过程自述（0666 ⇒ PC 侧不 root 也能读，失败原因都在这儿）                                  |
| `/sdcard/Download/pico_touch/logs/`                                                                              | `pico_touch.ps1`                       | 设备端 logcat                                                                                 |

只读验证配方（省得每次现猜）：

```sh
adb shell id                                                  # uid=0 ⇒ adbd 已被 picohaxx 提权
adb shell '/data/local/tmp/picohaxx -v'                       # 认固件、看 Offsets matched
adb shell 'grep -c frida-agent /proc/$(pidof pxrstreamingservice)/maps'   # >0 ⇒ hook 在（需 adbd 是 root）
adb shell 'tail -3 /data/local/tmp/frida-inject.log'                      # 注入器日志；hook 装好会回执 "touch hook installed"
adb shell 'cat /data/local/tmp/start_touch.log'                           # 注入自述（0666，不需要 root）：失败时 rc / 原因都在这儿
adb shell 'ls -la /data/data/com.termux/files/home/pico_touch; ls -l /data/data/com.termux/files/usr/bin/dptouch'  # 需 adbd 是 root，否则 Permission denied
```

- `patch_driver` 前置：**SteamVR 必须没跑**（`tasklist | findstr vrserver`）；只想验补丁逻辑就用 `-Dll <临时目录里的 DLL 副本>`，别碰真文件。
- UAC 需要人点：跑 `patch_driver.bat` 前先告诉用户一声，别让它干等。
- `picohaxx` 默认 `-adbd` 打完补丁会 **restart adbd** ⇒ 所有 adb 连接当场断开，且新 adbd 读的是易失的 `service.adb.tcp.port`（`persist` 那个不算，5555 监听就没了）。所以 PC 侧必须先 `adb tcpip 5555` 再提权、并带重连循环；Termux 侧**也走 adbd**（设备上跑 adb 会自动认出本机 `emulator-5554`，不用 `adb connect`）⇒ 正靠 adbd 干活，一律 `-noadbd`，别重启它。
- Termux 侧为什么必须借 adbd：Termux 是 app 进程，带 app 的 seccomp 过滤器（BPF，跨 `exec` 继承且不可撤销）⇒ 在 Termux 里跑 `frida-inject` 会被内核 SIGSYS 打死（实测 `rc=159`、注入器日志恒 0 字节）。adbd 由 init 起，`Seccomp: 0`，所以整条链（picohaxx + start_touch.sh）都交给 adbd 跑。

## Rules

### 编码与文件

- 编码 / 行尾以 `.editorconfig` + `.gitattributes` 为准：`.ps1` 含中文必须 BOM（否则 PS 5.1 按 GBK 读会乱码）、`.bat` 无 BOM + CRLF（cmd 见到 LF 会把注释当命令执行）、`sh`/`js` 用 LF —— 别绕开这两处配置。
- `.bat` 只是薄入口（`powershell -File … %*`，最多再跟个 `pause`），逻辑放实现脚本里。
- Prettier（文档，配置，脚本，`pnpx prettier -cw`） / Ruff（Python，`uvx ruff {check,format}`） / PSScriptAnalyzer（PowerShell，`Invoke-ScriptAnalyzer` / `Invoke-Formatter`） 支持处理的文件，改完用对应工具检查及格式化。
  - `.ps1` 排版 = `Invoke-Formatter` 默认风格（别加自定义 formatter settings）；行尾注释与代码之间固定 2 空格；文件头块注释内部按 4 空格一级缩进（4/8/12…）。
  - 格式化一律走 `scripts/format_ps.ps1`（`Invoke-Formatter` 不能原地写、PS 5.1 下还会吃掉文件头 `<#` 的 `<`、并会重排块注释缩进，所以别手搓）：它只改空白，**文件头逐字节保留、层级不对只警告不修改**；只要结果与原文的非空白内容不一致（例如 `Invoke-Formatter` 顺手把 `get-childitem` 规范成 `Get-ChildItem`）、或 `ParseFile` 不通过，就报错且不写盘。

### 脚本行为

- 幂等：能重复跑的脚本必须安全（补丁从 `.orig` 重算、注入前先查 `/proc/<pid>/maps`、推送可覆盖），重复跑不产生第二份副作用。
- 失败要吵：任何失败都要有 `[X]` 消息 + 非零退出码，并由 wrapper 传出去（`exit /b %RC%`）；禁止 `| Out-Null` 吞掉错误还不检查 `$LASTEXITCODE`。
- 只认状态不认字符串：判断设备/服务可用时匹配状态字段（`adb devices` 的 `device`），不要匹配「出现过」。
- 别把常驻进程的 stdout 接进管道：`frida-inject -e` 这类会一直攥着调用方的 stdout/write 端 ⇒ `| tee` 永远等不到 EOF，脚本/`adb shell` 就挂在那儿不退。设备端要长跑的命令自己 detach（`>/dev/null 2>&1 </dev/null &`），外层显示改用「输出进日志文件 + `wait` 主进程」（见 `src/shared/start_touch.sh`、`src/termux/termux_touch.sh`）。
- 别用 `| tail -N` / `| head -N` 收窄长跑命令的输出：它们要读到 EOF 才吐，中间用户看到的是「一点动静都没有」。要少看就写日志文件再取，跑的过程全量打印。
- 也别 `wait` 长跑命令的 `adb shell` 客户端：设备端留下常驻子进程（picohaxx 的喷子）时连接迟迟不关 —— 实测命令早跑完、结果都写进日志了，客户端还挂着。⇒ 远端结果用「轮询设备端日志文件拿标记，拿到就 kill 客户端」（见 `src/termux/termux_touch.sh`）。
- 探测失败就地问用户（`Read-Host`），别改成要求提前传参；探测优先用稳定标识（注册表键值、脚本自身目录），不按本地化名字找。
- 提示语中文，前缀 `[+]` 成功 / `[=]` 跳过 / `[!]` 警告 / `[i]` 说明 / `[X]` 失败；权限类提示写清「要做什么 + 用户要点什么」。
- 措辞分两层：`[i]` 与交互提示用白话（先说现状、再说用户该做什么）；状态 / 诊断行保持精确技术措辞（`offline` / `unauthorized` 原样留着，用户要能照抄去搜）。别把「友好」泛化到诊断行。
- 每个 `.ps1` 顶部 `Set-StrictMode -Version Latest`：变量名写错 / 变量过期必须当场炸，不许静默成 `$null`（`$target` 过期那次就是把 `adb disconnect` 退化成「断开全部连接」）。

### 本项目硬门槛（改动前先想清楚）

- `get_deps` 必须保持逐字节校验（上游 md5 + 补丁点原字节），任一不符即中止、不写入。
- 驱动补丁只对 md5 `9017439d560747678b4550fcf6726808` 的 `driver_pico.dll` 有效；写入前必须校验原字节，失败即中止。
- 固件版本决定 `picohaxx` 的内核符号偏移；换固件须重取符号（见 `docs/notes/06-root.md`），不要假设偏移通用。

### 改动连带面

- 改脚本行为或路径 → 同步 `README.md`、本文件与相关 notes；运行期提示语以 README 为唯一权威，别在多处各抄一份。

## Commit

Use English conventional commit messages:

```text
type(optional scope): description

- List of change briefs, focus one point per row

Optional footer(s)
```
