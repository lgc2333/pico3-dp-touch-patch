# 08 · 走过的死路与原因（保留为 facts）

> 这些不是「猜测」，都是实测/查证过的结论。记下来免得以后重走。

## 一、改 APK 后覆盖安装 —— 不可行

**签名实证**（两版 APK 同证书）：

| APK                                           | 签名条目                | 证书                                             |
| --------------------------------------------- | ----------------------- | ------------------------------------------------ |
| `/data/app/.../base.apk` (1.2.10)             | `META-INF/PLATFORM.RSA` | `CN=AndroidTeam, OU=SW, O=Pico, L=Beijing, C=CN` |
| `/system/app/BStreamingAssistant.apk` (1.2.0) | `META-INF/CERT.RSA`     | 同一张证书                                       |

SHA-256 `dc30289e0a61447d03c95d15e5acf63e18d109d545a766b1208f6b53cbdcd482`，
序列号 `0xd59edf6f80d89d86`。与 AOSP `testkey`/`platform`/`shared`/`media`/`networkstack`
**逐个比对全不匹配** ⇒ 私钥拿不到 ⇒ 无法同密钥重签 ⇒ `pm install -r` 必报
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`。

**开机扫描也会校验**：`/system/framework/services.jar` 内实测存在字符串
`signatures do not match previously installed version; ignoring!`
⇒ 「直接换 `/data/app/.../base.apk` 文件」在开机扫描会被判签名不符，包被忽略
（`UPDATED_SYSTEM_APP` 会退回预装 v1.2.0，数据目录保留）。

| 绕签名方案                                  | 结论                                    |
| ------------------------------------------- | --------------------------------------- |
| ① 同密钥重签                                | **不可行**（私钥拿不到，已证）          |
| ② 直接换 APK 文件                           | 低风险但**掉回 v1.2.0**                 |
| ③ ②+改 `/data/system/packages.xml` 证书记录 | 中风险（改错 → 包丢失/开机异常）        |
| ④ patch `services.jar` 关签名校验           | **高风险**（单槽无 A/B，bootloop 难救） |

**⇒ 而且根本不需要**：`extractNativeLibs=true`，native 库已解包在
`/data/app/.../lib/arm64/`，进程实测 mmap 的就是它们 ⇒ 改 native 直接换 `.so` 即可。
**但最终连 `.so` 也没改** —— 因为报文不由 app 组装（见 `03`）。

## 二、CorePatch / InstallerX Revived —— 不可行

| 方案                   | 结论      | 依据                                                                                                                                                                    |
| ---------------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **CorePatch**          | ❌ 装不上 | 它是 **Xposed 模块**（要求 libxposed API 101）。设备实测**无 Magisk**（`/data/adb` 空、无 `magiskd`、无 `modules`、无 Xposed 属性、zygote 未 hook）。                   |
| **InstallerX Revived** | ❌ 做不到 | 它只是**安装器前端**（root/Shizuku 提权跑 `pm`）。签名校验发生在 **system_server** 内部，前端改不了。其 README 原话：要替换系统包管理器/绕签名 → **"use Core Patch"**。 |

## 三、Magisk / KernelSU「越狱模式」—— 硬约束挡住

**KernelSU 越狱模式机制**（`tiann/KernelSU` commit `b98c05e feat: jailbreak by Magica (#3268)`，2026-03-12）：

```
漏洞拿临时 root + SELinux permissive
  → 管理器点「越狱」→ ksud late-load --magica 5555
  → ksuinit::load_module(&ko_data)     // insmod 一个 KMI 专用的 kernelsu.ko
  → KernelSU 激活（自动恢复 SELinux enforcing）
  → 装 Zygisk Next + LSPosed → CorePatch
```

官方文档明确：**每一次重启都要重做**（不持久）。

**在本机不可行**（实测）：

```
/proc/config.gz:
  CONFIG_MODVERSIONS=y          ← 符号 CRC 必须与内核编译时逐位一致
  CONFIG_MODULE_SIG=y
  CONFIG_MODULE_SIG_FORCE=y     ← 强制签名，未签名模块直接拒绝
  CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"

/sys/module/module/parameters/sig_enforce = Y   （-rw-r--r--，写入 0 → 被拒）
```

- `CONFIG_MODULE_SIG_FORCE=y` ⇒ `sig_enforce` **只读** ⇒ 未签名 `.ko` 一律拒载
- `CONFIG_MODVERSIONS=y` ⇒ 符号 CRC 必须匹配，要拿 PICO 内核源码 + 同 config + 同 clang(8.0.12) 重编
- **非 GKI**（`kona` / Qualcomm msm-4.19 定制）⇒ 没有现成 KMI 的 `kernelsu.ko`
- 内核签名私钥拿不到
- 官方警告：越狱模式下刷分区会破 AVB，**锁 BL 设备可能无法开机**

（理论上可用 picohaxx 的 `KERNEL_DS` 改内核内存里的 `sig_enforce`，
但**仍需 modversions 匹配的 `.ko`**，死结不变。）

## 四、改 `/system` / `boot` —— 硬砖级

```
ro.boot.veritymode        = enforcing   ← dm-verity 强制校验
ro.boot.flash.locked      = 1           ← Bootloader 已锁
ro.boot.vbmeta.device_state = locked
ro.boot.slot_suffix       = (空)        ← 单槽，无 A/B 回退
ro.boot.dynamic_partitions = true
mount: /dev/block/dm-6 on /vendor (ro)
```

- 装 Magisk 要改 `boot` → 锁 BL + AVB 校验 → 拒启
- 静态 patch `services.jar` → verity enforcing → 改完直接无法开机
- **单槽** ⇒ 砖了没有回退

⇒ 改 `boot` / `/system` 一律是**硬砖级**风险，彻底排除。

## 五、官方「注入键值」通道 —— 本机没开

`libpxrcontrollerclient.pxr.so` 导出了 `InjectKeyValue` / `injectKeyValue` /
`combineWithInjectKeyData` / `SetControllerKeyState` 等（详见 `03`），
`GetControllerKeyData` 会自动调用 `combineWithInjectKeyData` 合并注入值。

**实测：`getShareMemory` 失败，函数返回 `-2`** ⇒ 控制器服务没开这条通道 ⇒ 用不了。

## 六、最终为什么选「Frida hook + 驱动补丁」

| 约束                          | 结论                                         |
| ----------------------------- | -------------------------------------------- |
| 改 APK / 签名                 | ❌（一、二）                                 |
| 装 Magisk / KernelSU / Xposed | ❌（三、四）                                 |
| 改 `/system`                  | ❌ 硬砖（四）                                |
| 官方注入通道                  | ❌ 本机没开（五）                            |
| **root + 进程内 hook**        | ✅ **可行**（picohaxx 纯内核提权，不碰分区） |
| **PC 驱动补丁**               | ✅ 14 字节，可备份可还原                     |

⇒ 唯一零砖风险的组合：**临时 root + `frida-inject` 进程内 hook + 驱动 14 字节补丁**。
