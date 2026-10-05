# 05 · 注入实现（跑在头显本地）

## 原理

在 `pxrstreamingservice` 进程内把两端接起来：

```js
// 1) 读：拿到 controller_data_t 里的触摸位
Interceptor.attach(base_of('libpxrcontrollerclient.pxr.so').add(0x1f5c4), {
  // GetControllerKeyData
  onLeave() {
    const b = new Uint8Array(this.p.readByteArray(64))
    touch[b[0]] = {
      ax: b[32] !== 0,
      by: b[36] !== 0,
      stick: b[40] !== 0,
      trig: b[44] !== 0,
    }
  },
})

// 2) 写：把触摸位塞进 63 字节报告体的键值字低字节
Interceptor.attach(base_of('libpxrstreamingservice.so').add(0x18014), {
  // HidIOListener::hidWrite
  onEnter(a) {
    const p = a[1]
    if (a[2].toInt32() !== 63) return
    const b = new Uint8Array(p.readByteArray(63))
    const t = touch[b[1] >> 5] // 报告 type：1=左 2=右
    let nv = b[49] & ~0xaa // 清 bit1/3/5/7
    if (t.ax) nv |= 0x02 // bit1 → /input/a/touch
    if (t.by) nv |= 0x08 // bit3 → /input/b/touch
    if (t.trig) nv |= 0x20 // bit5 → /input/trigger/touch
    if (t.stick) nv |= 0x80 // bit7 → /input/joystick/touch
    p.add(49).writeU8(nv)
  },
})
```

完整脚本：`src/shared/hook.js`（**设备端**用）。

## 为什么能挂上（可行性实测）

```
/proc/1388/status:
  Seccomp:     0                 ← 无 seccomp 过滤（关键！否则 agent 跑不起来）
  NoNewPrivs:  0
  TracerPid:   0
  CapEff:      0000003fffffffff  ← 全能力
/proc/sys/kernel/yama/ptrace_scope : 无 yama ⇒ 无限制
getenforce : Permissive          uid : 0(root)
```

## 当前方案：设备端 `frida-inject`（不需要 PC / adb 长连接）

```sh
# 设备上（root）
/data/local/tmp/frida-inject -p $(pidof pxrstreamingservice) -s /data/local/tmp/hook.js -e
```

`-e` = **eternalize**：注入后保持脚本运行，进程自己退出 ⇒ 一条命令搞定，不需要常驻服务。

|                         | PC 侧 frida-server + client | **设备端 frida-inject**         |
| ----------------------- | --------------------------- | ------------------------------- |
| 需要 PC 常开            | ✅                          | ❌                              |
| 需要 adb / Wi-Fi 长连接 | ✅                          | ❌                              |
| 拔掉 USB 线             | ❌ 注入断                   | ✅ 照常工作                     |
| 依赖                    | frida-server + uv           | 只需 `frida-inject` + `hook.js` |

验证 agent 真在目标进程里：

```sh
grep frida-agent /proc/$(pidof pxrstreamingservice)/maps
# → /memfd:frida-agent-64.so
```

设备端文件：

| 路径                             | 内容                                                 |
| -------------------------------- | ---------------------------------------------------- |
| `/data/local/tmp/frida-inject`   | frida 16.7.19 的 android-arm64 设备端注入器（53 MB） |
| `/data/local/tmp/hook.js`        | 注入脚本                                             |
| `/data/local/tmp/start_touch.sh` | 幂等启动脚本（已注入则跳过）                         |

`start_touch.sh` 核心：

```sh
PID=$(pidof pxrstreamingservice)
grep -q 'frida-agent' /proc/$PID/maps 2>/dev/null && { echo "已注入，跳过"; exit 0; }
exec /data/local/tmp/frida-inject -p "$PID" -s /data/local/tmp/hook.js -e
```

## 一键脚本

`src\windows\pico_touch.ps1`：

1. 认头显：有 USB 就**用 USB**（不会自己换成无线）；没插线才走无线（缓存 IP → ARP 表探测 `:5555`）
   —— USB 下不读、也不记头显 IP：无线那条路要靠头显 **开发者选项**里的无线调试（另外开）
2. 开 TCP 端口：`adb tcpip 5555`（USB 直连也照跑：它设的是易失的 `service.adb.tcp.port`，
   adbd 重启后头显本机才连得上 `127.0.0.1:5555`，Termux 的 `dptouch` 靠这个）；
   这一步会让 adbd 重启一次 ⇒ USB 线短断几秒，脚本轮询等它回来（等不到就提示重插线）
3. picohaxx 拿 root（已是 root 则跳过）
4. 推 3 个文件 → 执行 `start_touch.sh`

```
=== 1/3 认头显 ===        [+] 认定头显 = <序列号>
[+] 用 <序列号>
=== 2/3 抓设备侧日志 + 检查 / 获取 root ===
[*] 先开 TCP 端口 5555 ...
[i] adbd 会重启，USB 线短断几秒（等它自己回来）
[+] USB 已回来
[+] root 已获得 / [=] 已是 root，跳过 picohaxx
=== 3/3 推文件 + 设备端注入 ===  [+] 文件已就位 / 已注入（pid=1388），跳过
[+] 完成。现在可以拔掉 USB 线 / 关掉本窗口。
```

## 客观验证（PC 侧抓 HID 报文）

```
report[50] 取值分布: {0x0:23318, 0x2:986, 0x8:874, 0x20:762, 0x80:951, 0xa:111, 0x5:45}
  bit1 A触摸 ✓   bit3 B触摸 ✓   bit5 扳机 ✓   bit7 摇杆顶 ✓
```

四类触摸全部出现在真实 USB 报文里，且由头显本地 hook 产生。

## 限制

**root 是临时的**（picohaxx 纯内核提权，重启即失效）⇒ 每次开机仍需跑一次 `pico_touch.ps1`。
提权那步必须经 adb，但无线 adb 可用 ⇒ **不用插线**（见下）。

要彻底免 root 得让改动持久化到 `/system` —— 不可行（见 `08`）。

### 两个实测特性

1. **已注入的 hook 与 SELinux 状态无关**：`picohaxx -unroot` 把 SELinux 恢复 Enforcing 之后，
   抓包仍能看到 `bit1/3/5/7` 全部出现。hook 是纯进程内内存操作，不依赖 SELinux。
   ⇒ 拔线、关窗口、切回 Enforcing 都不影响已挂上的 hook。
2. **只有「重新注入」才需要 root**：`frida-inject` 要 ptrace 那个 root 服务 ⇒ 无 root 会失败。

### 无线 adb

设备自带 `ro.pvr.adb_noauth=1`（adb 免授权）⇒ `adb connect` 不需要配对。
开发者设置里就能开无线 adb（本质就是 `persist.adb.tcp.port`），不需要额外配置。

### 完全本地路径（Termux）—— ✅ 已实测跑通

脚本在 `src/termux/`，已推到设备 `/sdcard/Download/pico_touch/`。

流程（PC 侧 push + Termux 初始化 + 每次开机）以 [`09-termux.md`](09-termux.md) 为唯一权威，这里不重复。

**实测证据**（app 域里跑完整条利用链）：

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

**关键设计**（`src/termux/dptouch.sh`，2026-10-05 重写）：

1. **整条链交给设备自己的 adbd 跑**：Termux 是 app 进程，seccomp 过滤器跨 `exec` 继承且不可撤销 ⇒ 在那里跑 `frida-inject` 会被内核 SIGSYS 打死（`rc=159`、日志恒 0 字节）。adbd 由 init 起、`Seccomp: 0`。
2. **提权 = 把 adbd 补成 root**：`adb tcpip 5555` → `picohaxx -noftpd -- /system/bin/id`（补 adbd 是默认行为）；此后设备端 adb 就是 root，注入只剩一句 `adb shell start_touch.sh`。单一路径，没有回落。
3. **客户端 server 换端口**：补成 root 的 adbd 自己占着 `127.0.0.1:5037` ⇒ 客户端用 `ANDROID_ADB_SERVER_PORT=5038`，本机设备照样认成 `emulator-5554`。
4. **固件串不再需要 shim**：`settings get system confirm_smartisan_version` 在 shell 域读得到，只有 app 域被 SELinux 拦。

细节（含退出码对照表、exploit 偶发失败的处理）在 [`09-termux.md`](09-termux.md)。
