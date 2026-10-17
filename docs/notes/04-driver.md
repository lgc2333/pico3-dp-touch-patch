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

已注册的外部驱动（`%LOCALAPPDATA%\openvr\openvrpaths.vrpath`）只有一条，跟着最后跑的模式走：无线 = `BusinessStreamingUW\driver`，DP = `BusinessStreamingDP\driver`（实测当前是后者）。

另有 v2 串流（`BusinessStreaming-v2.1.2-win32-x64.exe`，Electron）：驱动在 `<安装目录>\app\openvr_driver\`，**没有 DP 模式**；两代资源差异见下面「输入声明层」。

### md5

| 文件                                                 | md5                                |
| ---------------------------------------------------- | ---------------------------------- |
| DP `driver\bin\win64\driver_pico.dll` **原始**       | `9017439d560747678b4550fcf6726808` |
| DP 根目录 `driver_pico.dll`（废弃副本）              | `3e411eda6ab7ce0785abb12ef39af9a6` |
| UW `driver\bin\win64\driver_pico.dll`                | `f61949bf7afb4809eaa02daa18be7995` |
| v2.1.2 `app\openvr_driver\bin\win64\driver_pico.dll` | `e6d408b2590042c3c7f796b694ffc404` |

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
- **实测（2026-10-16，用户实机）**：`/input/application_menu` 写对之后，SteamVR「测试控制器」里 **menu 键与 system 键都有反应**；此前 DP 下 menu 键无声 ⇒ 那条少斜杠的声明确实没被 SteamVR 认。⇒ 补斜杠已固化成 `patch_driver.ps1` 的一个行为（见下）。
- DP 的 `pico_controller_profile.json` 里 `"input/application_menu"` 少一个 `/`（厂商笔误），而同目录 `pico_controller2_profile.json` 里是写对的；v2 的 neo3 profile 则整条没有。
- SteamVR 侧另有一份兜底：`SteamVR\resources\input\default_pico_controller_profile.json`（`"is_stub": true`，`input_source` 与厂商 DP 那份**逐字一致**，连 `input/application_menu` 的笔误都照抄；另带 `simulation_settings.legacy_buttons=[0,1,2,7,32,33,34]`）与 `default_pico_controller_remapping.json`（khr_generic / `oculus_touch` / `knuckles` / `hand_interaction_ext` / `vive_controller` / `khr_simple` 的 simulate + autoremapping）。
- **“profile 没有 `remapping`”不能推出“app 不会模拟手柄”**。DP 当前加载的 `pico_controller_profile.json` 确实没有 `remapping`，但它引用的 `legacy_bindings_pico_controller.json` 末尾仍有 `options.simulated_controller_type = "oculus_touch"` 和 `options.simulate_rendermodel = true`。这条 legacy 选项本身就足以让只带 Oculus 绑定的老游戏进入模拟路径；它和 profile 的 remapping/autoremapping 是两层配置。
- **Alyx 的实际运行日志证明它走了这条路径**（2026-10-17 06:10:40）：`vrclient_hlvr.txt` 记录 `[Input] Loaded input profile for simulated controller type: oculus_touch`、`Loaded input profile for simulated hmd type: rift`，随后 `[Simulation] Setting device 0/1/2 with override properties`。所以此前“只是绑定翻译、不是模拟 Oculus Touch”的笔记结论过强，应改为“绑定页显示的是 Pico Controller，但 app 运行时仍可拿到 simulated `oculus_touch` 身份”。
- SteamVR 自带的 `default_pico_controller_profile.json` / `default_pico_controller_remapping.json` 也有 `simulate_*` 配置，但本轮不能只凭 stub 归因；当前能直接归因的是 DP legacy binding 的 `options` 和 Alyx 自己的运行日志。
- ⚠️ 因此**别随手挂上那份 remapping**：它的 oculus_touch autoremappings 只映射 grip / trigger / joystick / x / y / a / b（还有两处 `/user/hand/rgiht/...` 拼错、等于无效），**没有任何 touch 子输入** ⇒ 改成"模拟 Oculus Touch"很可能会把本项目刚补回来的触摸又丢掉。
- **Alyx 的手指动画走 `skeleton` 输入，不是 capsense 绑定**（实测它的 `bindings_touch.json`：`/user/hand/*/input/skeleton/*` → `/actions/default/in/HandSkeletonLeft|Right`，整份里**没有**任何 `touch` 条目；这里的 Touch 指 Oculus Touch 手柄）⇒ 本项目补的 capsense 要变成手指动作，得靠 SteamVR 自己**合成骨架**（DP 驱动原本没实现 skeleton ⇒ 骨架输出建不出来；2026-10-16 已把 v2 的实现整段搬进驱动，见下面「骨架 / pose 补丁」）。VRChat 那套才是显式 `touch → gesture_activator_thumb/index/grip`，而 SteamVR 的自动重映射**不丢** touch（实测 `SteamVR\config\openxr\auto-remapping_{from,to}Binding.json` 只差一句 description）。
- SteamVR 的 stub profile 另有一整块 `simulation_settings`（`hmd_profile: rift`、模型号、`tracking_system_name: oculus`、`manufacturer_name: Oculus`、`legacy_buttons/axis`），厂商 profile 没有这块；同时 DP 的 legacy binding 还明确要求 `simulate_rendermodel=true`。两者共同说明 app 眼里的「Oculus Quest 2」来自兼容/模拟路径，但目前仍不能把某一块单独说成 9 cm 偏移的具体函数。**和手指问题要分开**：手序号修复解决了骨架镜像，不能据此排除模型挂接层。
- **profile 里没声明的输入，`CreateBooleanComponent` 静默失败、句柄留 0**（驱动从不检查返回值）
- `triggertest`（`RVRPlugin.ini` 的 `[PICO] triggertest=202`）是**死配置**：全二进制只有 1 处写、0 处读

### ⚠️ 移植前必读：v2 的「型号 × 形态」矩阵（踩过坑，2026-10-17）

v2 支持 4 种控制器 + 每种还有「手柄 / 手部追踪」两种形态，**同一个标志位往往同时决定"设备对外是什么"和"驱动行为"** ⇒ 别看一条分支就抄常量。已确认的分支：

- `sub_180016110(this, type)`（型号选择，`*(this+16) = type`）：

  | type | 设备                                | `controller_type` | profile                                             |
  | ---- | ----------------------------------- | ----------------- | --------------------------------------------------- |
  | 1    | Pico Neo2 手柄                      | `oculus_touch`    | `{oculus}/input/touch_profile.json`                 |
  | 2    | **Pico Neo3 手柄**（DP 直连是这类） | `pico_controller` | `{pico}/input/pico_neo3_controller_profile.json`    |
  | 3    | PICO 4（"phoenix"）                 | `pico_controller` | `{pico}/input/pico_phoenix_controller_profile.json` |
  | 4    | PICO 4S                             | `pico_controller` | 同上（图标换 `icons_4s/`）                          |

  DP 只发了通用的 `pico_controller_profile.json` / `pico_controller2_profile.json`，**没有** neo3 / phoenix 这两份（v2 有）。

- **`*(this+0x2E0)` = 「手部追踪形态」开关**：同一个函数里它把型号名从 `Pico Neo3 / PICO 4 Controller left|right` 改成 **`Pico Hand left|right`**；而组件创建（`sub_180012EC0`）用它决定 `eSkeletalTrackingLevel`：**0（手柄）/ 2（Pico Hand）**。⇒ 我们搬骨架时把 level 硬编码成 2 就是**只看了"手部追踪"那条分支**，实机代价是 SteamVR Home 里的手型与 v2 不一致（Alyx 不受影响）。
- 手序号同样是"约定"而不是自然数：v2 用 **1 = 左 / 2 = 右**（更新器只判 `== 1`），DP 的控制器对象用 **0 = 左 / 1 = 右** ⇒ 直接照搬会让两只手拿到对方的镜像姿势（见「真凶」一节）。
- **教训**：移植任何常量 / 分支前，先问三句 —— ① 这段代码在哪个型号分支上？② 这个标志位还有别的用途吗（会不会同时改设备身份）？③ 我这边（DP / Neo 3 / 手柄形态）落在哪一支？

### 预设整体搬迁：试过、已回滚（现在只补 application_menu）

2026-10-16 试过把 v2 的 Neo 3 预设整套搬到 DP（13 个文件：2 个 profile + 2 个绑定界面图 + 8 个游戏默认绑定 + compositor 绑定），实机验证后**整体回滚**，因为方向还没定；只有一条确定有益的改动留下来，进了 `patch_driver.ps1`：

- **保留**：`pico_controller_profile.json` 里 `"input/application_menu"` → `"/input/application_menu"`（补斜杠）。备份为同目录 `.orig`，已经是正确写法时跳过。
- **回滚了**：换 Neo 3 图/坐标、8 个游戏默认绑定、v2 的 compositor 绑定。现场已按 `resources.orig` + 删除新增文件还原（`input` 6 个 / `icons` 69 个 / 树内 212 个文件，与厂商安装时一致）。

如果以后要做整套搬迁，要点（当时验证过的）：

1. v2 的 neo3 profile **没有** `/input/application_menu`，整份照抄会把这条声明删掉 ⇒ 必须自己补一条（坐标借 `pico_neo3_controller2_profile.json` 的 `[45, 50]`）；它自带 8 个游戏默认绑定 + `vrcompositor` 绑定，不用另补。
2. `pico_neo3_*` 要**改名**成 DP 的 DLL 实际会加载的 `pico_controller_profile.json` / `pico_controller2_profile.json`（DP 的 DLL 只认这两个名字）；`controller_type` 必须仍是 `pico_controller`。
3. `remapping` 不加（SteamVR 自带 `default_pico_controller_remapping.json`）；非要加就见下一条的坑。
4. 搬之前一定留全量备份，并记下"哪些是新增文件"—— 只按"备份里没有就删"还原会误删厂商原有文件（实测踩过：`controller_left.svg` / `controller_right.svg` / `headset.svg` 被一起删了，靠打预设前的整体副本才救回来）。

- SteamVR 按应用缓存绑定（`%LOCALAPPDATA%\openvr\`）：改完没变化时先在绑定界面点「恢复默认绑定」，或清掉该应用的缓存绑定。

## 渲染模型层：早期假设与排除记录（**结论与此层无关**，见文末「根因」）

现象：SteamVR 自己的面板 / 系统场景里位置正常；进入 Scene app 后，SteamVR 的等待画面和 VRChat 游戏内都出现同一方向的偏移。用户描述为两只手柄沿各自柄身朝追踪环方向偏约 9 cm：追踪环在现实中相碰时，游戏模型会互相陷入；柄尾相碰时，游戏模型之间会出现空隙。打开 SteamVR 面板时又恢复正常。

目前可以确认的事实：

- **Scene app 会进入兼容身份**：设备属性表现为 `TrackingSystem=oculus`、`Manufacturer=Oculus`、`ModelNumber=Oculus Quest2 (Left Controller)`、`RenderModelName=oculus_quest2_controller_left`、`ControllerType=oculus_touch`，头显身份也会变成 `rift`。这说明 `oculus_touch` 兼容路径确实是触发条件之一；它还没有被证明就是产生 9 cm 的具体函数。
- **模型名不等于实际几何**：日志和用户截图都表明，偏移时看到的仍是白色 PICO 模型。`oculus_quest2_controller_*` 这个名字在 Scene app 中会被兼容层解析到 PICO 的资源；不能把现象描述成“实际换成了黑色的 Valve Oculus 模型”。
- **设备 pose 没有 9 cm 的整体平移**：Background / Scene 对照、手柄贴地测试，以及后续在 Alyx 进程内读取 raw、legacy 和 `HandPose` action，均只显示零点到亚毫米级的差异。后者是单帧验证，足以否定简单的设备 pose 偏移，但不等于已经定位了应用的模型矩阵。
- **DSH 现场对照进一步把两条路径分开**（2026-10-17）：用户在同一轮切换 compositor 与游戏/等待封面时确认“1.没偏，2.贴”——标尺/客户端 pose 没偏，compositor 的白色 PICO 模型贴合实物；切回 Scene app 或 VRChat 后模型再次沿柄身朝环方向偏。用户还确认问题在骨架移植之前、原装 DP 驱动下就存在。因此这不是触摸位、骨架补丁或 compositor 设备 pose 的新回归，排查重点应保持在 Scene app / 游戏的模型挂接矩阵。
- **模型组件值本身不是单独原因**：`body` 归零、`handgrip` 归零，以及补齐 `openxr_grip` 后重启验证，用户都确认视觉偏移没有变化。补齐 `openxr_grip` 后，暖机探针确实能读到约 `+10.19 cm`，所以“值没传到应用”与“应用不使用该值”必须区分；目前只能排除它是本问题的充分修复。
- **头显高度旋钮不是手柄偏移来源**：改变 `RVRPlugin.ini` 的 `initialOffsetY` 能改变 HMD 高度；Room Setup 也能改善 HMD 高度，但手柄模型偏移保持不变。
- **原装 DP 驱动也能复现**：因此触摸位补丁和骨架补丁不是这个视觉问题的根因。
- **Alyx 的兼容设置与模型渲染直接相关**：DP legacy binding 的 `simulate_rendermodel=true` 与 `simulated_controller_type=oculus_touch` 是当前最具体的可疑开关；IDA 中 `vrclient_x64.dll` 的 `sub_180171880` 会读取 `simulate_rendermodel`，并由后续组件路径逻辑决定是否走模拟模型分支。它仍未证明是哪一个矩阵产生 9 cm，只把实验入口从“随便平移 OBJ”收敛到了兼容渲染模型路径。
- **IDA 已把这个选项拆成三档**：`sub_1802AB800` 将 `false` / `none` 解析为 `0`，`true` / `name_only` 解析为 `1`，`full` 解析为 `2`；`sub_18016FD20` 只有在返回值为 `2` 时才向原设备请求 `GetOriginalComponentPath`。因此不能再把 JSON 里的 `true` 当作单纯布尔开关，也不能把 `simulate_rendermodel=false` 直接等同于“改回原生 PICO 模型”。
- **已完成 OpenVR 层 A/B，尚未完成游戏视觉 A/B**：用户目录克隆中只把 `simulate_rendermodel` 改为 `false`，重启 SteamVR 后仍返回 `oculus_quest2_controller_*` 兼容名和 PICO 零件路径；把 `simulated_controller_type` 改为 `none` 或 `pico_controller` 后，兼容名立即变成 `{pico}/rendermodels/pico_neo3_*controller`。这证明 Oculus 身份来自 `simulated_controller_type` 这条 legacy 选项；但 `pico_controller` 会改变只带 Oculus 绑定的游戏的输入身份，不能直接作为补丁方案，也不能据此断言 9 cm 已由它直接产生。三次实验均已恢复原 `openvrpaths.vrpath`，安装目录文件没有被改写。
- **同一 A/B 还排除了“兼容模型名直接改了组件原点”**：`simulated_controller_type=oculus_touch` 与 `none` 两次都返回 15 个 PICO 组件、相同的 PICO 零件路径，以及相同的 `mTrackingToComponentRenderModel` / `mTrackingToComponentLocal` 平移（例如 `body` / `handgrip = [0, 0.003, 0.097]`）。变化只有设备身份和 `RenderModelName`（Oculus 名 vs `{pico}` 名）。因此 9 cm 若仍只在 Scene app 出现，候选更接近 app 侧的兼容绑定或最终父节点矩阵，而不是 `component_local` 被 Oculus 名单独改写。
- **当前最强但尚未证实的假设是 pose action 语义错配**：SteamVR 的 Oculus 兼容 profile 明确声明 `/pose/handgrip` 和 `/pose/openxr_grip`；PICO 模型的 `handgrip` 恰好是本地 `+0.097 m`。常见 Unity `SteamVR_RenderModel` 源码把网格子节点放在 `mTrackingToComponentRenderModel`，只把 `mTrackingToComponentLocal` 写到 `attach` 点；若 Scene app 用模拟 Oculus 的 handgrip/openxr grip pose 作为模型根节点，就会得到“模型几何没有变、设备 raw pose 正确、app 里固定约 9 cm”的组合。现有专门 action 探针没有建立有效 origin，所以这仍是待验证假设，不是根因结论。

### 新的静态证据：0.097m 是资源坐标候选，不是已定位的加法点

- PICO Neo 3 的 `pico_neo3_leftcontroller.json` / `rightcontroller.json` 中，`body.component_local.origin` 与 `handgrip.component_local.origin` 都是 `[0.0, 0.003, 0.097]`；`base` 则是 `[0.0, -0.014, 0.174]`。相同数值也存在于 v2 资源。SteamVR 备份的 Oculus legacy JSON 中，`body.component_local.origin` 是 `[0.0, 0.0, 0.0]`，而 `handgrip` 仍是 `[0.0, 0.003, 0.097]`。这使“Scene legacy 路径把 PICO body 资源坐标当模型根，却没有按预期应用 component-local 语义”成为与用户观测完全对齐的候选：数值、方向和现象中的约 9.7cm 一致。
- 这条候选不能写成根因：把 PICO JSON 的 `body` 或 `handgrip` 原点归零并完整重启后，用户视觉上仍报告同样偏移；因此至少有一层缓存、父节点或 app 侧挂接语义没有被该 A/B 改到。OBJ 的 DP/v2 版本也不是统一平移 97mm，不能用“把所有顶点平移 0.097m”替代定位。
- IDA `vrclient_x64.dll` 的 `sub_18016C2D0`（`GetComponentStateForBinding` 路径）会先把输出的 3×4 状态清为单位矩阵，再依据 `OriginInfoList` 解析 render model、component 和 input source，最后调用输入服务虚表取得状态；函数自身没有 0.097m 常量或矩阵乘法。`sub_1802C0040` 解析 `component_local` 时只把 `origin` / `rotate_xyz` 保存到组件结构（`origin` 位于该结构偏移 `+472`），本函数也没有应用平移。因此下一步应追 `+472` 结构字段的读取者，以及真实 Scene app 的最终父节点矩阵，而不是继续改 JSON 原点。

### 已排除：`mTrackingToComponentLocal` / Scene 挂接（死路，别重走）

- 当时的假设：Scene app 把 `mTrackingToComponentLocal`（`[0,0.003,0.097]`）当作可见模型根，就会精确多出 9.70 cm。用一次性 Scene 探针验证过——把 local 矩阵当模型根确实能在真正的 compositor 帧里复现 9.70 cm 分离；而 Valve 的 Unity helper（`SteamVR_RenderModel.cs`，已核对过源码，副本不必留）也不会这么用：它把 `mTrackingToComponentRenderModel` 写给可见子节点，`local` 只喂 `attach` 点。
- **真根因不是它**：实测两态下 12 个组件的 `mTrackingToComponentLocal` **逐字节相同**，变的是**设备位姿**（每手 4.28 cm / 10.29°），来源是 host 发的 `apprun` 消息（见文末「根因」）。9.70 cm 与 `handgrip` 的 `+0.097` 只是数值巧合。
- 相关的一次性 Scene 探针与那份 `.cs` 副本都已随这条死路一起删掉；要重看「local 当模型根」，用 `GetComponentStateForDevicePath` 取矩阵相乘即可，不值得留脚本。

### VRChat/Unity OVRPlugin 的应用侧模型路径（2026-10-17）

- VRChat `GameAssembly.dll` 中的 `sub_1872FD420(a1, a2)` 先调用 `sub_1872AF7A0`（包装 `ovrp_GetRenderModelProperties2` / `ovrp_GetRenderModelProperties`）和 `sub_1872AFCF0`（包装 `ovrp_LoadRenderModel`），再创建 Unity 对象并写入 `Transform`。它只有一个上层调用点：`sub_1872FE0E0+0x4AD`，说明这不是通用 SteamVR C# helper 的被动结果，而是 VRChat 自己的渲染模型构建路径。
- 模型加载成功后，`sub_1872FD420` 通过 `UnityEngine.Transform::set_localPosition_Injected` 写入常量本地位置 `(0, -0.03, -0.04)` m；随后调用 `UnityEngine.Quaternion::AngleAxis_Injected`，再用 `set_localRotation_Injected` 写入本地旋转。这证明应用端在拿到 OVRPlugin 模型后还会自行挂接一层局部变换。
- 这组平移的长度约 5 cm，不能直接解释运行时稳定测得的 9.70 cm；目前也没有把该函数的父节点、输入手序号和最终绘制矩阵连起来。因此当前结论是：**应用侧存在独立模型父变换，且 VRChat 的 OVRPlugin 路径值得继续抓取；但 9.70 cm 的具体加法点仍未定位。**
- 与之相对，SteamVR `vrclient_x64.dll` 的 IDA 交叉引用显示，`component_local` 的 `+472/+496` 只进入 `GetComponentState` 和合成 pose；render-model template/cache 构建路径不读取这些字段。故不能把 `component_local` 直接写成“SteamVR 可见网格根被改写”的定论。
- **运行时命中仍未证明**：GameAssembly 还包含 `ovrp_GetRenderModelProperties(2)`、`ovrp_GetRenderModelPaths`、`ovrp_LoadRenderModel` 的动态解析包装（例如 `sub_1872C6540`、`sub_1872C42F0`、`sub_1872C4250`），但这些包装没有静态直接 caller，疑似由 IL2CPP 方法表间接分派。`OVRPlugin.dll` 的导出本身只是转发到 `CompositorCAPI` 虚表槽 230/231；当前检查到的 D3D11、D3D12、OpenGL、Vulkan 对应实现均为 `return -1002`（unsupported）。因此上面那段 GameAssembly 代码只能记录为“静态存在的候选 app 路径”，不能当成 VRChat 在 OpenVR 会话中一定实际使用的模型加载链。日志里的 `RendermodelManager` 仍需用运行时 API/调用栈确认其真正入口。

### 日志对“兼容身份”和“实际资源”的区分（2026-10-17）

- `vrclient_VRChat.txt` 的一轮完整启动（05:23:26–05:23:27）先记录 `Loaded input profile for simulated controller type: oculus_touch`，并对两只手柄执行 `Simulation ... override properties for oculus_touch`；随后 `RendermodelManager` 以 `oculus_quest2_controller_left/right` 作为模型名，却从 DP 的 `pico_neo3_leftcontroller/rightcontroller.json` 读取，并加载对应的 `left_*.obj` / `right_*.obj`。这证明“兼容身份名”和“实际几何资源”是两层，白色 PICO 模型并不能排除 app 侧兼容变换。
- 同一进程退出后又重新读 `{pico}/rendermodels/pico_neo3_*controller`，说明模型名会随 app/绑定上下文切换；它不是固定的驱动资源替换。
- 当前 `vrclient_vrcompositor.txt` 与备份中，控制器模型记录是 `{pico}/rendermodels/pico_neo3_*controller`，没有 `oculus_quest2_controller_*`。因此“compositor 自己加载了 Valve Oculus 几何”目前没有本机日志支持；此前相关说法应视为误归因。能看到 Valve Oculus JSON 的是 binding-callouts/overlay 类日志，不能拿来代表主控制器渲染路径。
- 这与用户的状态切换完全一致：打开 Dashboard 时走 Dashboard/compositor 的 PICO 路径；关闭后进入等待封面或游戏 app client，才触发 `oculus_touch` 模拟和另一套 app 侧模型挂接。它仍不能单独证明哪一个矩阵加了 9.70 cm，但已经排除了“只改 PICO OBJ 或 compositor 资源选择就能解释全部现象”。

### 试过的方向与有效性

| 试法                                                         | 结论                                                        | 有效性说明                                                                                                                                                    |
| ------------------------------------------------------------ | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `body.component_local.origin` 归零                           | 用户重启 SteamVR 和游戏后确认无变化                         | 有效排除；早期未重启的那次不能作为证据                                                                                                                        |
| `handgrip` / `openxr_grip` 归零或补齐                        | pose 值可以改变，游戏视觉偏移不变                           | 排除“缺一个 grip 值就能修好”；不能据此断言所有兼容层逻辑都无关                                                                                                |
| profile 加 `remapping` 并补 `pico_controller_remapping.json` | remapping 能被解析，暖机后 pose action 能读到；视觉偏移仍在 | 这是 DP 的独立资源回归，和本问题分开记录；当前已还原                                                                                                          |
| 左手改用 PICO 模型名、右手保留 Oculus 名                     | 两只手视觉上没有差别，面板正常                              | 排除“模型名单独决定偏移”                                                                                                                                      |
| 自制 `IVRInput` pose action 探针                             | 不能作为位姿排除证据                                        | SteamVR 接受 manifest/binding，但返回的 action 没有 origin、始终 `active=0`；说明探针没有建立有效 action context，不能把它的零读数写成“所有 action pose 正确” |
| 改 `initialOffsetY` / Room Setup                             | HMD 高度变化，手柄偏移不变                                  | 排除为手柄根因                                                                                                                                                |
| 只平移合并网格                                               | 早期测试不能证明 active Scene 路径是否使用它                | 不能作为“几何无关”的证据                                                                                                                                      |
| 平移所有零件 OBJ `+0.097 m`                                  | 面板和游戏都跟着变化；面板过校正，游戏仍有残余空隙          | 证明这类网格会影响两条渲染路径，但没有得到可用的 app-only 补偿；不能直接写进补丁                                                                              |
| 用左手镜像补右手整块网格                                     | 只影响右手模型是否能加载，和偏移无关                        | 已回滚                                                                                                                                                        |

### 当前结论

现阶段只能把根因定位到：**出问题的 Scene app 控制器模型渲染路径，与 SteamVR 面板路径使用了不同的模型挂接 / 兼容变换**。自制 Scene app 的标准 render-model 分支不会自然偏移，只有故意把 `component_local` 当可见根才出现 9.70 cm；VRChat 的 OVRPlugin 路径又证明应用会在模型加载后自行写父节点局部变换。`oculus_touch` 特判仍是高相关线索，但“真实游戏具体哪一层矩阵、哪一个函数加了 9.70 cm”仍未定位。

因此暂时不要把“应用硬编码偏移”或“只需把零件 OBJ 平移精确数值”写成定论。下一步应在真实游戏进程中捕获 render-model component state、应用创建的模型父节点和最终绘制矩阵，再与 compositor 的同一帧结果对照；继续改 `body`、`handgrip`、`openxr_grip`、地面高度或几何文件，只会重复已经做过的实验。

### 试过、无效、已回滚：把 app 模拟成 Index（`knuckles` priority 96）（2026-10-16 晚）

当时症状是「Alyx 里不碰键 = 握拳、碰键 = 手指伸开」，怀疑 app 没读驱动骨架。顺出来的背景：自动改绑挑「app 有绑定、且 `priority` 最高」的那一档（OpenVR 文档 _Automatic Rebinding_：_SteamVR will look for the highest priority layout that the application has a binding for_），而 Alyx 同时带 `knuckles`(90) 与 `oculus_touch`(95) 绑定 ⇒ 默认被当成 **Oculus Touch**。于是给驱动补了 `resources\input\pico_controller_remapping.json`（内容 = SteamVR 自带的兜底那份，只把 `knuckles` 抬到 96）并在 profile 里加 `"remapping"` 指上它。

- **实测确实生效**：`vrserver.txt` 出现 `[Remapping] … knuckles to … pico_controller`、`[Input] Loaded input profile for simulated controller type: knuckles`，Alyx 也改成加载 `bindings_knuckles.json`。
- **但症状一点没变** ⇒ 「手指不跟驱动走」**不是身份/绑定问题**（真因见下一节：手序号差一位导致两只手互换了镜像姿势）。
- **副作用**：被模拟的那一侧 app 连**模型**一起换成 Index 的（SteamVR Home 的手从「大白手」变成细长的 Index 手）—— 用户实测。
- **已全部回滚**：仓库里那份 json 删掉、profile 的 `remapping` 行去掉、`patch_driver.ps1` 里那两段删掉。**别再走这条路**。

### 真凶：手序号差一位 ⇒ 两只手各拿到对方的**镜像**姿势（2026-10-16 深夜，已修）

**症状**（用户实机）：SteamVR Home 里两只手**左右反了**、手指**扭成一团**；Alyx 里不碰键 = 握拳、碰键 = 手指伸开（"判定反了"）。

**根因**：v2 的控制器对象里手序号是 **1 = 左 / 2 = 右**（它的更新器只做 `*(a1+0xE8) == 1` 这一个判断来决定镜子），而 DP 的控制器对象 `[ctrl+8]` 是 **0 = 左 / 1 = 右**。移植时把 DP 的值**原样**写进了 `[scratch+0xE8]` ⇒ 左手拿到 `0`（≠1，走右手那套）、右手拿到 `1`（走左手那套）⇒ 两只手都用了**对方的镜像姿势**。

- **怎么定位的**：① 用户报告 SteamVR Home 左右反 + 骨扭成一团（说明骨架**确实在被 app 使用**）；② 用运行时自己的参考位姿对照（app 探针 `app_skeleton_probe.py`，Model 空间）：`/user/hand/left` 的实测手腕 x = `+0.034`，而运行时给同一个 action 的 `OpenHand` 参考是 `-0.034`（右手正好相反）⇒ **实测与参考正好互为镜像**；③ Frida 钩更新器（`hook_updater.py`）看实参：不碰键时喂的是 `mask=0`、手序号（`[scratch+0xE8]`）是 DP 的 0/1。
- **修法**：更新跳板写 `[scratch+0xE8]` 时 **+1**（`lea r8d, [rax+1]`）。暂存区/句柄数组仍按 DP 的 0/1 索引（我们自己的约定），只有喂给 v2 更新器的那一个字段用它的 1/2。
- **顺带解释"summary 反了"**：镜像的手相对掌心是"反着弯"的 ⇒ 运行时算出来的 `flFingerCurl` 自然整个反过来（实测：张开的手报 0.68、手指弯下去报 0.00）。**HL:A 就是拿 summary 画手指的**（cvar `vr_disable_skeletal` = _Disable skeletal summary_）⇒ 它忠实地画出了这个反的结果。修完镜像之后这两个值要重测一遍（预期：不碰键 ≈0、摸扳机/握把上升）。
- **回归测试**：`dp_skeleton_payload_test.py` 里加了断言（`[ctrl+8]=1` 的控制器，跳板必须写 `2` 进 `[scratch+0xE8]`）。

### 试过、无效（且实验本身没生效）：删 profile 的 `compatibility_mode_controller_type`（2026-10-17）

现象：**SteamVR Home 里的手型跟 v2 不一样**（用户凭记忆说 v2 是"大白手"，也可能记错）；**把 `eSkeletalTrackingLevel` 从 2 改回 0 不变** ⇒ 级别不是这个开关（实机两次对比，2026-10-17）。

量到的事实：

- 以 app 身份（Scene 应用）读设备属性 = 一整套冒充的 Oculus：`ControllerType=oculus_touch`、`RenderModelName=oculus_quest2_controller_left`、`ModelNumber=Oculus Quest2 (Left Controller)`、`TrackingSystem=oculus`、`Manufacturer=Oculus`（用 `getStringTrackedDeviceProperty` 逐个属性读一遍即可；原一次性探针已删）。
- 但 Home 的客户端日志（`Steam\logs\vrclient_steamtours.txt`）显示它加载的**几何是 PICO 的**：`...\BusinessStreamingDP\driver\resources\rendermodels\pico_neo3_*controller\*.obj` —— 即"名字是 Oculus、几何是 PICO"（与上一节实测一致）。

**试过的改动**：删掉 `resources\input\pico_controller_profile.json` 里的 `"compatibility_mode_controller_type": "oculus_touch",`（OpenVR 文档 _Binding Duplication_：找不到 app 绑定时会用被模拟设备的 profile **并设置模拟属性**）⇒ **实测：Home 手型不变、游戏里 ≈9cm 偏移也不变**。

- ⚠️ **这个实验不能归因到 profile 那一行**：改完后 Home 的日志里仍然是 `[Input] Loaded input profile for simulated controller type: oculus_touch`；DP legacy binding 自己就带 `simulate_rendermodel=true` 和 `simulated_controller_type=oculus_touch`，所以不能只把原因归给 SteamVR 的兜底 remapping。
- 当前只缺真实游戏画面对照：OpenVR 属性层已经确认 `simulate_rendermodel=false` 不会自动去掉 Oculus 兼容身份，而 `simulated_controller_type=none` 会去掉它。由于 `none` 会改变 Alyx 的绑定身份，不能直接作为补丁方案；`patch_driver.ps1` 仍不碰这两个兼容选项。
- 用户 2026-10-17 决定：**先不追**（手型差异无伤大雅），偏移另行调查。`patch_driver.ps1` **不**碰这一行；本机实验后已用 `restore_compat_type.ps1` 还原（该行缩进目前是 4 空格而非厂商的 2 空格，JSON 等价，下次打补丁时可顺手对齐）。

### 上一轮留下的量测结论（仍然有效，别丢）

用「以 app 身份读骨架」的探针（`docs/notes/artifacts/app_skeleton_probe.py`，**必须 `--scene`**：后台 app 拿不到输入，所有 action 都是 inactive）+ Frida 钩我们自己搬进去的更新器（`docs/notes/artifacts/hook_updater.py`，能强制掩码）量出来的事实：

- **每帧更新在跑**：更新器 ~200 次/秒/手；不碰键时喂进去的是 `mask=0x0000, trig=0, grip=0`。
- **驱动发出的姿势原样到达 app**：把 OpenVR 的四元数按 `HmdQuaternionf_t { float w, x, y, z; }`（**w 在最前**）读，驱动的 31 根骨与 app 读回的差 **0.00 mm**（`compare_app_bones.py`）。⚠️ 之前"运行时改写了姿势"的结论是**读法错误**：`VRBoneTransform_t.orientation` 内存里是 w 开头，按 x,y,z,w 读会得到"转了一个分量"的假象。
- **v2 的算法本身是对的**（正确读法重画 `render_v2_poses.py`）：不碰键 = **张开的手**（指尖到手腕 188mm、手指伸直），摸**扳机 / 握把** = 手指**弯**下去（指尖 158/112/90/80），摸 A/X、B/Y、摇杆顶、system 只动拇指。
- **身份/绑定与手指无关**：把 app 的模拟类型从 `oculus_touch` 换成 `knuckles`（见上一节）**没有改变**症状。
- **如果修完镜像还有问题再看这些**：① 给建组件的跳板传一份**非 NULL 的 `pGripLimitTransforms`**（`docs/notes/artifacts/make_grip_limit_pose.py` 已经能生成一份，用 v2 姿势表里"握把按下"那一帧）；② `GetSkeletalReferenceTransforms(BindPose)` 对这个骨架返回全零，若 summary 还是不对，这是下一个要解释的现象。

### 参考：各家模型的原点约定（实测，量合并网格的 z 范围）

| 模型                                     | 几何 z 范围        | 约定                                     |
| ---------------------------------------- | ------------------ | ---------------------------------------- |
| Valve `oculus_quest2_controller_*`       | `[+0.020, +0.150]` | 原点在尖端**前** 2cm（Oculus）           |
| Valve `oculus_cv1` / `oculus_quest_*`    | `[+0.02, +0.14]`   | 同上                                     |
| Valve `vr_controller_vive_1_5`           | `[-0.046, +0.174]` | 原点在身体**内部**（Vive）               |
| PICO `pico_neo3_*controller`（合并网格） | `[-0.049, +0.126]` | 原点在追踪环与柄身的交界附近，不是环中心 |

（这些原点约定确实不同；它们能解释为什么不同模型不能直接互换，但尚不能单独解释本问题。菜单与游戏路径的差异仍需看运行时矩阵。）

### 其它实测补充

- `component_local` 的离线几何意义和运行时挂接路径不能混为一谈：拿 Valve 的 `oculus_quest2_controller_left` 当对照时，各零件按 `origin + rotate_xyz` 变换后与其自带的合并网格差 **11–56mm**，原样用顶点则差 **0.0mm**。这只能说明静态资源之间的坐标约定不同，不能单凭离线包围盒断言 SteamVR 或游戏最终选用哪一种资源路径。
- DSH 实机测试还发现，整体平移零件 OBJ 会同时改变面板和游戏里的模型。因此当前只能记录“零件资源会影响运行时显示”，不能再写成“app 一定加载合并网格”或“compositor 一定只加载合并网格”。最终资源与矩阵组合需要在真实进程中抓取。
- DP 这份的 `tip.rotate_xyz` 是 `[-21.282,3.0,0.0]`，而 **UW / v2 / DP 自己的 neo2 都是 `-1.282`** ⇒ DP 独有、疑似笔误（已修）。
- v2（`%LOCALAPPDATA%\PicoNeo2NvencCompat`）与 DP 逐文件比对：**OBJ 逐字节相同**；JSON 只差 `motion` 块。DP 少发：`pico_hmd_profile.json`、`pico_neo3_controller_profile.json`、8 份应用绑定、`pico_controller2_remapping.json`、`_joystick` / `_trackpad` 模型变体。**右手的合并网格两边都缺**。
- `pico_neo2_*_oculus.json` / `_vive.json` 与本体只差空白（`_vive` 那对换了 trackpad 语义），neo3 目录里没有这两份、DLL 里也没有这些后缀 ⇒ 没人引用。厂商留 `_oculus` 变体这件事说明他们知道「给 Oculus 用要改几何」，但没做。
- 姿势源侧：DP 驱动 DLL 里原本 **`/pose/*` 与 `/skeleton/*` 一个都没有**（UW / v2 有 `/pose/raw` + `/skeleton/hand/{left,right}`）⇒ Alyx 的手指动画拿不到；2026-10-16 起由「骨架 / pose 补丁」把 v2 的实现搬了进来（见下面同名小节）。

### 头显 profile 漏发（已修）

```text
vrserver.txt  [Error] [Controller Setup] Failed to load input profile for device:
              Unable to read device input profile from {pico}/input/pico_hmd_profile.json
```

- DP 驱动每次启动都在找 `{pico}/input/pico_hmd_profile.json`，但包里没有 ⇒ 头显 profile 加载失败。v2 自带这份（纯 HMD profile，**没有** `simulation_settings`，引用 `{pico}/icons/headset.svg`）；DP 连 `headset.svg` 都没有 ⇒ `patch_driver.ps1` 生成时去掉图标引用。补上之后报错消失（但 `[Simulation] … for rift` 依旧 ⇒ 冒充来自 stub，与这份 profile 无关）。

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

## 补丁（15 字节，零长度变化）—— **已应用**

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

应用：`src\windows\patch_driver.ps1`（管理员 + 已退出 SteamVR；**Steam 客户端也会把这个 DLL 映射进自己进程**，占着就写不进去 —— 实测 `steam.exe` 会，且 `tasklist /m` 列不出来、得提权看 `Get-Process | %{ $_.Modules }`），自动备份 + 逐字节校验 + 复核；同一脚本还会把 profile 里 `input/application_menu` 的斜杠补上（见上「预设整体搬迁」一节），备份为 `pico_controller_profile.json.orig`。
还原：把 `driver_pico.dll.orig`（md5 `9017439d…`）复制回 `driver_pico.dll`；profile 那条则把 `.orig` 复制回去。

## 骨架 / pose 补丁：`.pitouch` 段（2026-10-16 实现，**离线验证过、待实机**）

前一节那 15 字节换不来手指动作：Alyx 读的是 `/user/hand/*/input/skeleton/*`（见「输入声明层」），而 DP 的 `driver_pico.dll` 里连 `skeleton` / `pose/raw` 字符串都没有 ⇒ 是被厂商整段砍掉的功能，profile / 数据层都补不出来。这里的做法是**把 v2 的实现整段搬进 DP 驱动**：

- **来源**：`BusinessStreaming-v2.1.2-win32-x64` 的 `app\openvr_driver\bin\win64\driver_pico.dll`（md5 `e6d408b2590042c3c7f796b694ffc404`、sha256 `d851b7d1…`）。搬的是 RVA `0x316D0`–`0x402C3` 这一整段（60,339 字节）：31 骨生成器 `sub_1800316D0`、它用的两张「按键组合 → 手指姿势」常量表 `sub_180035DC0` / `sub_180037860`、姿势混合 `sub_180032360`、slerp `sub_180040080`、以及每帧更新器 `sub_18003FDA0`。**没改一行逻辑**（逐指令搬 + 重定位），因此「v2 的算法」就是字面意义上的那套。
- **UW 那份为什么不用**：两边的骨架姿势其实都是 **PC 侧算的**（同一套「按键组合 → 姿势表 + 模拟量混合」）；区别只在入口 —— UW 的更新器（`sub_18001E2D0`）吃的是它网络层那份 176 字节控制器状态**结构体**（生成器只读 `+52` 掩码、`+88` 一个 float），搬它就得连结构体一起伪造；v2 的更新器只吃「键位掩码 + 扳机/握把模拟量」两个标量，正好就是 DP HID 路径手上的东西 ⇒ 搬 v2 的（v2 是新版，用户也要求优先用它）。
- 头显真的会送「手部数据」的是 **v2 的另一条路**：`sub_180016970` 把 0x958 字节关节原始数据 `memcpy` 下来、用 `sub_180001104` 换算成 31 根骨（日志里那句 `with handtracking UpdateSkeletonComponentfailed`）—— 那是手部追踪（PICO 4 那代），Neo 3 / DP 直连没有；我们搬的是控制器那条 `sub_18003FDA0`。
- **重定位**：整段里 **27 个跨段分支 + 881 个 RIP 相对引用**。873 个引用指向 `.rdata` 常量 ⇒ 把用到的 4 组共 1328 字节一起复制过来；剩下 8 个是三个 `__security_cookie`、IVRDriverInput 缓存指针、IVRDriverContext 指针 ⇒ 换成 DP 的同名全局（`0x18009A088` / `0x1800A2B40` / `0x1800A2B58`）。跨段跳转的 7 个 thunk 指回段内、`sinf`/`sin` 指向 DP 自带的静态 CRT（`0x180070E70` / `0x180070900`）、`__security_check_cookie` 指向 `0x1800469B0`、出错日志指向 DP 的 `sub_180025110`。
- **`acosf`：DP 没有**（静态 CRT 里没有，v2 是从 `api-ms-win-crt-math` 导入的）。slerp 要除以 `sin(acos(dot))`，`dot → ±1` 附近极端病态 ⇒ 用 A&S 那种 float 多项式（相对误差 ~11%）会让骨头算出 8.96 这种非法值，Newton 形式在 `acos(1)` 处 0/0 直接 NaN。最后是自己实现：`acos(x) = 2·asin(√((1−x)/2))`（x≥0）/ `π − 2·asin(√((1+x)/2))`（x<0），`asin(y) = y·Q(y)`，`Q` 是 16 次 Chebyshev 拟合、全程 double ⇒ 实测与正确舍入的 float32 结果 **0 ULP** 差。
- **新段 `.pitouch`**：RVA 就是原 `SizeOfImage`（`0xAB000`，脚本会卡死这个值再动手），属性 `0xE0000060`（可读/可写/可执行，里面放了两只手的句柄、暂存区和常量）；DLL 669,536 → 734,720 字节。段内只有 RIP 相对寻址，**不依赖加载基址**（驱动开了 ASLR）。
- **两个挂钩点**（都只改 5 字节，跳进去的跳板在段里）：
  - **建组件**：组件创建函数 `sub_1800149E0` 收尾那个 `call sub_180025110`（RVA `0x17E86`）→ 改成 call 跳板。跳板拿 `[ctrl+0x138]` 当 container，按手选 `/input/skeleton/left|right` + `/skeleton/hand/left|right`，base pose 传 `/pose/raw`，`eSkeletalTrackingLevel = 0`（`Estimated`，见下条）、`unGripLimitTransformCount = 31`，句柄存进段内按手索引的状态里，最后把原来的日志调用补回去。
    - **级别照 v2 抄**（2026-10-17 用 IDA 查清）：v2 的组件创建是 `if (*(BYTE *)(this + 0x2E0)) level = 2 else level = 0`，而这个标志在 v2 里是**「手部追踪版」开关** —— 同一个标志让设备对外自称 **"Pico Hand"** 而不是 `Pico Neo3 / PICO 4 Controller`（`sub_180016110`：`if (*(BYTE*)(a1+736)) model = "Pico Hand left"`）。⇒ **普通手柄（DP 直连就是这种）在 v2 里拿 `0 = Estimated`，只有 "Pico Hand" 拿 `2 = Full`**；一开始硬编码成 `2` 是偏离 v2 的（实机症状：SteamVR Home 里的手型跟 v2 不一样）。
  - **每帧更新**：输入更新入口 `sub_180019580`（RVA `0x19580`）的头 5 字节（`mov r11,rsp` / `push rbp` / `push rdi`）→ 改成 jmp 跳板；跳板执行完原指令再跳回 `0x19585`。跳板取 `hand = [ctrl+8]`、键值字、扳机/握把模拟量，翻译成 v2 的掩码，填进每只手 0x300 字节的暂存区 —— v2 的更新器把淡入淡出状态放在「控制器对象」的 `+0x2E4/0x2E8/0x2F0/0x2F8`、hand 在 `+0xE8`、句柄在 `+0x1C0`，所以我们就拿这块暂存区当那个对象喂给它，免得改它的代码。更新器自己会两次调 `UpdateSkeletonComponent`（motion range 0 / 1，各 31 根骨）。
- **位映射（DP 键值字 → v2 掩码）**：`0/1/2/3/4/6/12` 原样；**dp bit7（摇杆顶触摸）→ v2 bit5**、**dp bit5（扳机触摸）→ v2 bit7**（两代的这两个触摸位是反的，按物理含义对齐，不是按位号）；v2 的 bit9（grip touch）、bit13（system touch）留 0 —— DP 没有对应位，且 v2 的姿势表会读 bit13，不能让 menu 键去动手指。
- **payload 从哪来**：`src\windows\src\driver_patch\dp_skeleton_payload.bin`（+ 同名 `.json` 清单），**入库**（仓库因此带了一份 PICO 的机器码，README 许可一节写明了）；`patch_driver.ps1` 直接用它，离线，缺了就直接中止。要重建就手动跑 `docs\notes\artifacts\build_dp_skeleton_payload.py`（`uv run --with capstone --with keystone-engine --with pefile`；源 DLL 的 sha256 卡在打包器里）。
- **怎么验的**（都在这台机器上跑过，`docs/notes/artifacts/` 里）：
  - `dp_skeleton_payload_test.py`：① 逐指令比对「搬过来的段」与 v2 原件（只有该重写的那几个字段不同、且都指向映射后的目标）；② Unicorn 里把 v2 原更新器和搬过来的副本跑同一批 30 组输入，**31×2 根骨头逐比特一致**；③ 我们的 `acosf` 与正确舍入结果 0 ULP；④ 建/更新跳板与位映射都符合预期。
  - `dp_skeleton_image_test.py`：对**真打完补丁的 DLL** 整镜像跑一遍，确认两个挂钩点落进段里，并且从 `sub_180019580` 进去能产出 2 次 ×31 骨的更新。
  - **实机**：补丁打上后 Alyx 不再报 `Item /user/hand/left/input/skeleton/left in "skeleton" array missing path invalid device path for skeleton output`（SteamVR 日志，说明组件真建起来了、app 的骨架绑定解析通过）；手指真正动起来要等**手序号镜像**修掉（见「真凶」一节），修完后 Alyx 里"不碰键 = 张开、摸/按扳机 = 手指弯"，用户实测确认。

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

### 两代串流的「系统键」路由不同（实测）

- **网络串流**：头显 app 自己打包那份 32 位掩码，谁当 `system` 由它决定（掩码 bit9），PICO 键由头显系统吃掉、根本不下发 ⇒ 用户按到的是 menu 键当 SteamVR 系统键。
- **DP 直连**：`pxrstreamingservice` 直接发 HID 键值字、路由固定 ⇒ 左手 PICO 键 = bit12 = `/input/system/click`（SteamVR 里呼出 dashboard 的就是它），menu 键 = bit13 = `/input/application_menu/click`。
- bit13 头显**确实发**（`02` 的按钮巡回实测 `report[49] = 0x20`），驱动也确实写这个组件（`sub_180019580` 开头）；到不到游戏取决于 profile 有没有把这条输入建出来、以及游戏有没有绑它 —— Alyx / VRChat / The Lab 的绑定都引用了 `/user/hand/*/input/application_menu`。
- 自证（SteamVR 已启动、DP 已连）：`uv run python docs/notes/artifacts/ovrread.py 60`，按 menu 键看 `AppMenu(1)`、按 PICO 键看 `System(0)` 是否出现在 `ulButtonPressed`。

## 其它相关函数

| 函数                                                | 作用                                                    |
| --------------------------------------------------- | ------------------------------------------------------- |
| `sub_180026420`                                     | HID 打开：`hid_init` / `hid_open(0x2d40,0x16,0)`        |
| `sub_180026A10`                                     | HID 读循环：`hid_read_timeout(...)==0x40` 才处理        |
| `sub_180025A90`                                     | HID 报文分派：`type = buf[2] >> 5`（`buf[0]` 已被剥掉） |
| `sub_180026E60` / `sub_1800274B0` / `sub_180027EF0` | type0 / type1,2 / type3 处理（IMU 解算）                |
| `sub_18002CE90`                                     | UDP `recvfrom` 接收线程                                 |
| `sub_18003D610`                                     | 控制器状态入口（HID 与 UDP 多路调用）                   |

## 偏移问题的实测记录（2026-10-17，按时间）

### 模型几何与姿态原点的可实测标定（2026-10-17 晚）

之前只能从截图推断「模型整体平移 9.7cm」；这轮把网格和姿态的关系做成了可测的：

- **网格长轴与 +Z 的关系已定死**：`left_body.obj` 占 `x[-0.040,+0.048] y[-0.005,+0.085] z[-0.031,+0.136]`；沿 z 的剖面里 `z[-0.031,+0.02]` 是最大半径 0.085 的「环 + 面盘」区，`z[+0.02,+0.136]` 收窄到 0.044→0.028 的柄身区，且空心判据只在 `z[+0.015,+0.030]` 出现 40% 空芯（环的截面）。⇒ 模型原点位于**环—柄交界**，柄身朝 **+Z** 伸出约 13.6cm，`body`/`handgrip` 的 `+0.097` 落在柄身靠末端。
- **世界方向已用运行时标定**：新探针 `temp/driver/probe_ruler_numbers.py` 沿控制器自己的 +Z 摆一列彩色刻度（`-6/-3/0/+3/+6/+9.7/+13/+16cm`，蓝→青→绿→黄→品红→橙→红），并把「设备姿态原点」和「+9.7cm 点」投影到左眼视口记账。同一帧里用 SteamVR 自带「VR 视图」镜像核对：刻度 x 随 z 单调递增，且与 compositor 白模型的柄身方向一致 ⇒ **模型 +Z = 柄身 = 朝环外**，`mTrackingToComponent*` 的 0.097 方向与用户描述的「偏」方向可以做符号判断。
- **镜像视口映射不能想当然**：镜像窗口不是 1:1 的眼缓冲（实测把日志里的视口坐标线性映射到窗口像素后，左右手残差不同）。要在镜像里做逐点量测，必须先用一列已知位置的标尺色块反解「缩放 + 偏移」，不能直接用 `getProjectionMatrix` 的结果换算像素。
- **镜像同时画 compositor 内建模型与 app 帧**：`vrmonitor` 的「VR 视图」在「无 Scene app」和「SteamVR Home 持有 Scene 焦点」两种状态下，compositor 的控制器模型位置逐像素一致（阈值 40 的差分只剩 2763 px，全是抗锯齿/抖动）⇒ 那两张图里画的是 compositor 的内建模型（`{pico}` 路径），和用户口径一致：compositor 那条一直是对的，偏的是 app 那条。**但镜像本身不是「只画 compositor」**，见下一条更正。
- **更正（同日）：镜像是可以显示 Scene app 帧的** —— 只要 app 真的在提交。判据：最小 Scene app 把双眼涂成品红后，镜像里品红占 69650/131k 采样点。之前几次「镜像只看得到 compositor 模型」是因为捕获时 app 已经退出（帧数跑完）。⇒ **用镜像量测 app 侧渲染是可行的**，前提是①捕获必须在 app 运行期间；②别用「窗口置顶」截图（会打断用户），改用 `PrintWindow`（见下条）。
- **无人值守抓镜像的办法**：`temp/tools/capture_window.ps1`（`-Hwnd <hwnd>` + `PrintWindow(PW_RENDERFULLCONTENT)`）可以在**不抢前台**的情况下抓到「VR 视图」窗口，窗口被遮挡也没关系；`-Foreground` 才置顶。注意窗口 hwnd 会变（`SteamVR 状态` 与 `VR 视图` 都在 `vrmonitor.exe` 下），抓之前先用 `Get-Process | ? MainWindowHandle -ne 0` 复查。
- **位置对照标尺（本次新增的定量工具）**：`temp/driver/scene_three_offsets.py --mode ladder` 会在同一帧里把同一个手柄网格画 7 份，沿模型 +Z 分别偏移 `-9.7 / -5 / -2.5 / 0 / +2.5 / +5 / +9.7 cm`，颜色 `红 / 橙 / 黄 / 灰 / 绿 / 青 / 蓝`，其中**灰色＝compositor 的摆放（设备姿态 + 单位阵）**。镜像里已确认 7 份都能渲染（`ps_ladder.png`）。游戏里模型与哪一份重合，就直接读出偏移量与符号 —— 这是目前唯一能把「app 侧偏移」变成数值的仪器。
- **地面高度反推原点位置不可行**：遍历网格所有「贴地」朝向（绕 z/x 各 15° 步进）后，原点离地高度的取值覆盖 `0.5–12.9cm`（中位 5.65cm）⇒ 用户测到的 `Y=+0.0575` 无法判别姿态原点对应实物哪个点，别再拿这条数据做结论。
- **原点在实物上的位置（体积加权，双手机械对称）**：`*_body.obj` 体积 137.8cm³、体积重心 `z=+0.0462`（轴向 46.2%）；**原点是整个几何里离 -Z 端最近的点，位于轴向 18.5%、柄身半径最低处**（`z=0` 的顶点只剩 439 个）。体积沿 z 的分布是两端重（28.1% / 36.3%）中间轻 —— 环在一端、柄身朝 +Z 收窄到 12.6cm 处，与镜像里「柄身朝 +Z、环在 -Z」一致。⇒ **姿态原点落在环—柄交界（环根），而手掌实际握在柄身中段（z≈+0.05~0.09）**，两者相距约 5–9cm，量级正好覆盖用户报的 9.7cm。
- **截面「实心度」再确认一次形状**：按 z 逐层求表面与平面的交线并算包围盒填充率，`z≤+0.013` 的层宽 8.6–8.8cm（环），`z≥+0.023` 骤降到 5.4cm 并一路收窄到 2.1cm（柄身）⇒ **环只占 z∈[-0.031,+0.013]，柄身从 z≈+0.013 一直到 +0.136**；手握点（体积重心 +0.046、`button_grip` 网格 +0.060~0.079）落在柄身中段，和模型自己声明的 `handgrip=+0.097` 差 2–4cm（模型声明值比实测握点更靠柄尖）。
- **姿态源侧的数值（旧探针实测，别读错列）**：`pose_path_probe --oculus-only --scene` 的结论是 **`raw` / `legacy` / `openxr_grip = 0.00cm`、`handgrip = +9.70cm`、`base = +17.46cm`、`tip = +1.22cm`**（相对设备姿态）。⇒ **驱动报的设备姿态原点与网格原点同为一点，握把/`base` 都在它前方（+Z）**，两者内部自洽；这也解释了为什么「把 `handgrip.origin` 归零」改不动视觉偏移（那只挪动握把点，不挪网格）。
- **为什么「compositor 对 / app 偏」这条对照无法判别**：两条路都把网格摆到「设备姿态原点」上（compositor 用设备姿态，app 用 `device * mTrackingToComponentRenderModel(=单位阵)`），差值恒为 0。所以「哪一侧对」实际取决于**实物握把相对姿态原点的位置**这个外部事实：若原点在环根而握把在 z≈+0.05，则「app 偏」与「compositor 偏」在数据上不可区分，必须用实物指认来破对称。
- **另一个同源实测**：`hand_root_probe.py` 在 `VRSkeletalMotionRange_WithController` 下读骨架，`j0` 恒为 `(0,0,0)`、`j1/j2` 是固定的小偏移（约 `±0.034, +0.037, +0.165`），与设备位姿相差 130cm 以上 ⇒ **骨架返回的不是世界坐标，不能用它来判定手的位置**（那次「骨架根偏多少」的猜想就此作废）；要测手的位置得换 `GetSkeletalReferenceTransforms` 或走 app 侧。
- **下一个最小实验（一次指认即可破对称，探针已就绪）**：戴着头显、正常握住手柄，报「彩色刻度梯里**哪一格压在掌心/握把上**」。刻度梯为 `蓝 -6 / 青 -3 / 绿 原点 / 黄 +3 / 品红 +6 / 橙 +9.7 / 红 +13cm`。
  - 若答案是「**绿（原点）**」⇒ 驱动姿态与网格一致，9.7cm 来自 app 侧的模型挂接（继续追 `+472` 的读取者与 app 父节点）；
  - 若答案是「**品红/橙（+6~+9.7）**」⇒ 网格原点与实物握把差 9.7cm，修法是把网格与 `component_local` 一起平移 −9.7cm（面板与游戏会同时对齐）。
- **仍缺的唯一量**：驱动报的姿态原点落在实物上哪个点（环交界 / 柄身中段 / 掌心）。标定探针已经把这道题变成「戴上看哪一格压在掌心」，不需要再改 JSON 或长方形网格。

### WebXR 标定台（2026-10-17 晚，可直接读数）

`temp/webxr/xr_overlap_probe.html` + `temp/webxr/xr_ctl.mjs`（静态服务在 `127.0.0.1:8010`，根目录是 `temp/`）：

- **不需要人点 ENTER VR**：Chrome 带 `--remote-debugging-port=9333` 起（`temp/chrome-xr` 独立 profile），`node temp/webxr/xr_ctl.mjs click "#VRButton"` 用 CDP `Input.dispatchMouseEvent` 派发**可信点击**，`requestSession()` 的用户激活条件满足；随后 `eval "window.__probe.state()"` 读 `presenting / tracked / frames`，不必再问用户「进去了没有」。
- **别用 `renderer.xr.getControllerGrip(i)` 量姿态**：本机 Three.js r169 下若在 session 起来之后才创建，grip 的 `matrix` 恒为单位阵（`position` 全 0，镜像里模型落在原点），换成自己按 `XRFrame.getPose(inputSource.gripSpace, referenceSpace)` 写 `Group.matrix` 才准（页面里就是这么做的）。
- **镜像能直接看 WebXR 帧**：`temp/tools/capture_window.ps1 -Hwnd <VR 视图>`（`PrintWindow`，不抢前台）即可，和抓 compositor 是同一套；SteamVR 的 "VR 视图" hwnd 会变，先枚举 `vrmonitor.exe` 的窗口。
- **标定结果（用户现场指认）**：以 grip 空间为原点、沿模型自身 +Z 摆 `-19.4 / -9.7 / 0 / +9.7 / +19.4 cm` 五份，**`-9.7`（绿）＝ 正确位置 ＝ compositor 的摆放**；更往里（`-19.4`）已被用户否掉，不是游戏里的位置。⇒ **网格要落在 grip 空间原点往后 9.7cm 处才对**，也就是「网格挂到手柄空间原点」这一档（0）恰好偏出 9.7cm —— 与用户报的偏移量、与 JSON 里 `handgrip=+0.097` 同一个量级，方向为「朝环 / 往上」。
- **下一步只差一次物理指认**：页面现在只留两份（**白 = 挂手柄空间原点**、**绿 = 正确**）。把两只手柄的环怼在一起，看白的模型是否像游戏里那样互相陷进去；是则「游戏把模型挂到了 grip 姿态而不是设备姿态」成立，接着追 Scene app 侧拿到 +9.7 的那个位姿源（`/pose/grip` vs 设备姿态），而不是再动资源。

### 游戏自身两帧的定量比对（2026-10-17 20:1x，用户现场截图）

用户给了同一姿势下的一对截图（`正常位置` = 无 drift / `不正常位置` = Scene app 等封面时），`temp/driver/game/`：

- **相机没动**：两帧天空带与地面带逐像素平均差 `0.40 / 0.09`（/255），山区带的大差异全来自手柄模型本身 ⇒ 可以把手柄的像面位移直接当成模型漂移。
- **正常帧是两个独立连通块，漂移帧并成一个**：白模型的连通域在正常帧是 `n=17886` 与 `18814` 两块，漂移帧合并成 `n=28675` 一块（bbox `x[459,859]`）⇒ 漂移让两只模型在像面上真的叠在一起（用户说的 overlap 有了像素级证据）。
- **漂移方向 = 各自朝内**：正常帧两模型 bbox 外缘 `392 / 920`（跨度 528px），漂移帧 `459 / 859`（跨度 400px），每只向内缩 ≈64px；高度 145→159 略长。⇒ 每只模型沿「自己柄身朝环」方向位移，横向分量约 3–4cm，其余在深度里（模型变长/变近）。
- **因此 sweep 探针的范围是对的**：`temp/webxr/xr_drift_sweep.html` 让白色模型沿模型自身 +Z 连续扫 `-30 … +10cm`，绿色 22% 透明度参考固定在 `-9.7`（= 正确 = compositor），**扣扳机冻结**并把冻结值写进 `window.__probe.state().history`（CDP 可直接读，不需要用户读数）；冻结再扣一次继续扫。
- 待定：漂移的**精确标量**（用户现场扣一次扳机即可）。已知它朝环方向、量级 3–9cm，且 `-19.4` 已被用户否掉 ⇒ 真值大概在 `-0.097` 与 `-0.194` 之间，不能直接套用 `handgrip` 的 9.7。

### 已复现 + 根因改判：漂移在**设备位姿**，不在渲染模型（2026-10-17 20:2x）

用真游戏复现成功（`temp/driver/game2/`，HL:Alyx appid 546560，`steam://rungameid/546560` 拉起后 `hlvr.exe` 一出现即进入漂移态）：

- **和用户两张截图的数字逐项吻合**：正常帧两个白色连通块 `n=18128 / 18968`、外缘跨度 **528px**；漂移帧并成一块 `n=28813`、跨度 **400px**（用户那对是 528/400 与 17886/18814/28675）。背景天空带逐像素平均差 `0.073/255` ⇒ 相机没动，可以逐像素比。
- **确定性 A/B**：杀 `hlvr.exe` 后 8 秒再抓，两个连通块与外缘坐标**回到原值**（`400..661 / 668..928`，跨度 528）⇒ 漂移随「游戏占着 scene」开关，不是手抖、不是追踪漂移。
- **关键改判（推翻「模型挂接矩阵」这条主线）**：同一个静态姿势下，用 `VRApplication_Background` 探针（`temp/driver/pose_matrix_probe.py`）读 `getDeviceToAbsoluteTrackingPose`：
  - 正常：L `(+0.03608,+0.60136,-0.27770)`、R `(+0.10133,+0.59220,-0.26753)`
  - 游戏加载中：L `(+0.07864,+0.60547,-0.27497)`、R `(+0.06079,+0.59870,-0.25529)`
  - 每只手位移 **4.28cm**；换算到**手柄自身坐标系**是 `(±0.0099, +0.0115, -0.0401)`，同时姿态整体转了 **10.29°**（转轴在自身系里 ≈ `(0,-0.096,+0.994)`，即沿柄身轴 + 一点 Y）；左右手镜像对称。
  - **头显位姿完全不变**（`+0.07053/+0.71034/+0.13816` → `+0.07077/+0.71035/+0.13802`）⇒ 不是 universe origin 平移，是**逐设备**的位姿修正。
  - 杀游戏后再读，数值**逐位回到**正常值 ⇒ 是一个确定性的固定刚体变换，不是噪声。
- ⇒ **模型本身没动，是喂给渲染器的位姿动了**。这解释了为什么所有资源侧改法（`body`/`handgrip` 原点归零、换模型名、补组件、平移 OBJ）都没用：它们改的是几何，而错在 pose。历史上的「9.7cm = `handgrip` 偏移」是**数值巧合**；真实每手漂移是 4.28cm，两只手柄相对位置偏 8.6cm，正好对应 `528→400px`。
- **触发条件不是「声明 oculus 绑定」**：自制 Scene app 用 oculus-only manifest（`temp/driver/scene_standby_sim_probe.py`，日志确认 `[Simulation] ... oculus_touch`、`type=oculus_touch`）占着 scene 时，位姿**逐位不变**、镜像里也不漂。⇒ 真 Steam 游戏（有 appid / vrmanifest、走 `vrclient_x64.dll`）还做了别的事才会触发这段修正。这是下一个要定位的点。
- **日志侧已定位到「兼容/重映射」这条链**（`Steam\logs\vrserver.txt`）：`steam.app.546560` 连接后立刻出现
  - `[Input] steam.app.546560 (pico_controller) attempting to load default config from .../hlvr/cfg/bindings_touch.json`（Alyx 自己的 **oculus_touch** 绑定）
  - `[Remapping] Beginning remapping from controller type: oculus_touch to controller type: pico_controller` → 成功
  - 而 `pico_controller_profile.json` 里写着 **`"compatibility_mode_controller_type": "oculus_touch"`** ⇒ 「没写 pico 绑定的 app 自动当 Oculus Touch」是驱动自己声明的，重映射与模拟都由此而来。
- **下一步（按性价比排序）**：①把 Alyx 的 `bindings_touch.json` 当作自制 manifest 的 `oculus_binding` 再跑 standby 探针，看位姿是否跟着变（能一次性锁定是不是这份绑定/重映射引入的修正）；②换第二个游戏（VRChat / The Lab）看是否同样触发，确认是通病而不是 Alyx 特例；③若确认在重映射里，就去 `vrclient_x64.dll` 追 remap 的 pose 分支（`docs/notes/04-driver.md` 已有的 `simulate_rendermodel` 三档线索在 `sub_1802AB800` / `sub_18016FD20` 附近）。

## 结论：游戏里手柄偏 ≈4cm / 10° —— 已定位并修复（2026-10-17）

**现象与量化**：Scene app 占场景时，两只手柄的**设备位姿**各偏一段——自身系 `d=(±0.0111,−0.0093,+0.0403)`、`|d|=4.28cm`、绕自身 `∓Z` 转 **10.29°**，左右镜像；`raw` / `standing` / `seated` 三个 universe 同步变、HMD 位姿不变；静态姿势下逐位稳定（预测时间 −0.05…+0.5 s 结果相同、速度全 0）。镜像里肉眼可见两只模型并到一起。

**根因链**：Steam 启动游戏 → PICO PC 侧 host 通过本机 socket 反复发 `apprun <n>` → `driver_pico.dll` 的收包线程 `sub_18002CE90` 用 `atoi` 写入全局 `dword_18009B080`（RVA `0x9B080`）→ 位姿发布函数 `sub_180018340` 读这个标志，给 `DriverPose_t` 多加一段 → 客户端读到的就是偏的。`apprun` 在整个 DLL 里只有这一处消费，所以补掉它不影响串流画质等其他行为。

**取证**

- **免游戏复现**：`IVRApplications::identifyApplication(pid, "steam.app.<已安装id>")` 把空进程挂到某个已安装 Steam 应用上，约 2 秒内进入漂移，进程退出即恢复（`temp/driver/drift_hold.py`）。换 `openvr.tool.steamvr_room_setup` 这类工具 key 不触发 ⇒ 只有被当成「Steam 游戏」才偏。
- **发布函数入口/出口成对取值**：输入 `(+1.01164,+0.55034,+1.08921)` 两态**一字不差**，写出的 `vPosition` 不同（`+0.97067,…` vs `+0.92877,…`），而出口值就是客户端读到的值 ⇒ 偏移由驱动产生，vrserver 只转发。
- **整个 `.data`（10.7 KB）两态只差两处**，其一是 `0x9B080`（0→1）。
- **闭环**：漂移态下每 5 ms 把该标志写 0，位姿立刻回到基线（`+0.90857/+0.97067`），停止写入又回漂移。

**修法**：`patch_driver.ps1` 把写标志前的 `call atoi` 换成 `xor eax, eax`（零长度变化）⇒ 标志恒 0。验证：identify 测试 **4.28 cm → 0.04 cm**；The Lab 运行中位姿保持基线、两只模型分开（`temp/driver/fixed_thelab.png`）。

**已排除（都有数值或 A/B 证据，别再试）**

- **不是 vrserver**：两态下驱动喂入的 `DriverPose_t`、`.data` 全局、设备属性集全部一致，vrserver 只转发；`simulate_rendermodel`、`compatibility_mode_controller_type`、`simulated_controller_type`、Valve 的 priority-95 `simulate_*` 布局逐项 A/B 均为负。
- **不是模型挂接**：两态下 12 个组件的 `mTrackingToComponentLocal` **逐字节相同**；把两份 rendermodel 的 13 个 `component_local` 全部归零后漂移**一字不差** ⇒ 几何 / 组件原点 / 模型名这条路原理上不可能修好它。9.70 cm 与 `handgrip` 的 `+0.097` 只是数值巧合。
- **不是本项目的补丁**：换成厂商原版 `driver_pico.dll.orig`（无 `.pitouch`）照样漂。
- **不看控制器类型 / profile**：把 `pico_controller` 等长改名（DLL 三处 + profile）后照样漂。
- **不是预测外推**：−0.05…+0.5 s 各预测一遍结果完全相同、速度全 0。
- **不是 `vrlink`**（Steam Link 驱动）：虽加载并连着头显 IP，但从未建立会话（`Null VTE_CLIENT_SESSION_ID`）。**不是 `app_check.exe`**：连续 kill 不影响。
- `[poseFeeder] initialOffset*` 只影响头显高度；`debug.log` / `sendlog*.txt` 不含位姿数值。

**公开资料对上了**：[SteamVR 论坛「Offset problems using Pico 4 controllers」](https://steamcommunity.com/app/250820/discussions/0/3828666917400432090) 里 PICO 用户描述「in game hands are being offset and appearing at the wrong angle」「It starts from the tip of controllers and angled」，与实测的 **4.28 cm + 10.29°（不是单纯平移）**逐条吻合；那边把控制器显示成 Quest 2 手柄后偏移消失，本质也是换了位姿约定。

**两个方法论坑（下次省时间）**

- 只 hook 发布函数的**入口**会得出「驱动没变」的错误结论——必须入口 + 出口成对取值。
- `identifyApplication` 之后漂移态会**卡住**（vrserver 一直以为应用在跑）；每次测量前重启 SteamVR，并先打印一次基线位姿确认（`dev2.x≈+0.97067` 干净 / `≈+0.92877` 已卡住）。
