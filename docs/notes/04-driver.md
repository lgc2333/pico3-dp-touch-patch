# 04 · PC 端 OpenVR 驱动

## 安装布局

```
D:\Program Files\BusinessStreaming\
├─ BusinessStreamingDP\          ← DP 模式
│  ├─ Business StreamingDP.exe / .pdb / .ilk     （带完整调试符号）
│  ├─ driver_pico.dll (540,160)   ← 废弃副本，不被加载
│  └─ driver\
│     ├─ driver.vrdrivermanifest  name=pico, hmd_presence=["11584.*","22.*"]
│     ├─ bin\win64\driver_pico.dll (669,536)  ← 真正被 vrserver 加载
│     ├─ bin\win64\RVRPlugin.ini              （[PICO] controllertype=3）
│     └─ resources\input\*.json               （输入 profile 与 legacy bindings）
└─ BusinessStreamingUW\          ← 无线模式；驱动 905,216B，依赖 msquic + UsbBulkModule
```

已注册的外部驱动（`%LOCALAPPDATA%\openvr\openvrpaths.vrpath`）：只有 `BusinessStreamingUW\driver`。

### md5

| 文件                                           | md5                                |
| ---------------------------------------------- | ---------------------------------- |
| DP `driver\bin\win64\driver_pico.dll` **原始** | `9017439d560747678b4550fcf6726808` |
| DP 根目录 `driver_pico.dll`（废弃副本）        | `3e411eda6ab7ce0785abb12ef39af9a6` |
| UW `driver\bin\win64\driver_pico.dll`          | `f61949bf7afb4809eaa02daa18be7995` |

## 输入声明层（齐全，不是问题所在）

- `resources\input\pico_controller_profile.json`：9 个输入全部 `"touch": true`
- `legacy_bindings_pico_controller.json`：12 处 `touch` 映射齐全
- profile 按 `controllertype` 二选一（`GetPrivateProfileIntW("PICO","controllertype",0,RVRPlugin.ini)`）：
  - `==3` → `pico_controller_profile.json`：`compatibility_mode_controller_type=oculus_touch`，`/input/joystick`
  - 其它 → `pico_controller2_profile.json`：`vive_controller`，`/input/trackpad`
- **profile 里没声明的输入，`CreateBooleanComponent` 静默失败、句柄留 0**（驱动从不检查返回值）
- `triggertest`（`RVRPlugin.ini` 的 `[PICO] triggertest=202`）是**死配置**：全二进制只有 1 处写、0 处读

## 镜像基址 `0x180000000`；RVA↔文件偏移 `rva = file + 0xc00`

### 驱动对象 = 静态全局 `0x18009AD10`

```
drv = base + 0x9AD10        （16 处引用全是 lea；首 qword = vtable 0x18008C7D8）
drv+0x2a8 → 带 +0x319 的对象   （0 ⇒ 路径 A，否则路径 B）
drv+0x2b0 → 带 +0x21c 的对象   （!=0 才做输入更新）
drv+0x2b8 → 左手控制器对象      drv+0x2c0 → 右手控制器对象
ctrl+0x130 = 设备号；ctrl+0x8 = hand(0 左 / 1 右)；ctrl+0x130 == -1 ⇒ 输入更新立刻 return
```

### 组件句柄表（`sub_1800149E0` 创建；已用 Hex-Rays 全量交叉验证）

| 句柄            | 路径                                               | 句柄            | 路径                                |
| --------------- | -------------------------------------------------- | --------------- | ----------------------------------- |
| +0x140          | `/input/application_menu/click`                    | +0x1A8          | `/input/grip/value`                 |
| +0x148          | `/input/trigger/click`                             | +0x1B0          | `/input/grip/touch`                 |
| +0x150          | `/input/joystick/click` 或 `/input/trackpad/click` | +0x1B8 / +0x1C0 | `/input/x/click` / `/input/x/touch` |
| +0x158          | `/input/trackpad/touch`                            | +0x1C8 / +0x1D0 | `/input/y/click` / `/input/y/touch` |
| +0x160          | `/input/trigger/value`                             | +0x1D8 / +0x1E0 | `/input/a/click` / `/input/a/touch` |
| +0x168 / +0x170 | `/input/trackpad/x` / `y`                          | +0x1E8 / +0x1F0 | `/input/b/click` / `/input/b/touch` |
| +0x178          | `/input/grip/click`                                | **+0x1F8**      | **`/input/trigger/touch`**          |
| +0x180          | `/input/system/click`                              | +0x190          | `/input/joystick/touch`             |
| +0x198 / +0x1A0 | `/input/joystick/x` / `y`                          |                 |                                     |

## 输入更新 `sub_180019580(控制器对象, a2 /*6 字节结构*/)`

`a2` 布局：`[0..1]=键值字(uint16)`、`[2]=摇杆X`、`[3]=摇杆Y`、`[4]=扳机模拟量`、`[5]=grip 模拟量`。

```c
v4  = *a2;                    // 16 位键值字
v12 = *((u8*)a2 + 4);         // 扳机模拟量 0..255
v13 = *((u8*)a2 + 5);         // grip 模拟量 0..255
v11 = (摇杆偏离中位) ? 1 : 0;

UpdateBoolean(+0x140, (v4 & 0x2000) != 0);   // application_menu/click ← bit13
UpdateBoolean(+0x1F8, v12 != 0);             // trigger/touch          ← 扳机模拟量！★
UpdateScalar (+0x160, ...);                  // trigger/value
UpdateBoolean(+0x148, v12 == 255);           // trigger/click
if (v4 & 0x40) log("kTriggerTouch\n");       // bit6 只用于日志
// controllertype==3 走第二分支：
//   +0x150 ← (v4 & 0x10)          // joystick/click
//   +0x190 ← v11                  // joystick/touch ← 摇杆偏移！★
//   +0x198 / +0x1A0 ← 摇杆 X / Y
//   +0x1A8 / +0x1B0 ← grip 模拟量 / (grip != 0)
//   +0x178 ← (v13 == 255)         // grip/click
//   hand==0(左): +0x1D8/0x1E0/0x1E8/0x1F0 ← v4 的 bit0/1/2/3  ★★
//   hand!=0(右): +0x1B8/0x1C0/0x1C8/0x1D0 ← v4 的 bit0/1/2/3  ★★
UpdateBoolean(+0x180, (v4 & 0x1000) != 0);   // system/click ← bit12
```

### ★★ 关键结论：bit1 / bit3 早已接线

```c
hand == 0（左手）: +0x1D8 ← bit0 (a/click)  +0x1E0 ← bit1 (a/touch)
                  +0x1E8 ← bit2 (b/click)  +0x1F0 ← bit3 (b/touch)
hand != 0（右手）: +0x1B8 ← bit0 (x/click)  +0x1C0 ← bit1 (x/touch)
                  +0x1C8 ← bit2 (y/click)  +0x1D0 ← bit3 (y/touch)
```

**驱动本来就支持 A/B（X/Y）的电容触摸，只是头显从不发这两个位。**
⇒ 把触摸写进 bit1/bit3，**PC 侧一行都不用改**。

### ★ 扳机 / 摇杆顶的 touch 被绑在模拟量上（需要补丁）

- `/input/trigger/touch`（+0x1F8）← `扳机模拟量 != 0`
- `/input/joystick/touch`（+0x190）← `摇杆偏离中位`

### 两条互斥路径（`sub_18003D610(dev, hand, pose_state, key_struct)` 分派）

```
if (*(char*)(*(dev+0x2a8)+0x319) == 0) {
    if (*(char*)(*(dev+0x2b0)+0x21c) != 0)
        sub_180019580(ctrl, &key6);     // 路径 A（DP 走这条）
} else {
    sub_180018CD0(ctrl, &state);        // 路径 B：从 state+0x34 取 32 位掩码
}
```

路径 B 的掩码来自头显打包的 `PVRControllerState_`，**只在非 DP 路径经 QUIC 送达**。

## 补丁（14 字节，零长度变化）—— **已应用**

`/input/trigger/touch` ← 键值字 **bit5**；`/input/joystick/touch` ← 键值字 **bit7**

| RVA           | 文件偏移  | 原字节                 | 新字节                 | 汇编                           |
| ------------- | --------- | ---------------------- | ---------------------- | ------------------------------ |
| `0x1800197b8` | `0x18bb8` | `0f 57 db 41 0f 95 c0` | `41 88 f0 41 80 e0 20` | `mov r8b,sil` / `and r8b,0x20` |
| `0x18001991d` | `0x18d1d` | `0f 57 db`             | `41 88 f0`             | `mov r8b,sil`                  |
| `0x180019927` | `0x18d27` | `45 0f b6 c7`          | `41 80 e0 80`          | `and r8b,0x80`                 |

- 两处 `xorps xmm3,xmm3`（ABI 卫生，`UpdateBoolean` 无浮点参数）被安全占用
- 中间的 `mov rdx,[rdi+...]` 不改 r8b / 不改标志位，顺序无碍
- 假设 `IVRDriverInput::UpdateBoolean(handle, bool)` 对「非零」判真（0x20/0x80 即真）——**实测有效**

应用：`src\windows\patch_driver.ps1`（管理员 + 已退出 SteamVR），自动备份 + 逐字节校验 + 复核。
还原：把 `driver_pico.dll.orig`（md5 `9017439d…`）复制回 `driver_pico.dll`。

## 键值字位占用总表

| 位     | 用途                   | 来源                     |
| ------ | ---------------------- | ------------------------ |
| 0      | A/X click              | 头显原有                 |
| **1**  | **A/X 电容触摸**       | 本项目新增               |
| 2      | B/Y click              | 头显原有                 |
| **3**  | **B/Y 电容触摸**       | 本项目新增               |
| 4      | 摇杆 click             | 头显原有                 |
| **5**  | **扳机电容触摸**       | 本项目新增（需驱动补丁） |
| 6      | 扳机 click             | 头显原有                 |
| **7**  | **摇杆顶电容触摸**     | 本项目新增（需驱动补丁） |
| 8–11   | 空闲                   | —                        |
| 12     | system click           | 头显原有                 |
| 13     | application_menu click | 头显原有                 |
| 14, 15 | 空闲                   | —                        |

## 其它相关函数

| 函数                                                | 作用                                                    |
| --------------------------------------------------- | ------------------------------------------------------- |
| `sub_180026420`                                     | HID 打开：`hid_init` / `hid_open(0x2d40,0x16,0)`        |
| `sub_180026A10`                                     | HID 读循环：`hid_read_timeout(...)==0x40` 才处理        |
| `sub_180025A90`                                     | HID 报文分派：`type = buf[2] >> 5`（`buf[0]` 已被剥掉） |
| `sub_180026E60` / `sub_1800274B0` / `sub_180027EF0` | type0 / type1,2 / type3 处理（IMU 解算）                |
| `sub_18002CE90`                                     | UDP `recvfrom` 接收线程                                 |
| `sub_18003D610`                                     | 控制器状态入口（HID 与 UDP 多路调用）                   |
