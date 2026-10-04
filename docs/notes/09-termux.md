# 09 · Termux 路径（不需要 PC）

> 头显上装一个 Termux，之后每次开机在头显里敲一个词就能恢复电容触摸。**PC 只在「装 kit 这一次」需要。**
> 本文是 Termux 流程的唯一权威（README 只留一段介绍 + 指针）。

## 为什么整条链都借 adbd 跑

Termux 是 **app 进程**，从 zygote 继承了 app 的 **seccomp BPF 过滤器**（跨 `exec` 继承、且不可撤销）：
在 Termux 里起的 `frida-inject` 一碰被拦的 syscall 就被内核 **SIGSYS** 打死 —— 退出码 `rc=159`、
注入器日志恒 0 字节、`/proc/<pid>/maps` 里永远没有 `frida-agent`。adbd 由 init 起，`Seccomp: 0`。
picohaxx 在 app 域要额外一个 `settings` 垫片才认得出固件（见 [`06-root.md`](06-root.md)）⇒ 索性连提权也走 adbd，省掉这层。
⇒ **提权和注入都交给 adb 跑**。

设备上跑 `adb` 的两个前提：

- 头显「设置 → 开发者选项」里开着 adb / 无线调试（adbd 在 5555 上监听）；
- **客户端的 server 不能用 5037**：本机 adbd 自己占着 `127.0.0.1:5037`，再起 server 会
  `could not install *smartsocket* listener: Address already in use` ⇒ 脚本用 `ANDROID_ADB_SERVER_PORT=5038`。

## 用法

1. 头显上装 **Termux**（PC 上 `adb install <termux-arm64.apk>`，或从头显侧载 APK）；
2. 头显「设置 → 开发者选项」里**打开 adb / 无线调试**；
3. 装 kit，二选一（**kit 全由 PC 推，头显不再自己下依赖**）：
   - PC 侧跑一次 `push.bat`（那一次 adb 是 root 的话直接装好，Termux 里一个字都不用敲）；
   - 或头显 Termux 里 `termux-setup-storage` 后 `sh /sdcard/Download/pico_touch/install.sh`（只拷 kit + 装短命令）；
4. 以后**每次开机**在 Termux 里敲 `dptouch`。

`dptouch`（= kit 里的 `dptouch.sh`）每次做四件事：

1. 只验 adb：用不了就自己 `pkg update` + `pkg upgrade`（非交互、冲突取新版）+ 装 `android-tools`（旧的包环境是「100% 必挂的 FATAL」第一嫌疑）；顺手把 `ANDROID_ADB_SERVER_PORT=5038` 写进 `~/.bashrc`（幂等，新开的 Termux 会话也生效）。**不自更新** —— 换版本走 PC 侧 `push.bat`；
2. 推 `picohaxx / frida-inject / hook.js / start_touch.sh` 到 `/data/local/tmp`（kit 里缺哪个就让你重跑 `push.bat`）；
3. **提权 = 把 adbd 换成 root**：`adb tcpip 5555`（picohaxx 会重启 adbd，得先设好易失的
   `service.adb.tcp.port`）→ `picohaxx -noftpd -- /system/bin/id`（补 adbd 是默认行为）→ 等 adbd 以 root 回来。
   已经是 root 就跳过 ⇒ 同一次开机里再跑（重启流媒体服务后补注入）**秒完**；
4. 注入：一句 `adb shell start_touch.sh`（输出写设备端 `dptouch_run.log`，轮询 `[[RC]]` 标记拿结果）。

picohaxx 会自己中止（`FATAL: SPINLOCK TIMEOUT`），两种表现：**同一开机里跑多了**（重启头显、或隔会儿重跑，能恢复）、
以及 **100% 每次必挂**（那多半是 Termux 那套环境的问题：清 Termux 数据 + `pkg update`/`pkg upgrade` —— 清数据会把 kit 一起清掉，所以之后要从 PC 侧 `push.bat` 重装 kit，见 [`06-root.md`](06-root.md)）。中止时 adbd 没被动过 ⇒ 脚本当场收工（不再等、也不重试），
把它的输出留一份 `/data/local/tmp/picohaxx.log` 供判读。

日志写 `~/pico_touch/logs/`；失败时把设备端 `/data/local/tmp/{start_touch.log,frida-inject.log,dptouch_run.log}` 的尾部一起打出来。

## 注入校验

`start_touch.sh` 轮询 `/proc/<pid>/maps` 等 `frida-agent`（最多 60 秒）；失败时按注入器退出码报原因
（`159`=继承了 app 的 seccomp、`137`=被 lmkd/OOM 杀、`1`=注入器自己报错），全过程写一份
`/data/local/tmp/start_touch.log`（0666 ⇒ PC 侧不 root 也能读）。

其它踩过的坑：

- 注入器输出**不能丢 `/dev/null`**，也不能继承调用方 stdout（`| tee` 等不到 EOF、`adb shell` 会挂住）⇒ 重定向到文件。
- 也别 `wait` 长跑命令的 `adb shell` 客户端：设备端留着常驻子进程时连接迟迟不关（实测命令早跑完、结果都写进日志了，客户端还挂着）⇒ 结果改成「轮询设备端日志文件拿标记，拿到就 kill 客户端」。
- hook 装好会在注入器日志里回执：`{"type":"send","payload":{"ok":true,"msg":"touch hook installed"}}`。
- 注入器不能吃 Termux 的 `LD_LIBRARY_PATH`（会去 Termux 的库目录找 `libz`/`libcrypto` ⇒ 静默死掉），`TMPDIR` 指到 `/data/local/tmp`。
- `dptouch` 的日志显示是「写文件 + `tail -f` 跟读」；**stdout 恰好就是那份日志时不能 tail**（等于把日志内容又写回自己，自我喂养 —— 实测刷出过 193 MB）⇒ 脚本先比 inode，是同一个就跳过显示。
- exploit 刚跑完那几秒 lmkd 会连着杀进程（实测连 `u:r:su:s0` 的也杀），注入器可能被顺手杀掉 ⇒ 那时重跑一次 `dptouch` 即可。

## 与 PC 路径的关系

|               | PC 路径                           | Termux 路径（本文）                         |
| ------------- | --------------------------------- | ------------------------------------------- |
| 入口          | `src\windows\pico_touch.bat`      | `dptouch`（`$PREFIX/bin/dptouch`）          |
| 需要 PC       | 需要（跑脚本那一下）              | **不需要**                                  |
| 谁跑 picohaxx | adbd（`adb shell`，`Seccomp: 0`） | 同一个 adbd（`adb connect 127.0.0.1:5555`） |
| 谁跑注入器    | 同一个 adbd                       | 同一个 adbd                                 |
| adbd          | 打补丁成 root + 重连循环          | 打补丁成 root（之后再跑秒完）               |
