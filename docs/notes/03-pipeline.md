# 03 · 完整链路：从触摸传感器到 HID 报文

## 进程与库（实测 `/proc/*/fd` + `/proc/*/maps`）

```
PID 1388  /system/bin/pxrstreamingservice        (root)  fd=23 → /dev/hidg0   ← 写 HID
   /system/lib64/libpxrstreamingservice.so                 ← 报文组装 + hidWrite
   /system/lib64/libpxrcontrollerclient.pxr.so             ← GetControllerKeyData（键值来源）

PID 2959  com.picoxr.bstreamassistant
   /data/app/.../lib/arm64/libpicolink_dp.so               ← 只有 JNI 壳
PID 2990  com.picoxr.bstreamassistant:picoStream
   /data/app/.../lib/arm64/libnative-lib.so                ← 控制器轮询（Pxr SDK）
   /system/lib64/libpxrstreamingserviceclient.so           ← binder 到服务
```

**只有 `pxrstreamingservice` 打开 `/dev/hidg0`** —— 它是 root 系统服务，库全在 `/system`。

## 报文组装点

`PXR::PxrStreamingService::HidIOThread::threadLoop` @ `0xc6e4`：

```c
buf = *(this+18) + 164;                          // 63 字节报告体
*(_OWORD *)(buf + 47) = *(_OWORD *)&v190[15];    // buf[47..62]
*(_OWORD *)(buf + 32) = *(_OWORD *)v190;         // buf[32..47]
*(_OWORD *)(buf + 16) = *(_OWORD *)&v189[16];    // buf[16..31]
*(_OWORD *)(buf +  0) = *(_OWORD *)v189;         // buf[0..15]
PXR::HidIOListener::hidWrite(mutex, buf, 63);
```

键值字由 `PXR::PxrStreamingServiceCore::getControllerTrackingRawData(..., a8: &v190[16], ...)` 写入
→ 内部调用 `getControllerKeyData`（`dlopen` 自 `libpxrcontrollerclient.pxr.so`）。

## 触摸数据源：`controller_data_t`

`PvrContorlServiceClient::GetControllerKeyData(controller_data_t* a2)`：

```c
KeyData = ControllerManager::GetKeyData(sInstance, *(a1+176), a2);
combineWithInjectKeyData(a1, a2);        // 尝试合并「注入键值」（本机不可用，见下）
return KeyData;
```

`controller_data_t`（64 字节，`+0` = hand：1=左 / 2=右）—— **实测字节映射**：

| 偏移        | 含义               | 备注              |
| ----------- | ------------------ | ----------------- |
| `+0`        | hand               | 1 = 左，2 = 右    |
| `+12`       | A/X click          | → HID 键值字 bit0 |
| **`+32`**   | **A / X 电容触摸** |                   |
| **`+36`**   | **B / Y 电容触摸** |                   |
| **`+40`**   | **摇杆顶电容触摸** |                   |
| **`+44`**   | **扳机电容触摸**   |                   |
| `+50`,`+51` | 摇杆 X/Y           | 中位 = 128        |
| `+54`,`+55` | 扳机 / grip 模拟量 |                   |

### 实测时间线（Frida hook `GetControllerKeyData`，用户按序 hover）

```
 15.24  hand=2  +32=1     ← ① hover A
 23.24  hand=2  +36=1     ← ② hover B
 29.31  hand=1  +36=1     ← ③ hover Y
 35.22  hand=2  +44=1  /  42.37  hand=1  +44=1     ← ④ hover 扳机
 47.72  hand=2  +40=1  /  52.40  hand=1  +40=1     ← ⑤ hover 摇杆顶
```

HID 报文同步验证：`report[50] = 0x01`（bit0）出现在 **t=12.61..26.07**，
与 `+12` 的窗口**逐帧吻合** ⇒ 键值字位置与位义完全确认。

> ⚠️ 更早一次巡回（用户自选顺序）给出的 `+40`/`+44` 对应关系与此相反，**以本表为准**。

## app 侧是死代码（jadx 全量验证）

`libpicolink_dp.so`：

```c
Java_..._DPJniInterface_writeHIDData(env, thiz, jstring data) {
    byte[] b = data.getBytes("GB2312");
    ...
    StreamServiceClient::writeHIDData(client, buf, 8);   // → PXRModule->writeHIDData
}
```

- `DPJniInterface.writeHIDData(String)` 只被 `DPManager.writeHIDData(String)` 调用
- **`DPManager.writeHIDData` 在 1.2.10 的 dex 里没有任何调用者**
- `libnative-lib.so` 里没有 `DPManager` / `picolink/DP` / `(Ljava/lang/String;)I` 任何痕迹

⇒ 改 app 的 native 库**改不到报文**（报文不由 app 组装）。

## 官方「注入键值」通道（本机不可用，记录为 fact）

`libpxrcontrollerclient.pxr.so` 导出了一套键值注入 API：

| 符号                                                                         | 地址（基址内） |
| ---------------------------------------------------------------------------- | -------------- |
| `InjectKeyValue`                                                             | `0x21f3c`      |
| `PvrContorlServiceClient::injectKeyValue(uint8 hand, char key, uint8 value)` | `0x212d4`      |
| `PvrContorlServiceClient::combineWithInjectKeyData(controller_data_t*)`      | `0x1f61c`      |
| `PvrContorlServiceClient::GetControllerKeyData(controller_data_t*)`          | `0x1f5c4`      |
| `PvrContorlServiceClient::getControllerKeyDataEx(controller_data_ex_t*)`     | `0x206a0`      |
| `ControllerManager::GetControllerKeyState(key_state_t*)`                     | `0x22eb8`      |
| `ControllerManager::SetControllerKeyState(int,int)`                          | `0x22e9c`      |

`combineWithInjectKeyData` 会从控制器服务的共享内存取每只手 112 字节的条目，
按「`!=0` 才覆盖」的规则合并进 `controller_data_t`（`+52/+53` 为 u8，`+54/+55` 以 128 为中位）。

**实测：`getShareMemory` 失败，函数返回 `-2`** ⇒ 本机的控制器服务没开这条通道 ⇒ 用不了。

## 结论

1. HID 报文由 `/system/bin/pxrstreamingservice`(root) 组装并写 `/dev/hidg0`，
   app 完全不参与 ⇒ **改 APK / 改 app 的 `.so` 无法让报文带上触摸**
2. `/system` 改不了（verity enforcing + 锁 BL + 单槽，见 `08`）
3. 触摸数据**存在于控制器服务**，且 `GetControllerKeyData` 在**同一个进程**里就能读到
   ⇒ 用 Frida 在进程内把两端接起来即可（见 `05`）
