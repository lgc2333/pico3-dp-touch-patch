# 04.c · 触摸补丁与键值字

> 总览：[04 · PC 端 OpenVR 驱动](04-driver.md)。
> 状态：**已应用**（本机打过，SteamVR「测试控制器」逐键验过）。

## 补丁（15 字节，零长度变化）

`/input/trigger/touch` ← 键值字 **bit5**；`/input/joystick/touch` ← 键值字 **bit7**；
厂商遗留的调试打印 `kTriggerTouch` ← 恒跳过（原版 DLL 就有：`sub_180019580` 里 `test sil,40h / jz / lea+call`，
bit6 置位时每个输入更新打一行 ⇒ DP 直连下按住扳机 ~200 Hz 刷 SteamVR Console 与 `vrserver.txt`）

| RVA           | 文件偏移  | 原字节                 | 新字节                 | 汇编                              |
| ------------- | --------- | ---------------------- | ---------------------- | --------------------------------- |
| `0x1800197b8` | `0x18bb8` | `0f 57 db 41 0f 95 c0` | `41 88 f0 41 80 e0 20` | `mov r8b,sil` / `and r8b,0x20`    |
| `0x18001986f` | `0x18c6f` | `74 0c`                | `eb 0c`                | `jz` → `jmp`（跳过 `lea`+`call`） |
| `0x18001991d` | `0x18d1d` | `0f 57 db`             | `41 88 f0`             | `mov r8b,sil`                     |
| `0x180019927` | `0x18d27` | `45 0f b6 c7`          | `41 80 e0 80`          | `and r8b,0x80`                    |

- 两处 `xorps xmm3,xmm3`（ABI 卫生，`UpdateBoolean` 无浮点参数）被安全占用
- 中间的 `mov rdx,[rdi+...]` 不改 r8b / 不改标志位，顺序无碍
- 假设 `IVRDriverInput::UpdateBoolean(handle, bool)` 对「非零」判真（0x20/0x80 即真）——**实测有效**
- `kTriggerTouch` 那处跳过的是 `lea rcx,str` + `call`，两行只写 `rcx`，而紧随其后的 `mov ecx, cs:dword_18009B100` 会覆盖它 ⇒ 跳过去无副作用

应用：`src\windows\patch_driver.ps1`（管理员 + 已退出 SteamVR；**Steam 客户端也会把这个 DLL 映射进自己进程**，占着就写不进去 —— 实测 `steam.exe` 会，且 `tasklist /m` 列不出来、得提权看 `Get-Process | %{ $_.Modules }`），自动备份 + 逐字节校验 + 复核；同一脚本还会把 profile 里 `input/application_menu` 的斜杠补上（见 [04](04-driver.md) 的「预设整体搬迁」），备份为 `pico_controller_profile.json.orig`。
还原：把 `driver_pico.dll.orig`（md5 `9017439d…`）复制回 `driver_pico.dll`；profile 那条则把 `.orig` 复制回去。

## 键值字位占用总表

| 位     | 用途                   | 来源                     |
| ------ | ---------------------- | ------------------------ |
| 0      | A/X click              | 头显原有                 |
| **1**  | **A/X 电容触摸**       | 本项目新增               |
| 2      | B/Y click              | 头显原有                 |
| **3**  | **B/Y 电容触摸**       | 本项目新增               |
| 4      | 摇杆 click             | 头显原有                 |
| **5**  | **扳机电容触摸**       | 本项目新增（需驱动补丁） |
| 6      | 扳机 click             | 头显原有（只喂厂商日志） |
| **7**  | **摇杆顶电容触摸**     | 本项目新增（需驱动补丁） |
| 8–11   | 空闲                   | —                        |
| 12     | system click           | 头显原有                 |
| 13     | application_menu click | 头显原有                 |
| 14, 15 | 空闲                   | —                        |

## 两代串流的「系统键」路由不同（实测）

- **网络串流**：头显 app 自己打包那份 32 位掩码，谁当 `system` 由它决定（掩码 bit9），PICO 键由头显系统吃掉、根本不下发 ⇒ 用户按到的是 menu 键当 SteamVR 系统键。
- **DP 直连**：`pxrstreamingservice` 直接发 HID 键值字、路由固定 ⇒ 左手 PICO 键 = bit12 = `/input/system/click`（SteamVR 里呼出 dashboard 的就是它），menu 键 = bit13 = `/input/application_menu/click`。
- bit13 头显**确实发**（`02` 的按钮巡回实测 `report[49] = 0x20`），驱动也确实写这个组件（`sub_180019580` 开头）；到不到游戏取决于 profile 有没有把这条输入建出来、以及游戏有没有绑它 —— Alyx / VRChat / The Lab 的绑定都引用了 `/user/hand/*/input/application_menu`。
- 自证（SteamVR 已启动、DP 已连）：`uv run python docs/notes/artifacts/ovrread.py 60`，按 menu 键看 `AppMenu(1)`、按 PICO 键看 `System(0)` 是否出现在 `ulButtonPressed`。

> 为什么 A/X、B/Y 的触摸不需要补丁（驱动早就读了 bit1 / bit3）：见 [04.b](04_b-driver-binary.md) 的「关键结论」。
