# AGENTS.md

PICO Neo 3 Pro（企业版）在「Business Streaming DP 直连」下补回手柄电容触摸：头显端 Frida hook + PC 驱动补丁。面向用户的说明在 `README.md`；完整逆向记录在 `docs/`。

## Structure

```text
src/
  windows/            PC（Windows）侧：wrapper 在外面，实现和缓存都在里面
    pico_touch.bat / patch_driver.bat / push.bat / downgrade_streaming.bat   双击即用的入口，只负责调 src/ 下的脚本
    src/              实现脚本（PowerShell 5.1+）
      _utils.ps1      公用：仓库路径、找/补 adb.exe、拉依赖、认/连头显、装 Termux kit（被下面几个点源）
      pico_touch.ps1  一键：找头显 → 无线 adb → picohaxx 提权 → 推送 → 设备端注入
      push.ps1        只推文件：设备端三件套 + Termux 要用的（不提权、不注入）
      downgrade_streaming.ps1 头显端企业串流换版本：校验 sha256 的 APK → `adb uninstall` 卸用户态更新 → `adb install -r -d` → 读回 versionName/flags；PC 端安装包问过才下
      patch_driver.ps1 驱动补丁（自己定位 DLL：注册表/OpenVR/问用户；未提权自己弹 UAC）；改 DLL 两处：15 字节的触摸位补丁 + 新增 `.pitouch` 段（把 v2 的骨架实现整段搬进来，补 `/pose/raw` + `/skeleton/*`，见 `docs/notes/04-driver.md`）；顺手补 profile 里 `input/application_menu` 的斜杠（补完 menu 键才在 SteamVR 里生效）、修 `rendermodels\*.json` 里 `tip` 的角度笔误、补厂商漏发的 `pico_hmd_profile.json`。**游戏里手柄偏 ≈9cm 未解决**：几何/位姿都验过是对的，偏的是 app 对「被冒充成 oculus_touch」的特判，试过的四条（补 grip/aim 组件、平移几何、镜像补右手网格、换模型名）全无效并已回滚，别再重走
      driver_patch/   骨架 payload（`dp_skeleton_payload.{bin,json}`，**入库**）：从 v2 驱动整段搬来的机器码 + 清单，patch_driver.ps1 直接用（离线）；缺失就直接中止（重新生成跑 `docs/notes/artifacts/build_dp_skeleton_payload.py`）
      get_deps.ps1    从上游拉 frida-inject / picohaxx（并打 Neo 3 补丁）/ platform-tools（-PlatformTools）
    temp/             运行期缓存：依赖二进制、`.headset_ip`（整目录被 .gitignore 忽略）
  termux/             头显端（Termux）的 kit：装进 ~/pico_touch 即用，运行期不碰 /sdcard
    dptouch.sh        每次开机跑：只验 adb（**不自更新**，换版本走 install.sh / push.bat）+ 经本机 adbd 提权 picohaxx 并注入（**单一路径，无回落**）；缺 adb 时自己 `pkg update/upgrade` + 装 android-tools；日志写 ./logs/
    install.sh        兜底装 kit（PC 侧 adbd 非 root 时）：/sdcard 的 kit → ~/pico_touch + 把 `$PREFIX/bin/dptouch` 建成 symlink（头显不再自己下依赖）
  shared/             两端共用的设备端脚本
    hook.js           Frida 脚本：键值字 bit1/3/5/7 ← controller_data_t +32/+36/+40/+44
    start_touch.sh    幂等启动（检查 /proc/<pid>/maps 是否已有 frida-agent）
scripts/              仓库工具（不被脚本运行期依赖）
  format_ps.ps1       按本仓库约定格式化 .ps1（默认风格 + 行尾注释 2 空格 + 文件头只判定只警告）
docs/notes/           逆向笔记 01 → 09（设备 / HID 协议 / 链路 / 驱动 / 注入 / root / 工具 / 死路 / Termux）
  artifacts/          笔记引用的分析脚本：`build_dp_skeleton_payload.py`（手动重建骨架 payload 用）、`dp_skeleton_payload_test.py`（重定位 + Unicorn 差分）、`dp_skeleton_image_test.py`（打完补丁的整镜像）
temp/                 本地工作区（安装了原始材料）；`src/*/temp/` 是各脚本的运行期缓存（依赖二进制、`.headset_ip`）。两级都靠 `temp/` 一条规则忽略
```

## Commands

入口全在仓库根 `package.json`（`pnpm run` / `npm run` 均可）；本仓库无可构建产物。

```powershell
pnpm run check        # 全跑：shellcheck + PS（format→ParseFile + PSScriptAnalyzer）+ node --check + prettier -c
pnpm run check:ps     # 只跑 PS 那两件（规则裁剪及理由见仓库根 PSScriptAnalyzerSettings.psd1）
pnpm run fmt:ps       # 就地格式化 .ps1（只动空白；文件头逐字节保留、层级只警告）
pnpm run fmt:md       # 文档就地格式化（prettier）
pnpm run deps         # 联网拉依赖二进制到 src/windows/temp/（不入库）
pnpm run device:all   # 设备只读验证：id / seccomp / hook / kit / logs（一个探针一条 adb 命令）
```

任务没覆盖、偶尔还要手敲的：

```sh
sh -n src/termux/dptouch.sh src/termux/install.sh src/shared/start_touch.sh   # POSIX 语法（shellcheck 也会报语法错）
```

## 设备端（动真机时看这里）

| 路径                                                                                               | 谁放的                                 | 作用                                                                                                                                      |
| -------------------------------------------------------------------------------------------------- | -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `/data/local/tmp/{frida-inject,hook.js,start_touch.sh}`                                            | `push.bat` / `pico_touch.ps1`          | 注入三件套（必须 root 才能执行）                                                                                                          |
| `/data/local/tmp/picohaxx`                                                                         | `pico_touch.ps1` 提权时                | 临时 root（重启失效）                                                                                                                     |
| `/data/local/tmp/picohaxx.log`                                                                     | `dptouch.sh`                           | 提权那步 picohaxx 的输出（一眼判它是打完补丁还是自己中止）                                                                                |
| `/data/local/tmp/dptouch_run.log`                                                                  | `dptouch.sh`                           | 注入那步的全过程，末尾 `[[RC]]=<rc>`（脚本轮询它拿结果，不等 adb 客户端）                                                                 |
| `/sdcard/Download/pico_touch/{*.sh,hook.js,start_touch.sh,picohaxx.neo3.bin,frida-inject}`         | `push.bat`                             | 传输中转（**要完整**：头显侧不下依赖）：root 时 PC 直接装进 Termux；非 root 时用户在里面跑 `install.sh`                                   |
| `~/pico_touch/{dptouch.sh,install.sh,hook.js,start_touch.sh,picohaxx.neo3.bin,frida-inject,logs/}` | `Push-TermuxKit`（root）/ `install.sh` | Termux 方案的 kit（**全由 PC 推**：头显侧不下依赖；目录 `chmod 755` ⇒ shell 用户的 adb 也读得到 kit；运行期不碰 /sdcard）                 |
| `$PREFIX/bin/dptouch`                                                                              | `Push-TermuxKit` / `install.sh`        | 短命令（VR 里少打字）：**symlink 到 `~/pico_touch/dptouch.sh`**（脚本 `readlink -f` 找真身）；root 建的条目必须 `chcon -h <app 的上下文>` |
| `/data/local/tmp/start_touch.log`                                                                  | `start_touch.sh`                       | 注入过程自述（0666 ⇒ PC 侧不 root 也能读，失败原因都在这儿）                                                                              |
| `/sdcard/Download/pico_touch/logs/`                                                                | `pico_touch.ps1` / `dptouch.sh`        | 设备端 logcat ＋ `dptouch` 日志的镜像（不 root 的 adb / PC 读得到）                                                                       |

只读验证：优先 `pnpm run device:all`（id / seccomp / hook / kit / logs；实现见 `scripts/device_probe.ps1`）。探针没覆盖、偶尔还要手敲的几条：

```sh
adb shell '/data/local/tmp/picohaxx -v'                       # 认固件、看 Offsets matched
adb shell 'tail -3 /data/local/tmp/frida-inject.log'          # 注入器日志；hook 装好会回执 "touch hook installed"
adb shell 'ls -la /data/data/com.termux/files/home/pico_touch; ls -l /data/data/com.termux/files/usr/bin/dptouch'  # 属主与 symlink
```

- 设备端命令**不要带双引号**：PowerShell 5.1 调 `adb.exe` 时，`\"` 的转义过不了 Windows 的 argv 层（设备端看到字面量 `\"`，`[ -n \"$p\" ]` 恒真）⇒ 用 `[ $p ]`、`pidof -s`，需要临时变量就在同一条命令里 `f=$(…)` 后判空。
- **`$PREFIX/bin/dptouch` 是 symlink，标签必须等于 app 自己的**：root 建出来的条目默认只带 `u:object_r:app_data_file:s0`、少了 app 的类别（`s0:c126,c256,c512,c768`）⇒ app 连 `stat` 都被拒（`install.sh` 报 `cp: cannot stat '…/dptouch'`、敲 `dptouch` 直接 Permission denied）。实机踩过两次（2026-10-05），第二次的真凶是：**Android 的 toybox `chcon` 不支持 `--reference`**（`chcon: Unknown option reference=…`），而它在 `;` 链里静默失败、整条命令的退出码还被后面的 `restorecon` 覆盖成 0 ⇒ 必须显式喂上下文：宿主侧从 `ls -Zd $PREFIX/home` 取第一列，再 `chcon -h <ctx> $PREFIX/bin/dptouch`（设备端命令里别嵌引号，见上一条）。`Push-TermuxKit` 现在建完会 `ls -lZ` 反查、标签不对就 `[X]` 并让用户跑 `install.sh`（最稳还是让 app 自己建：`install.sh` 由 app 执行，标签天然正确）。`/sdcard` 那份必须是**完整** kit（含 `frida-inject`，头显侧不下依赖）。
- `patch_driver` 前置：**SteamVR 必须没跑**（`tasklist | findstr vrserver`）；**Steam 客户端也可能映射着 `driver_pico.dll`**（`tasklist /m` 不一定列得出来，提权后 `Get-Process | %{ $_.Modules }` 看得到；实测 `steam.exe` 占着就写盘失败并抛「文件正由另一进程使用」）⇒ 遇到就请用户把 Steam 一起退掉再跑；只想验补丁逻辑就用 `-Dll <临时目录里的 DLL 副本>`，别碰真文件。
- 骨架 payload **在仓库里**（`src/windows/src/driver_patch/`）⇒ 打补丁完全离线；**别删** —— `patch_driver` 不再自己找 v2 的 DLL，缺了就直接 `[X]`（重建要手动跑 `docs/notes/artifacts/build_dp_skeleton_payload.py`）。
- UAC 需要人点：跑 `patch_driver.bat` 前先告诉用户一声，别让它干等。
- `picohaxx` 默认 `-adbd`：打完 adbd 补丁会 **restart adbd** ⇒ 所有 adb 连接当场断开，且新 adbd 读的是易失的 `service.adb.tcp.port`（`persist` 那个不算）⇒ 两边都得先 `adb tcpip 5555` 再提权：PC 侧带重连循环，Termux 侧用 `adb connect 127.0.0.1:5555` 轮询等它回来。它自己中止（`FATAL: SPINLOCK TIMEOUT`）时 adbd **压根没被动过**（既不掉线也不变 root）⇒ 两边都不干等、不重试（判据与两种表现见 `docs/notes/06-root.md`）。Termux 侧只有这一条路：提权也经 adbd（app 域直跑还要一个 `settings` 垫片，不值当）。
- **Termux 那套包得是好的**：老包 `adb` 会 `CANNOT LINK EXECUTABLE`，旧的包环境也是「100% 必挂的 FATAL」的第一嫌疑（见 `docs/notes/06-root.md`）⇒ `dptouch` 发现 adb 用不了就自己 `pkg update` + `pkg upgrade`（非交互、配置文件冲突取新版）并装 `android-tools`；包正常时它只 `adb version` 验一下、不碰 `pkg`。
- Termux 侧为什么整条链都借 adbd：Termux 是 app 进程，带 app 的 seccomp 过滤器（BPF，跨 `exec` 继承且不可撤销）⇒ 在 Termux 里跑 `frida-inject` 会被内核 SIGSYS 打死（实测 `rc=159`、注入器日志恒 0 字节）；adbd 由 init 起，`Seccomp: 0`。完整流程见 `docs/notes/09-termux.md`。

## Rules

### 编码与文件

- 编码 / 行尾以 `.editorconfig` + `.gitattributes` 为准：`.ps1` 含中文必须 BOM（否则 PS 5.1 按 GBK 读会乱码）、`.bat` 无 BOM + CRLF（cmd 见到 LF 会把注释当命令执行）、`sh`/`js` 用 LF —— 别绕开这两处配置。
- `.bat` 只是薄入口（`powershell -File … %*`，最多再跟个 `pause`），逻辑放实现脚本里。
- Prettier（文档，配置，脚本，`pnpx prettier -cw`） / Ruff（Python，`uvx ruff {check,format}`） / PSScriptAnalyzer（PowerShell，`Invoke-ScriptAnalyzer` / `Invoke-Formatter`） 支持处理的文件，改完用对应工具检查及格式化。
  - `.ps1` 排版 = `Invoke-Formatter` 默认风格（别加自定义 formatter settings）；行尾注释与代码之间固定 2 空格；文件头块注释内部**顶格起、每级 4 空格**（0/4/8…）。
  - 格式化一律走 `scripts/format_ps.ps1`（`Invoke-Formatter` 不能原地写、PS 5.1 下还会吃掉文件头 `<#` 的 `<`、并会重排块注释缩进，所以别手搓）：它只改空白，**文件头逐字节保留、层级不对只警告不修改**；只要结果与原文的非空白内容不一致（例如 `Invoke-Formatter` 顺手把 `get-childitem` 规范成 `Get-ChildItem`）、或 `ParseFile` 不通过，就报错且不写盘。

### 脚本行为

- 幂等：能重复跑的脚本必须安全（补丁从 `.orig` 重算、注入前先查 `/proc/<pid>/maps`、推送可覆盖），重复跑不产生第二份副作用。
- `.orig` 的语义是「脚本动手前那一刻的副本」，**不保证是厂商原件**：`.orig` 不在时就把当前文件存成它（`.ps1` 里三个阶段统一，故意如此）。DLL 那步靠 md5 + 原字节校验兜底（不是原版会 `[X]` 中止且不写盘），别「顺手修」成校验通过后再备份。
- 失败要吵：任何失败都要有 `[X]` 消息 + 非零退出码，并由 wrapper 传出去（`exit /b %RC%`）；禁止 `| Out-Null` 吞掉错误还不检查 `$LASTEXITCODE`。
- 只认状态不认字符串：判断设备/服务可用时匹配状态字段（`adb devices` 的 `device`），不要匹配「出现过」。
- 别把常驻进程的 stdout 接进管道：`frida-inject -e` 这类会一直攥着调用方的 stdout/write 端 ⇒ `| tee` 永远等不到 EOF，脚本/`adb shell` 就挂在那儿不退。设备端要长跑的命令自己 detach（`>/dev/null 2>&1 </dev/null &`），外层显示改用「输出进日志文件 + `wait` 主进程」（见 `src/shared/start_touch.sh`、`src/termux/dptouch.sh`）。
- exploit 自己中止（`FATAL: SPINLOCK TIMEOUT`）时 adbd **压根没被动过**（既不掉线也不变 root）⇒ 别再去等它「以 root 回来」：Termux 侧读设备端 `picohaxx.log` 判 FATAL 就收工，PC 侧用「adbd 还在且 `id -u` ≠ 0」判同一种中止；两边都不重试、不回落（表现一 = 同一开机跑多了；表现二 = 100% 必挂 ⇒ 先怀疑 Termux 那套环境；见 `docs/notes/06-root.md`）。
- 轮询/等待要报进度：等设备、等 adbd 回来、等远端结果这类循环，每几秒打一行（`[i] 还在等…（第 N/M 轮）`），别让程序看起来卡死；能顺带打印远端输出的就把输出跟着看（写文件 + `tail`）。
- 输出是给用户的、不是给作者的：**成功路径只报用户结果**（一行一件事，别报文件偏移 / 字节数 / RVA / 内部函数名 / 逐步 trace ——那些进注释或失败信息），只打**状态值**（rc / 已等秒数 / 版本号）和**用户该做什么**（要点的按钮、要跑的 setup）；解释原理、机制的话写成注释，别 `echo`。也别在输出里自我辩解（「别嫌长」这类）。
- 前缀只用 `[+]` 成功 / `[=]` 跳过 / `[!]` 警告 / `[i]` 说明 / `[X]` 失败 —— 别自造 `[*]` 之类的临时标记。
- 注释只留「一句话 + 指针」：能指 `docs/notes/` 就别复述 —— 文档讲过的机制不要在脚本里再讲一遍。
- 也别 `wait` 长跑命令的 `adb shell` 客户端：设备端留下常驻子进程（picohaxx 的喷子）时连接迟迟不关 —— 实测命令早跑完、结果都写进日志了，客户端还挂着。⇒ 远端结果用「轮询设备端日志文件拿标记，拿到就 kill 客户端」（见 `src/termux/dptouch.sh`）。
- 探测失败就地问用户（`Read-Host`），别改成要求提前传参；探测优先用稳定标识（注册表键值、脚本自身目录），不按本地化名字找。
- 提示语中文，前缀 `[+]` 成功 / `[=]` 跳过 / `[!]` 警告 / `[i]` 说明 / `[X]` 失败；权限类提示写清「要做什么 + 用户要点什么」。
- 措辞分两层：`[i]` 与交互提示用白话（先说现状、再说用户该做什么）；状态 / 诊断行保持精确技术措辞（`offline` / `unauthorized` 原样留着，用户要能照抄去搜）。别把「友好」泛化到诊断行。
- 每个 `.ps1` 顶部 `Set-StrictMode -Version Latest`：变量名写错 / 变量过期必须当场炸，不许静默成 `$null`（`$target` 过期那次就是把 `adb disconnect` 退化成「断开全部连接」）。

### 本项目硬门槛（改动前先想清楚）

- `get_deps.ps1`（PC 侧唯一的依赖来源）必须保持逐字节校验（上游 md5 + 补丁点原字节），任一不符即中止、不写入。
- 驱动补丁只对 md5 `9017439d560747678b4550fcf6726808` 的 `driver_pico.dll` 有效；写入前必须校验原字节，失败即中止。
- 骨架 payload 只对 v2 的 `driver_pico.dll`（sha256 `d851b7d1…`）有效，且段 RVA 固定 = DP 的 `SizeOfImage`（`0xAB000`）；`docs/notes/artifacts/build_dp_skeleton_payload.py` 卡源 DLL 的 sha256，`patch_driver.ps1` 卡段数 / `SizeOfImage` / 段表 / 两个挂钩点原字节，任一不符即中止 —— 别放宽这几处。
- 固件版本决定 `picohaxx` 的内核符号偏移；换固件须重取符号（见 `docs/notes/06-root.md`），不要假设偏移通用。
- **从 v2 抄常量 / 分支前先确认自己落在哪个「型号 × 形态」上**：v2 支持 Neo2 / Neo3 / PICO4 / 4S 四种控制器，每种还有「手柄 / 手部追踪（设备自称 `Pico Hand`）」两种形态，同一个标志位常常同时决定设备身份和驱动行为（例：`*(this+0x2E0)` 既是"手部追踪版"、又决定 `eSkeletalTrackingLevel` 取 0 还是 2；手序号 v2 用 1/2 而 DP 用 0/1）。矩阵与踩坑记录见 `docs/notes/04-driver.md` 的「移植前必读」；移植前问三句：这段在哪个型号分支？这个标志位还有别的用途吗？我们（DP / Neo 3 / 手柄形态）落在哪一支？
- `downgrade_streaming.ps1` 的两个上游产物（头显端 APK、PC 端安装包）必须保持 sha256 逐字节校验：`URL` 与 `Sha` 成对改，任一不符即中止（缓存里的也要每次重算）。

### 改动连带面

- `README.md` 是**面向用户**的：只写用户看得见的影响（能做什么、要准备什么、怎么还原），除「原理」一节外不写用户看不懂的内容，**保持简短**；机制、偏移、验证一律进 `docs/notes/`。
- 改脚本行为或路径 → 同步 `README.md`、本文件与相关 notes；运行期提示语以 README 为唯一权威，别在多处各抄一份。
- 驱动补丁的字节数只在 `docs/notes/04-driver.md` 记一次 —— `README.md`、本文件与其它 notes 一律不写数字，省得每次动补丁都要全仓库同步。
- 文档分三层：**实测 / 推测 / 设计选择** —— 别把「我们没这么做」写成「做不到」（翻过车：app 域直跑 + `settings` 垫片其实可行）；结论变了要把旧说法一起改掉。
- 用户当场纠正的事实：**同一轮**里改到位 —— 不只改被点名那一句，同源处（脚本提示、README、本文件、notes）一起扫掉。

## Commit

Use English conventional commit messages:

```text
type(optional scope): description

- List of change briefs, focus one point per row

Optional footer(s)
```
