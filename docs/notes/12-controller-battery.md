# 12 · 手柄电量上报（可行性调查）

> 问题：能不能把两只手柄的电量上报到 SteamVR。
> 结论：**能，但必须头显端与 PC 驱动端一起改**；**DP、UW、v2.1.2 三代驱动都没有电量上报**（v2.1.2 已实测）。
> 状态：调查完成，实现未开始。

## 一、SteamVR 侧要什么

电量是 tracked device 的属性，驱动得同时报三样：

| 属性                                    | 值     | 作用                          |
| --------------------------------------- | ------ | ----------------------------- |
| `Prop_DeviceBatteryPercentage_Float`    | 0..1   | 电量百分比                    |
| `Prop_DeviceProvidesBatteryStatus_Bool` | `true` | **没有它 SteamVR 不显示电量** |
| `Prop_DeviceIsCharging_Bool`            | `bool` | 充电中                        |

## 二、PC 驱动现状（实测，静态）

扫描方法：在 DLL 里找 3000–3010 的小端立即数（属性号只能以常量出现在代码里），按 `.pdata` 归到函数，再解出写属性的批结构。

| 属性                                    | DP（`9017439d…`）   | UW / `PicoNeo2NvencCompat`（`f61949bf…`） | v2.1.2（`e6d408b2…`） |
| --------------------------------------- | ------------------- | ----------------------------------------- | --------------------- |
| `Prop_DeviceIsWireless_Bool`            | 有                  | 有                                        | 有                    |
| `Prop_DeviceIsCharging_Bool`            | 有，写常量 `-1`     | 有，写常量 `-1`                           | 有，写常量 `-1`       |
| `Prop_DeviceBatteryPercentage_Float`    | 有 3 处，写常量 `1` | 有，写常量 `1`                            | 有 1 处，写常量 `2`   |
| `Prop_DeviceProvidesBatteryStatus_Bool` | **0 处**            | **0 处**                                  | **0 处**              |

- `IsCharging` 与 `BatteryPercentage` 都写在设备激活那条路径上（与组件句柄表同一个函数），值是常量 ⇒ 不是真电量。
- 写属性的通道是 `IVRProperties_001::WritePropertyBatch`；容器句柄由 `TrackedDeviceToPropertyContainer(设备号)` 换来，激活时缓存在 `ctrl+0x138`（设备号在 `ctrl+0x130`，见 [04.b](04_b-driver-binary.md)）。
- v2.1.2 的驱动（`e6d408b2…`，也是骨架 payload 的来源）已解开安装包实测：同样 0 处 `ProvidesBatteryStatus` ⇒ 三代驱动都没有电量上报。安装包地址见 [04](04-driver.md) 的「v2.1.2 安装包」。

## 三、头显侧有没有电量（实测，静态）

`/system/lib64/libpxrcontrollerservice.so`：

| 符号                                                                  | 语义                                 |
| --------------------------------------------------------------------- | ------------------------------------ |
| `MCUController::getControllerBattery`                                 | 从 MCU 读电量                        |
| `MCUController::getControllerBatteryByStation`                        | 读后按手存进 `this + 0x104 + hand*4` |
| `MCUController::handleControllerBatteryChange(int hand, int battery)` | 电量变化回调，写同一组槽位           |
| `StationPxrControllerService::setControllerBattery(int, int)`         | 服务层入口                           |
| `IControllerServiceListener::onControllerStatusChange`                | 变化通知                             |

`pxrstreamingservice` 的 `getControllerDataThread` **已经在调** `mControllerInterface.getControllerStatus`
（失败日志 `mControllerInterface.getControllerStatus fail.`，成功日志 `… [%d,%d]`）⇒ 取状态的通道在进程内已通，
只是没把电量送给 PC。

⇒ 电量值在头显上确实存在，但**它落在传给串流服务的哪个结构、哪个偏移还没定**：
`MCUController::getControllerStatus` 只把 `+0xa0..+0xff` 拷进 parcelable，电量槽位 `+0x104` 不在这段里 ⇒ 需要运行期 dump 才能定。

## 四、HID 报文有没有空位（实测）

按 [02](02-hid-protocol.md) 的布局，手柄报文（type 1/2）里 `report[47]` / `report[48]`
（即报告体 `data[46]` / `data[47]`）用途未定，两只手各 2 字节，够放「电量 0–100 + 充电 / 有效标志」。

## 五、方案（设计选择，未实施）

1. **头显端**：在现有的 `hook.js` 里再挂 `HidIOListener::hidWrite`，把电量与标志写进 `data[46]` / `data[47]`，只动手柄报文。
2. **PC 驱动**：在 type 1/2 报文处理链上加一段桩，用 `WritePropertyBatch` 写「我能报电量」一次，之后每次按电量换算 0..1 写百分比，充电位写充电状态。
3. **验证**：SteamVR 控制器面板对照，再换一只低电手柄复查。

## 六、未决与风险

| 项                     | 状态                                                   |
| ---------------------- | ------------------------------------------------------ |
| 电量在状态结构里的偏移 | 待实测（手柄开机后 dump）                              |
| 有没有充电位           | 待实测                                                 |
| `.pitouch` 剩余空间    | 放桩够用；真扩段要改 `SizeOfImage` 的断言              |
| SteamVR 属性缓存       | 首次读到才显示，可能要在会话建立早期就写「我能报电量」 |

## 七、复现方法

- 属性扫描：`pefile` + `capstone`，在 `.text` 里找 3000–3010 的 `imm32`，用 `.pdata` 归函数，再解 `PropertyWrite_t` 批结构。
- 符号：`pyelftools` 读 `.dynsym`，两个 PICO 系统库的导出符号都在。
- arm64 交叉引用：`adrp` + `add/ldr` 配对还原目标地址。
