# 04.b · 驱动二进制地图

> 总览：[04 · PC 端 OpenVR 驱动](04-driver.md)。
> 状态：IDA 静态结论（Hex-Rays 全量交叉验证过）。补丁本身见 [04.c](04_c-driver-touch-patch.md) / [04.d](04_d-driver-skeleton.md)。

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
if (v4 & 0x40) log("kTriggerTouch\n");       // bit6 只喂这条厂商遗留日志（本项目补丁恒跳过）
// controllertype==3 走第二分支：
//   +0x150 ← (v4 & 0x10)          // joystick/click
//   +0x190 ← v11                  // joystick/touch ← 摇杆偏移！★
//   +0x198 / +0x1A0 ← 摇杆 X / Y
//   +0x1A8 / +0x1B0 ← grip 模拟量 / (grip != 0)
//   +0x178 ← (v13 == 255)         // grip/click
//   hand!=0(右): +0x1D8/0x1E0/0x1E8/0x1F0 ← v4 的 bit0/1/2/3  ★★
//   hand==0(左): +0x1B8/0x1C0/0x1C8/0x1D0 ← v4 的 bit0/1/2/3  ★★
UpdateBoolean(+0x180, (v4 & 0x1000) != 0);   // system/click ← bit12
```

### ★★ 关键结论：bit1 / bit3 早已接线

```c
hand != 0（右手）: +0x1D8 ← bit0 (a/click)  +0x1E0 ← bit1 (a/touch)
                  +0x1E8 ← bit2 (b/click)  +0x1F0 ← bit3 (b/touch)
hand == 0（左手）: +0x1B8 ← bit0 (x/click)  +0x1C0 ← bit1 (x/touch)
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

路径 B 的掩码来自头显打包的 `PVRControllerState_`，**只在非 DP 路径经 QUIC 送达**（DP 直连下走路径 A）。

### 路径 B：32 位掩码的位布局（`sub_180018CD0`）

`v7 = *(u32*)(a2 + 0x34)` 是键位掩码（与头显侧 `PVRControllerState_ +0x40` 的偏移差异是结构版本，语义一致）。
两组的判据就是原样保留的 `(dword - 2) & 0xFFFFFFFD` 与 `(dword & 0xFFFFFFFC) == 0 && dword != 2`，本机 `controllertype=3` 落第一组：

| 掩码位 | `controllertype=3`（本机；joystick 预设）     | `controllertype=2`（trackpad 预设） |
| ------ | --------------------------------------------- | ----------------------------------- |
| bit0   | A/X click（右手 `a` / 左手 `x`）              | `/input/system/click`               |
| bit1   | B/Y click                                     | `/input/application_menu/click`     |
| bit2   | A/X touch                                     | —                                   |
| bit3   | B/Y touch                                     | —                                   |
| bit5   | `/input/trigger/touch`                        | —                                   |
| bit6   | `/input/grip/touch`（与 grip 模拟量做「或」） | —                                   |
| bit9   | `/input/system/click`                         | —                                   |
| bit12  | —                                             | `/input/grip/click`                 |
| bit13  | `/input/trigger/click`                        | `/input/trigger/click`              |
| bit15  | `/input/joystick/click`                       | `/input/trackpad/click`             |

- `controllertype` 0/1 走的是和 3 同一段分支（`(dword & 0xFFFFFFFC) == 0 && dword != 2`），但它们加载的是 trackpad 那份 profile，`+0x150` / `+0x158` 就变成 `/input/trackpad/click` / `touch`；本机 ini 是 3，只按第一列看。
- 这一组里 **`/input/application_menu` 一次都不写**；`/input/joystick（或 trackpad）/touch` ← 摇杆偏离中位（不是掩码位）；`/input/grip/click` 看 grip 模拟量（`> 0.99`）。
- 头显侧打包的 5 个 touch 值里，这组只读 `AXTouch(bit2)`、`BYTouch(bit3)`、`triggerTouch(bit5)`；`rockerTouch(bit4)`、`thumbrestTouch(bit7)` 驱动读了也不用（摇杆 touch 走「偏离中位」）—— 见 `01`。
- ⚠️ 与 16 位 HID 键值字（路径 A）是**两套编码**：同一功能位位置不同（system 12↔9、摇杆 click 4↔15、A/X touch 1↔2、B/Y click 2↔1、扳机 click 由模拟量↔bit13）。

## 其它相关函数

| 函数                                                | 作用                                                    |
| --------------------------------------------------- | ------------------------------------------------------- |
| `sub_180026420`                                     | HID 打开：`hid_init` / `hid_open(0x2d40,0x16,0)`        |
| `sub_180026A10`                                     | HID 读循环：`hid_read_timeout(...)==0x40` 才处理        |
| `sub_180025A90`                                     | HID 报文分派：`type = buf[2] >> 5`（`buf[0]` 已被剥掉） |
| `sub_180026E60` / `sub_1800274B0` / `sub_180027EF0` | type0 / type1,2 / type3 处理（IMU 解算）                |
| `sub_18002CE90`                                     | UDP `recvfrom` 接收线程                                 |
| `sub_18003D610`                                     | 控制器状态入口（HID 与 UDP 多路调用）                   |
