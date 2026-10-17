# 04.a · 兼容身份与输入声明

> 总览：[04 · PC 端 OpenVR 驱动](04-driver.md)。
> 状态：**部分已修**（`application_menu` 斜杠、头显 profile 漏发）；「游戏把我们当 Oculus Touch」这条兼容身份链仍是现状。
> 抄 v2 代码前的型号约定见 [04](04-driver.md) 的「v2 移植约定」；骨架级别怎么选见 [04.d](04_d-driver-skeleton.md)。

## 输入声明层：DP 只配了通用预设，且坐标与自己的图错位

profile 按 `controllertype` 二选一（`GetPrivateProfileIntW("PICO","controllertype",0,RVRPlugin.ini)`，本机 `=3`）：

| 项                                             | DP 驱动（`BusinessStreamingDP`，PC 端 1.2.11）                                                                                                    | v2 串流（`BusinessStreaming-v2.1.2` 的 `openvr_driver/`）                                     |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `controllertype=3` 加载的 profile              | `pico_controller_profile.json`（DLL 字符串表里 `pico_controller` 只认 `pico_controller_profile.json` / `pico_controller2_profile.json` 两个名字） | 按机型分：Neo 3 → `pico_neo3_controller_profile.json`（另有 phoenix / 4s）                    |
| 绑定 UI 图                                     | `icons/controller_left.svg` / `controller_right.svg`（**571×581**）                                                                               | `icons/neo3_left.svg` / `neo3_right.svg`（**90×166**）                                        |
| `remapping`                                    | 无                                                                                                                                                | `pico_controller_remapping.json`（`oculus_touch` → pico 自动重映射 + simulate 标志）          |
| 游戏自带默认绑定                               | 无（只带 vrcompositor 一条）                                                                                                                      | 8 个游戏（TWD / Pavlov / Propagation / Aircar / Moss / BeatSaber / Fallout4VR / VRSoloNobel） |
| `vrcompositor_bindings_pico.json` 的 `options` | `{}`                                                                                                                                              | `compatibility_mode` + `simulate_rendermodel` + `simulated_controller_type=oculus_touch`      |
| 状态图标目录                                   | `icons`、`icons_neo2`                                                                                                                             | 另有 `icons_neo3`、`icons_4s`、`icons_phoenix`、`icons_hand`                                  |

- `legacy_bindings_pico_controller.json`（12 处 `touch`）与 `legacy_bindings_pico_controller2.json` 在两边**逐字节相同** ⇒ 老游戏的 legacy 映射不是差异来源。
- `controllertype=3` → `pico_controller_profile.json`：`compatibility_mode_controller_type=oculus_touch`、`/input/joystick`；其它值 → `pico_controller2_profile.json`：`vive_controller`、`/input/trackpad`。
- **两代用的是互不配套的两套预设**：DP = 通用图 `icons/controller_left.svg`（571×581）+ 通用坐标；v2 = Neo 3 图 `icons/neo3_left.svg`（90×166）+ Neo 3 坐标，两套坐标没有一条相同。**实机现象（用户）**：DP 下 SteamVR「测试控制器」的高亮框错位。
- ⚠️ **离线渲染不能判定 SteamVR 里的实际对齐**：绑定界面 JS（`SteamVR\resources\webinterface\dashboard\controllerbindingui.js`）算的是「`binding_image_point` × `nPointScale`（= 显示高 / 图自然高）+ 图位置」，左手还要把 x 镜像（`S.x = ptController.x - S.x`）。照这套把 Valve 自带 Index profile 画到它自己的图上，点同样落在空白区 ⇒ 只能证明「DP 用的是一套与图不配套的通用预设」，算不出偏差量。
- 同一套画法（`artifacts/render_bindings.py`，8× + 每 10 单位网格）下，v2 的 neo3 坐标相对**它自己的图**也有约 20–27% 图高的系统性偏移，DP 那套比例相同 ⇒ **光换预设不保证高亮落对**，要落对得按图量坐标（`/input/joystick` 等点已可用该脚本逐点核对）。
- **实测（2026-10-16，用户实机）**：`/input/application_menu` 写对之后，SteamVR「测试控制器」里 **menu 键与 system 键都有反应**；此前 DP 下 menu 键无声 ⇒ 那条少斜杠的声明确实没被 SteamVR 认。⇒ 补斜杠已固化成 `patch_driver.ps1` 的一个行为。
- DP 的 `pico_controller_profile.json` 里 `"input/application_menu"` 少一个 `/`（厂商笔误），而同目录 `pico_controller2_profile.json` 里是写对的；v2 的 neo3 profile 则整条没有。
- SteamVR 侧另有一份兜底：`SteamVR\resources\input\default_pico_controller_profile.json`（`"is_stub": true`，`input_source` 与厂商 DP 那份**逐字一致**，连 `input/application_menu` 的笔误都照抄；另带 `simulation_settings.legacy_buttons=[0,1,2,7,32,33,34]`）与 `default_pico_controller_remapping.json`（khr_generic / `oculus_touch` / `knuckles` / `hand_interaction_ext` / `vive_controller` / `khr_simple` 的 simulate + autoremapping）。
- **“profile 没有 `remapping`”不能推出“app 不会模拟手柄”**。DP 当前加载的 `pico_controller_profile.json` 确实没有 `remapping`，但它引用的 `legacy_bindings_pico_controller.json` 末尾仍有 `options.simulated_controller_type = "oculus_touch"` 和 `options.simulate_rendermodel = true`。这条 legacy 选项本身就足以让只带 Oculus 绑定的老游戏进入模拟路径；它和 profile 的 remapping/autoremapping 是两层配置。
- **Alyx 的实际运行日志证明它走了这条路径**（2026-10-17 06:10:40）：`vrclient_hlvr.txt` 记录 `[Input] Loaded input profile for simulated controller type: oculus_touch`、`Loaded input profile for simulated hmd type: rift`，随后 `[Simulation] Setting device 0/1/2 with override properties`。所以此前“只是绑定翻译、不是模拟 Oculus Touch”的笔记结论过强，应改为“绑定页显示的是 Pico Controller，但 app 运行时仍可拿到 simulated `oculus_touch` 身份”。
- SteamVR 自带的 `default_pico_controller_profile.json` / `default_pico_controller_remapping.json` 也有 `simulate_*` 配置，但本轮不能只凭 stub 归因；当前能直接归因的是 DP legacy binding 的 `options` 和 Alyx 自己的运行日志。
- ⚠️ 因此**别随手挂上那份 remapping**：它的 oculus_touch autoremappings 只映射 grip / trigger / joystick / x / y / a / b（还有两处 `/user/hand/rgiht/...` 拼错、等于无效），**没有任何 touch 子输入** ⇒ 改成"模拟 Oculus Touch"很可能会把本项目刚补回来的触摸又丢掉。
- **Alyx 的手指动画走 `skeleton` 输入，不是 capsense 绑定**（实测它的 `bindings_touch.json`：`/user/hand/*/input/skeleton/*` → `/actions/default/in/HandSkeletonLeft|Right`，整份里**没有**任何 `touch` 条目；这里的 Touch 指 Oculus Touch 手柄）⇒ 本项目补的 capsense 要变成手指动作，得靠 SteamVR 自己**合成骨架**（DP 驱动原本没实现 skeleton ⇒ 骨架输出建不出来；2026-10-16 已把 v2 的实现整段搬进驱动，见 [04.d](04_d-driver-skeleton.md)）。VRChat 那套才是显式 `touch → gesture_activator_thumb/index/grip`，而 SteamVR 的自动重映射**不丢** touch（实测 `SteamVR\config\openxr\auto-remapping_{from,to}Binding.json` 只差一句 description）。
- SteamVR 的 stub profile 另有一整块 `simulation_settings`（`hmd_profile: rift`、模型号、`tracking_system_name: oculus`、`manufacturer_name: Oculus`、`legacy_buttons/axis`），厂商 profile 没有这块；同时 DP 的 legacy binding 还明确要求 `simulate_rendermodel=true`。两者共同说明 app 眼里的「Oculus Quest 2」来自兼容/模拟路径，但目前仍不能把某一块单独说成 9 cm 偏移的具体函数。**和手指问题要分开**：手序号修复解决了骨架镜像，不能据此排除模型挂接层。
- **profile 里没声明的输入，`CreateBooleanComponent` 静默失败、句柄留 0**（驱动从不检查返回值）
- `triggertest`（`RVRPlugin.ini` 的 `[PICO] triggertest=202`）是**死配置**：全二进制只有 1 处写、0 处读

### 资源差异与没人引用的变体（v2 vs DP）

- v2（`%LOCALAPPDATA%\PicoNeo2NvencCompat`）与 DP 逐文件比对：**OBJ 逐字节相同**；JSON 只差 `motion` 块。DP 少发：`pico_hmd_profile.json`、`pico_neo3_controller_profile.json`、8 份应用绑定、`pico_controller2_remapping.json`、`_joystick` / `_trackpad` 模型变体。**右手的合并网格两边都缺**。
- `pico_neo2_*_oculus.json` / `_vive.json` 与本体只差空白（`_vive` 那对换了 trackpad 语义），neo3 目录里没有这两份、DLL 里也没有这些后缀 ⇒ 没人引用。厂商留 `_oculus` 变体这件事说明他们知道「给 Oculus 用要改几何」，但没做。

## 试过、无效（且实验本身没生效）：删 profile 的 `compatibility_mode_controller_type`（2026-10-17）

现象：**SteamVR Home 里的手型跟 v2 不一样**（用户凭记忆说 v2 是"大白手"，也可能记错）；**把 `eSkeletalTrackingLevel` 从 2 改回 0 不变** ⇒ 级别不是这个开关（实机两次对比，2026-10-17）。

量到的事实：

- 以 app 身份（Scene 应用）读设备属性 = 一整套冒充的 Oculus：`ControllerType=oculus_touch`、`RenderModelName=oculus_quest2_controller_left`、`ModelNumber=Oculus Quest2 (Left Controller)`、`TrackingSystem=oculus`、`Manufacturer=Oculus`（用 `getStringTrackedDeviceProperty` 逐个属性读一遍即可；原一次性探针已删）。
- 但 Home 的客户端日志（`Steam\logs\vrclient_steamtours.txt`）显示它加载的**几何是 PICO 的**：`...\BusinessStreamingDP\driver\resources\rendermodels\pico_neo3_*controller\*.obj` —— 即"名字是 Oculus、几何是 PICO"（与 [04.e](04_e-driver-offset.md) 的日志对照一致）。

**试过的改动**：删掉 `resources\input\pico_controller_profile.json` 里的 `"compatibility_mode_controller_type": "oculus_touch",`（OpenVR 文档 _Binding Duplication_：找不到 app 绑定时会用被模拟设备的 profile **并设置模拟属性**）⇒ **实测：Home 手型不变、游戏里 ≈9cm 偏移也不变**。

- ⚠️ **这个实验不能归因到 profile 那一行**：改完后 Home 的日志里仍然是 `[Input] Loaded input profile for simulated controller type: oculus_touch`；DP legacy binding 自己就带 `simulate_rendermodel=true` 和 `simulated_controller_type=oculus_touch`，所以不能只把原因归给 SteamVR 的兜底 remapping。
- 当前只缺真实游戏画面对照：OpenVR 属性层已经确认 `simulate_rendermodel=false` 不会自动去掉 Oculus 兼容身份，而 `simulated_controller_type=none` 会去掉它。由于 `none` 会改变 Alyx 的绑定身份，不能直接作为补丁方案；`patch_driver.ps1` 仍不碰这两个兼容选项。
- 用户 2026-10-17 决定：**先不追**（手型差异无伤大雅），偏移另行调查。`patch_driver.ps1` **不**碰这一行；本机实验后已用一次性脚本把那一行改回（该行缩进目前是 4 空格而非厂商的 2 空格，JSON 等价，下次打补丁时可顺手对齐）。

## 头显 profile 漏发（已修）

```text
vrserver.txt  [Error] [Controller Setup] Failed to load input profile for device:
              Unable to read device input profile from {pico}/input/pico_hmd_profile.json
```

- DP 驱动每次启动都在找 `{pico}/input/pico_hmd_profile.json`，但包里没有 ⇒ 头显 profile 加载失败。v2 自带这份（纯 HMD profile，**没有** `simulation_settings`，引用 `{pico}/icons/headset.svg`）；DP 连 `headset.svg` 都没有 ⇒ `patch_driver.ps1` 生成时去掉图标引用。补上之后报错消失（但 `[Simulation] … for rift` 依旧 ⇒ 冒充来自 stub，与这份 profile 无关）。
