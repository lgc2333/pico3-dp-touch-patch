# 09 · Termux 路径（不需要 PC / 不用 adb）

> 在头显上装一个 Termux，之后每次开机在头显里跑一条命令就能恢复电容触摸。
> **PC 只在「装 Termux 这一次」需要。**

## 核心思路（踩过两个坑之后）

### 坑 1：picohaxx 打完 adbd 补丁会 `exit(21)`

`root.c` 的 `patch_ADBD()` 末尾是 `kill_adbd()`，而 `kill_adbd()` 是：

```c
void kill_adbd() { system("pkill -9 adbd"); exit(21); }
```

⇒ **第一次跑（原本没 root）时，`-- <cmd>` 根本不会执行**。
必须**分两步**：先提权，再执行命令（第二次已是 root，会跳过补丁）。

### 坑 2：app 域读不到 `settings`，而 fallback 是坏的

picohaxx 靠 `settings get system confirm_smartisan_version` 识别固件。
Termux 是 app 域，调 `settings` 被 SELinux 拦：

```
[*] Device Firmware Version: cmd: Failure calling service settings: Failed transaction (2147483646)
[-] Unsupported Firmware version!
```

源码里的 fallback 是读 `ro.pvr.internal.version` 并把 `_` 换成 `-`，
但**实测编译版返回空串**（`Device Firmware Version: ` 后直接 Unsupported）。

⇒ **用 PATH shim 绕过**：在 PATH 前面放一个假的 `settings`，直接吐出正确版本串。
picohaxx 用 `popen("settings get system confirm_smartisan_version")`，会命中这个 shim。

实测（真实 settings 不可用时）：

```
[*] Device Firmware Version: 5.9.9-202409100313-RELEASE-user-neo3-b5349
[+] Offsets matched: 202409100313
seOffset: 0xffffff800aab5001
```

### 附带：表串改短，兼容两种分隔符

`offsets.h` 的表里是短横线形式（`5.9.9-202409100313`），而
`ro.pvr.internal.version` 是下划线（`..._sv5.9.9_202409100313_...`）。
**已把表串改成只留 build 时间戳 `202409100313`**（12 字符，NUL 补位）⇒ 两种形式都能 `strstr` 命中。

## 一次性准备

1. 装 Termux（PC 上 `adb install` 一个 arm64 的 Termux APK，或从头显文件管理器侧载）
2. 打开 Termux：
   ```sh
   termux-setup-storage
   cp /sdcard/Download/pico_touch/termux_*.sh ~/
   bash ~/termux_setup.sh
   ```

## 每次开机

```sh
bash ~/termux_touch.sh
```

内部做的：

1. 把 `/sdcard/Download/pico_touch/picohaxx` 拷到 `~/` 并 `chmod +x`
2. 在 `~/.pico-shim/settings` 放版本串 shim
3. `PATH=~/.pico-shim:$PATH ~/picohaxx -noftpd` ← 提权（约 50 秒）
4. `PATH=~/.pico-shim:$PATH ~/picohaxx -noftpd -- /data/local/tmp/start_touch.sh` ← 注入

日志：`/sdcard/Download/pico_touch/logs/termux_<时间戳>.log`

## ✅ 已实测跑通（2026-10-04）

在头显的 Termux 里完整跑了一遍，app 域成功执行整条利用链：

```
[!] RACE CONDITION WON!
[+] Forked 80 sprayer processes * 32.00 GB regions (2560.00 GB) 16384 mappings
[!] TARGET PTE IDENTIFIED (scanned: 16)
[5] Patching UID and CAPS in-place.
⏳ [14778.384 ms] TOTAL
[+] execve argv[]: /data/local/tmp/start_touch.sh
已注入（pid=1466），跳过
[✓] 完成
```

⇒ **app 域能开 `/dev/kgsl-3d0`、能 fork 80 进程、能 mmap 2560 GB PTE、能赢竞态** —— 全部验证。
同时也证明 `settings` shim 生效（否则版本识别会失败、利用链根本推进不下去）。

**唯一未实测**：冷启动时第 1 步的 adbd 补丁（`kill_adbd` + `exit(21)`）——
对 Termux 路径无影响（不用 adb），第 2 步会正常接上。

## 与 PC 路径的关系

|                            | PC 路径（已验证）                    | **Termux 路径（已验证）** |
| -------------------------- | ------------------------------------ | ------------------------- |
| 命令                       | `src\windows\pico_touch.ps1`         | `bash ~/termux_touch.sh`  |
| 需要 PC                    | 需要（跑脚本那一下）                 | **不需要**                |
| 用 adb                     | 是（走 Wi-Fi，不需要 USB 线）        | **不用**                  |
| 受 picohaxx 重启 adbd 影响 | 是（脚本已加重连重试）               | **否**                    |
| 步骤                       | 一步（提权后 `adb shell` 就是 root） | **两步**（见上文坑 1）    |
