# 09 · Termux 路径（不需要 PC）

> 头显上装一个 Termux，之后每次开机在头显里敲一个词就能恢复电容触摸。**PC 只在「装 kit 这一次」需要。**
> 本文是 Termux 流程的唯一权威（README 只留一段介绍 + 指针）。

## 为什么必须借 adbd 跑（核心，卡了很久）

Termux 是 **app 进程**，从 zygote 继承了 app 的 **seccomp BPF 过滤器**；这个过滤器**跨 `exec` 继承、且不可撤销**。
于是：在 Termux 里 fork 出来的 `frida-inject`，一碰被拦的 syscall 就被内核 **SIGSYS** 当场打死：

- 注入器退出码 **`rc=159`**（= 128 + 31/SIGSYS）
- 注入器日志**恒为 0 字节**（连一行错误都来不及写）
- `/proc/<pid>/maps` 里永远没有 `frida-agent`

而 **adbd 是 init 起的**，`/proc/self/status` 里 `Seccomp: 0` ⇒ **整条链（picohaxx 提权 + start_touch.sh 注入）交给 adbd 跑就行**。
（「设备本地怎么都挂不上、PC 上 adb 一下就好」，差的就是这条：两条线路只差 seccomp。）

顺带两个结论：

- 设备上跑 `adb` 会**自动**把本机 adbd 认成 `emulator-5554`，**不用 `adb connect`**；前提是头显「设置 → 开发者选项」里开着 adb / 无线调试（adbd 在 5555 上监听）。
- **但 server 不能用 5037**：本机 adbd 自己占着 `127.0.0.1:5037`（实测 adbd 的 fd 指着那个 LISTEN socket），客户端再起 server 会 `could not install *smartsocket* listener: Address already in use` 然后 abort。⇒ 脚本把客户端的 server 端口换掉（`ANDROID_ADB_SERVER_PORT=5038`）；手动折腾时同理：`adb -P 5038 devices` / `export ANDROID_ADB_SERVER_PORT=5038`。
- 固件串**不再需要 PATH shim**：`settings get system confirm_smartisan_version` 在 **shell 域**读得到（只有 app 域被 SELinux 拦），而 picohaxx 现在由 adbd 跑。

## 用法

1. 头显上装 **Termux**（PC 上 `adb install <termux-arm64.apk>`，或从头显侧载 APK）；
2. 头显「设置 → 开发者选项」里**打开 adb / 无线调试**；
3. 把 kit 装进 `~/pico_touch`，二选一：
   - PC 侧跑一次 `push.bat`（那一次 adb 是 root 的话直接装好，Termux 里一个字都不用敲）；
   - 或头显 Termux 里 `termux-setup-storage` 后 `sh /sdcard/Download/pico_touch/install.sh`；
4. 以后**每次开机**在 Termux 里敲：

   ```sh
   dptouch
   ```

`dptouch`（= kit 里的 `termux_touch.sh`）每次做：

1. 装 adb 客户端（缺了才 `pkg install android-tools`）；
2. `adb devices` 认本机 `emulator-5554`（设备上跑 adb 会自动出现，不用 `adb connect`）；
3. 把 `picohaxx / frida-inject / hook.js / start_touch.sh` 推进 `/data/local/tmp`（kit 里缺的由 `get_deps.sh` 拉）；
4. **提权 = 把 adbd 换成 root**（与 PC 侧同一条路）：`adb tcpip 5555`（picohaxx 会重启 adbd，得先设好易失的 `service.adb.tcp.port`）→ `picohaxx -adbd -noftpd` → 等 adbd 以 root 回来、`id -u` 确认。成功之后 Termux 侧的 adb 就是 root，**同一次开机里再跑就是一句 `adb shell start_touch.sh`、秒完**；exploit 偶发挂（`FATAL: SPINLOCK TIMEOUT`）会自动重试一次；
5. **注入**：adbd 是 root ⇒ 直接 `adb shell start_touch.sh`；万一没变 root ⇒ 回退 `picohaxx -noadbd -noftpd -- start_touch.sh`（`-noadbd` 是为了别重启我们正靠着的 adbd）。

日志写 `~/pico_touch/logs/`；失败时会把设备端 `/data/local/tmp/{start_touch.log,frida-inject.log,dptouch_run.log}` 的尾部一起打出来。

## 注入校验：不看退出码就只能瞎猜

`start_touch.sh` 注入后轮询 `/proc/<pid>/maps` 等 `frida-agent`：每轮 30 秒，注入器还活着就再等一轮（最多 4 轮）；期间它**死了**就重试（最多 3 次）。失败时打出**退出码** ＋ 注入器输出 ＋ `dmesg` 末尾，并且全程写一份 `/data/local/tmp/start_touch.log`（0666 ⇒ PC 侧不 root 也能读）。
理由是「没看到 frida-agent」本身分不出是哪一种坏：

| 现象                          | 含义                                                                                            |
| ----------------------------- | ----------------------------------------------------------------------------------------------- |
| `rc=159`                      | **被 SIGSYS 杀** = 继承了 app 的 seccomp ⇒ 这条线路是 Termux 直跑，必须交给 adbd                |
| `rc=137`                      | 被 SIGKILL —— exploit 那波内存风暴里 lmkd / OOM 顺手杀的（实测 lmkd 连 `u:r:su:s0` 的进程都杀） |
| `rc=139`                      | 段错误                                                                                          |
| `rc=1` / `rc=4` ＋ 日志有输出 | frida 自己报错（`rc=4` = 访问不了目标进程）                                                     |
| 等满几轮「仍在跑」            | 没被杀、也没做完：attach 卡住或系统太忙                                                         |
| 日志 0 字节且进程已消失       | 结合上面的 `rc` 判断：`159`=seccomp、`137`=被杀、其余=崩                                        |

其它踩过的坑：

- 注入器输出**不能丢 `/dev/null`**，也不能继承调用方 stdout（`| tee` 等不到 EOF、`adb shell` 会挂住）⇒ 重定向到文件。
- **别把常驻进程的 stdout 接进管道**：picohaxx 留下的喷子进程会一直攥着调用方的 stdout ⇒ 外层 `| tail` 永远等不到 EOF（我就这么卡过 5 分钟）。设备端要长跑的命令自己把输出写文件，外层用「文件 + `wait`」。
- hook 装好会在注入器日志里回执：`{"type":"send","payload":{"ok":true,"msg":"touch hook installed"}}`

- **别把常驻进程的 stdout 接进管道**：picohaxx 留下的喷子进程会一直攥着调用方的 stdout ⇒ 外层 `| tail` 永远等不到 EOF（我就这么卡过 5 分钟）。设备端要长跑的命令自己把输出写文件，外层用「文件 + `wait`」。
- **也别 `wait` 长跑命令的 `adb shell` 客户端**：设备端留下常驻子进程时，连接会迟迟不关 —— 实测命令早就跑完（`[[RC]]` 都写进日志了）客户端还挂着，Termux 里看着就像死机。⇒ 结果改成「轮询设备端日志文件拿标记，拿到就 kill 客户端」。

## 与 PC 路径的关系

|                        | PC 路径                           | Termux 路径（本文）                                                        |
| ---------------------- | --------------------------------- | -------------------------------------------------------------------------- |
| 入口                   | `src\windows\pico_touch.bat`      | `dptouch`（`$PREFIX/bin/dptouch`）                                         |
| 需要 PC                | 需要（跑脚本那一下）              | **不需要**                                                                 |
| 谁跑 picohaxx / 注入器 | adbd（`adb shell`，`Seccomp: 0`） | **同一个 adbd**（设备上的 adb 认成 `emulator-5554`）                       |
| adbd                   | 打补丁成 root + 重连循环          | 也是打补丁成 root（`tcpip` + `-adbd`，失败才回退 `-noadbd`）；之后再跑秒完 |
| 固件串                 | shell 域读 `settings`             | 同左（不再需要 shim）                                                      |
