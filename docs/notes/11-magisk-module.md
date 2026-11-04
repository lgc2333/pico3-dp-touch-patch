# 11 · Magisk 模块：无 Frida 的永久注入

> 有永久 root 后（见 [10-permanent-root.md](10-permanent-root.md)），头显侧不再需要每次跑 frida-inject。模块在 [src/magisk](../../src/magisk/)。
> 状态：设计与构建已落地；真机验证待做（见文末）。

## 为什么不选 Xposed

目标进程是 /system/bin/pxrstreamingservice：init 起的 native 服务（SELinux 域 u:r:pxrstreamingservice:s0），没有 ART。Xposed / LSPosed 只覆盖 zygote 派生的 Java 进程，进不去。

## 为什么不用 LD_PRELOAD

init 的 wrap.<service> 通道在 Android 10 **不存在**（system/core/init/service.cpp 里没有 wrap. 字符串）⇒ 只能从库文件本身入手。

## 做法

1. 给 libpxrstreamingservice.so 补一条 DT_NEEDED: picotouch_shim.so，加载器就会把 shim 带进进程。
   - 原 .dynamic 没有空槽（43 个全满）⇒ 脚本新建 dynstr + dynamic 放到文件尾，再扩最后一个 PT_LOAD（[inject_needed.py](../../src/magisk/tools/inject_needed.py)）。
2. 模块 magic mount 覆盖 /system/lib64/ 下的 libpxrstreamingservice.so 与 picotouch_shim.so。
3. shim（[picotouch_shim.c](../../src/magisk/shim/picotouch_shim.c)）的 constructor 只改 GOT。两个偏移都已用 `llvm-readobj --relocations` 核实为 `R_AARCH64_JUMP_SLOT`（GOT 槽，不是函数首字节）：
   - libpxrstreamingservice.so：`__write_chk` 的 GOT 槽 `+0x204C0` ⇒ 在报文 `+49` 写触摸位
   - libpxrcontrollerclient.pxr.so：`ControllerManager::GetKeyData` 的 GOT 槽 `+0x31B50` ⇒ 读 `+0`（手）、`+32/+36/+40/+44`
   - 只 mprotect 数据页再写指针，**不碰代码页** ⇒ 不用 execmem / execmod，SELinux 保持 enforcing。

## 实测（本机库）

| 事实        | 值                                                                                         |
| ----------- | ------------------------------------------------------------------------------------------ |
| 报文写出口  | `__write_chk@plt`，参数 (fd, buf, 0x40, 0x40)                                              |
| 键值来源    | GetControllerKeyData 内 bl GetKeyData@plt                                                  |
| 库符号      | libpxrstreamingservice.so 已 strip，只能按偏移                                             |
| 服务启动    | class core、user root、u:r:pxrstreamingservice:s0                                          |
| 原库 sha256 | 见 [vendor_lib.sha256](../../src/magisk/tools/vendor_lib.sha256)（值只此一处，脚本都读它） |

> ⚠️ 写侧是 **64 字节**（不是 hook.js 里的 63，那是 hidWrite 的入参长度）。shim 在 64 字节报文上用同样的 `+49` 偏移；报文头布局待真机复核。

## 固件闸门

两处各自把关，任一不符即中止，别放宽：

| 位置                                                               | 判据                                                                                             | 不符时   |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ | -------- |
| 设备端 [customize.sh](../../src/magisk/customize.sh)               | `ro.pvr.internal.version`（或 `settings get system confirm_smartisan_version`）含 `202409100313` | 中止安装 |
| 打包端 [build_module.ps1](../../src/magisk/tools/build_module.ps1) | 原厂库 sha256 = [vendor_lib.sha256](../../src/magisk/tools/vendor_lib.sha256)                    | 中止打包 |

设备端**刻意不校验库的 sha256**：模块装过一次后该路径已被模块挂载覆盖，覆盖安装时读到的是补过的库，用 sha256 判会把任何固件都放过去（旧实现就是这么错的）。固件属性不被模块覆盖，所以能一直判准。

## 构建与打包

```sh
pnpm build:magisk                                    # Windows；等价于 powershell -File src/magisk/tools/build_module.ps1
pwsh -File src/magisk/tools/build_module.ps1         # pwsh 7 / Linux CI
# 要指定 NDK 就加 -Ndk <路径>
```

- 入库的只有原厂库 `src/magisk/tools/resources/libpxrstreamingservice.so`（PUI 5.9.9-202409100313）。
- 补丁库与 shim 都是构建产物，**不入库**：前者每次用 [inject_needed.py](../../src/magisk/tools/inject_needed.py) 从原厂库现场补，后者用 NDK 编译。
- NDK 只在要编译 shim 时才需要（shim 缺失，或比 `picotouch_shim.c` 旧）；路径依次取 `-Ndk` → `ANDROID_NDK_HOME` → `ANDROID_HOME`/`ANDROID_SDK_ROOT`/`%LOCALAPPDATA%\Android\Sdk` 下 `ndk/` 的最新一版。
- 产物：`temp/magisk/pico_dp_touch.zip`（文件名跟 `module.prop` 的 id 一致）。
- 跨平台：脚本按 `$IsWindows`/`$IsMacOS` 选 NDK 的 `prebuilt/<平台>/bin`，PS 5.1 与 pwsh 7 都验过。Linux CI 里除了 `pwsh` 还要有 `uv` 与 NDK。
- CI：`.github/workflows/build-magisk-module.yml` 手动触发，ubuntu-latest 上装 uv 与 NDK 后跑同一个脚本，zip 以 artifact 上传。

## 验证（真机）

```sh
adb logcat -s picotouch
# 期望两行：hid write hooked / controller client hooked
```

再用 [hidcap.py](artifacts/hidcap.py) 抓 HID：report[50] 出现 0x02/0x08/0x20/0x80。

## 回滚

管理器里关模块并重启；或删掉模块目录。[hook.js](../../src/shared/hook.js) 方案保持原样，可随时回到 Frida。
