# 01 · 设备与串流 app

## 设备

| 项       | 值                                                                                                                    |
| -------- | --------------------------------------------------------------------------------------------------------------------- |
| 型号     | Pico Neo 3 Pro（企业版），`ro.product.model=Pico Neo 3`、`ro.product.device=PICOA7H10`                                |
| 系统     | PUI 5.9.9 / Android 10 / 内核 `4.19.81-perf+` / XR2（kona，Adreno650v3）                                              |
| 构建     | `ro.build.fingerprint=Pico/A7H10/PICOA7H10:10/5.9.9/smartcm.1725909320:user/dev-keys`                                 |
| 安全补丁 | `2021-04-05`（漏洞遍地，见 `06`）                                                                                     |
| 锁定     | `ro.boot.flash.locked=1`、`ro.boot.veritymode=enforcing`、单槽（`slot_suffix` 空）、`ro.boot.dynamic_partitions=true` |
| adb      | 无线 `<PC热点网段>.x:5555`（PC 是 ICS/热点网关）；`persist.adb.tcp.port=5555` 已设                                    |

> **DP 直连只有 Neo 3 Pro / Pro Eye 系列才有**（普通 Neo 3 没有 DP 口）。本仓库在 **Pro** 上实测；
> Pro Eye 理论上同样适用（同为 PUI 5.9.9）但未测试；海外版 **Neo 3 Link** 也带 DP 口，同样未测试。
> PC 侧补丁只针对**中国版 v1.2.10** 配套软件。

## 串流 app

```
包名      com.picoxr.bstreamassistant
DP 版     1.2.10（用户态更新，/data/app/...，flags 含 UPDATED_SYSTEM_APP）
系统内置  /system/app/BStreamingAssistant（1.2.0）
```

### 签名事实（决定了「改原 APK」不可行）

- `META-INF/PLATFORM.RSA`，**Pico 自家发布证书**：`CN=AndroidTeam, OU=SW, O=Pico, L=Beijing, C=CN`
  - SHA-256 `dc30289e0a61447d03c95d15e5acf63e18d109d545a766b1208f6b53cbdcd482`
  - 序列号 `0xd59edf6f80d89d86`，2021-03-22 → 2048-08-07
- 与 AOSP `testkey/platform/shared/media/networkstack` **全不匹配**（`ro.build.tags=dev-keys` 只说明 ROM 本身用 AOSP 测试密钥）
- ⇒ 私钥拿不到 ⇒ **无法同密钥重签** ⇒ `pm install -r` 必报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
- app 的系统级权限来自 `UPDATED_SYSTEM_APP` 身份；改包名重打包会丢掉，串流链路直接断

## DP 版 app 没有触摸逻辑（实测）

| 检查                                                                              | DP 版（1.2.9/1.2.10）                                                | 非 DP 版（2.1.1） |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ----------------- |
| `libstreaming_server.so`                                                          | **不存在**                                                           | 存在（9.3 MB）    |
| `TouchEvent` / `MultipleTouchEvent` protobuf                                      | **无**                                                               | **有**            |
| `Triggertouch`/`Thumbresttouch`/`Rockertouch`/`Atouch`/`Btouch`/`Xtouch`/`Ytouch` | **无**                                                               | **有**            |
| `Pxr_GetControllerTouchEvent`                                                     | 只在 `libpxr_api.so` 作为 API 导出，**无任何库引用**                 | —                 |
| `libpicolink_dp.so` 触摸串                                                        | **0**                                                                | —                 |
| `classes.dex` 的 `TouchEvent`                                                     | 11 处**全是 Android UI**（RecyclerView/ItemTouchHelper），与手柄无关 | —                 |

⇒ PICO 运行时有能力，**DP 端只是不读那份数据**。

### DP 版 native 库（`/data/app/.../lib/arm64/`，未 strip）

| 库                                                                                          | 作用                                               |
| ------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `libnative-lib.so` (465 KB)                                                                 | 串流主逻辑；控制器采集与打包（`:picoStream` 进程） |
| `libpicolink_dp.so` (199 KB)                                                                | DP 链路 JNI 薄壳（`DPJniInterface.*`）             |
| `libpxr_api.so` (465 KB)                                                                    | PICO 系统 SDK 转发桩                               |
| `libpxr_base.so` / `libMotionEngine.so` / `libmsquic.so` / `libvibrat*` / `libEncryptor.so` | 其它                                               |

DP 版控制器数据流（`libnative-lib.so`，已确认）：

```
Pxr_GetControllerConnectStatus / Pxr_GetControllerTrackingState
Pxr_GetControllerInputState(hand, state+0xC8)          ← 唯一输入来源
CheckControllerBackKeyEvent / CheckControllerABXYKeyEvent
TransformControllerState(state, PVRControllerState_)   ← 压成 32 位键值掩码
```

## 硬件电容触摸能力（PICO Native SDK 2.0.1 交叉验证）

`PxrControllerInputState` 的 touch 字段只有 5 个：

```
int AXTouchValue;         // +0x48
int BYTouchValue;         // +0x4C
int rockerTouchValue;     // +0x50
int triggerTouchValue;    // +0x54
int thumbrestTouchValue;  // +0x58
```

**没有 grip 的 touch 字段**（grip 只有 `float gripValue` 与 `int sideValue`）；
`PxrControllerKeyMap` 的 TOUCH 事件也只有 AX/BY/ROCKER/TRIGGER/THUMB。

| 部件    | 电容感应                                   |
| ------- | ------------------------------------------ |
| 扳机    | ✅                                         |
| A/B/X/Y | ✅                                         |
| 摇杆    | ✅                                         |
| 拇指托  | ❓（SDK 有字段，Neo 3 是否装传感器未验证） |
| grip    | ❌                                         |

## 非 DP 路径为什么正常

app 在所有模式下都打包同一份 456 字节 `PVRControllerState_`（含全部 5 个 touch 值）。
**非 DP 路径**把这份结构经 QUIC 送到 UW 驱动，掩码映射（`PVRControllerState_ +0x40`，32 位）：

```
bit2 ← AXTouchValue      bit3 ← BYTouchValue     bit4 ← rockerTouchValue
bit5 ← triggerTouchValue bit7 ← thumbrestTouchValue
```

⇒ 触摸齐全。

**DP 路径**走 USB HID，驱动只读 16 位键值字，那份 32 位掩码到不了 PC
（DP 驱动二进制里无任何 USB bulk / WinUSB 字符串）。

> ⚠️ 注意这是**两套不同的编码**：QUIC 掩码（32 位，bit2/3/4/5/7 为触摸）与
> DP 的 HID 键值字（16 位，见 `02`/`04`）不是一回事。
