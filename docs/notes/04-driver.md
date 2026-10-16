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
- **「模拟另一只手柄」还是「翻译绑定」由驱动 profile 的 `remapping` 字段决定，不是 SteamVR 那份 stub 决定**（实测 2026-10-16，用户实机）：换上 v2 的 neo3 profile（**没有** `remapping` 字段）后，Alyx 的绑定页显示「有效的控制器 = **Pico Controller**」+「此绑定已自动重映射至您的控制器」，`vrserver.txt` 成片 `[Remapping] ... oculus_touch to ... pico_controller` ⇒ 走的是**兼容翻译**，不是模拟 Oculus Touch。厂商的 `pico_controller_remapping.json` 头一条 layout 恰好是 `oculus_touch` + `simulate_controller_type: true`，但**只有那份没人加载的通用 `pico_controller_profile.json` 引用它**，neo3 profile（DP 与 v2 都实际加载它）不引用。
- ⚠️ 因此**别随手挂上那份 remapping**：它的 oculus_touch autoremappings 只映射 grip / trigger / joystick / x / y / a / b（还有两处 `/user/hand/rgiht/...` 拼错、等于无效），**没有任何 touch 子输入** ⇒ 改成"模拟 Oculus Touch"很可能会把本项目刚补回来的触摸又丢掉。
- **Alyx 的手指动画走 `skeleton` 输入，不是 capsense 绑定**（实测它的 `bindings_touch.json`：`/user/hand/*/input/skeleton/*` → `/actions/default/in/HandSkeletonLeft|Right`，整份里**没有**任何 `touch` 条目；这里的 Touch 指 Oculus Touch 手柄）⇒ 本项目补的 capsense 要变成手指动作，得靠 SteamVR 自己**合成骨架**（DP 驱动原本没实现 skeleton ⇒ 骨架输出建不出来；2026-10-16 已把 v2 的实现整段搬进驱动，见下面「骨架 / pose 补丁」）。VRChat 那套才是显式 `touch → gesture_activator_thumb/index/grip`，而 SteamVR 的自动重映射**不丢** touch（实测 `SteamVR\config\openxr\auto-remapping_{from,to}Binding.json` 只差一句 description）。
- SteamVR 的 stub profile 另有一整块 `simulation_settings`（`hmd_profile: rift`、模型号、`tracking_system_name: oculus`、`manufacturer_name: Oculus`、`legacy_buttons/axis`），厂商 profile 没有这块 —— app 眼里的「Oculus Quest 2」就是它伪造的（实测见「渲染模型层」，`temp/driver_port/scene_props_probe.py` 可复现）。**和手指没关系**：实测把 app 的模拟类型换成 `knuckles` 也没用，真凶是手序号差一位（见「真凶」一节）。
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

## 渲染模型层：游戏里手柄偏 ≈9cm —— **未解决**（实测记录 2026-10-16）

现象：**SteamVR 菜单里位置正确，游戏里偏 ≈9cm**（用户实测：现实里两个追踪环对顶，游戏里互相穿插；菜单和游戏里的位置也对不上）。

已经量清楚的事实（只读探针，`uv run --with openvr python temp/driver/{pose_probe,model_probe}.py`）：

- **普通客户端**看到的设备完全正常：`TrackingSystem=pico`、`Manufacturer=Pico`、`RenderModelName={pico}/rendermodels/pico_neo3_leftcontroller`、`ControllerType=pico_controller`。
- **Scene 应用**（= Alyx 那种）看到的是一整套冒充的 Oculus Quest 2：`TrackingSystem=oculus`、`Manufacturer=Oculus`、`ModelNumber=Oculus Quest2 (Left Controller)`、`RenderModelName=oculus_quest2_controller_left`、`ControllerType=oculus_touch`；头显也变成 `rift`。冒充来自 **SteamVR 自带的 stub** `resources\input\default_pico_controller_profile.json`（`is_stub` + `simulation_settings`），**按 app 生效**。
- app 按 `oculus_quest2_controller_left` 加载时，**拿到的几何是 PICO 的**：加载出来的包围盒 `x[-0.043,+0.051] y[-0.031,+0.068] z[-0.049,+0.126]` 与 PICO 合并网格 `pico_neo3_leftcontroller.obj` 逐位吻合（Valve 的 Quest2 是 `x[-0.032,+0.060] z[+0.020,+0.150]`）。
- **右手模型本来就是坏的**：厂商右手目录里没有 `pico_neo3_rightcontroller.obj`（v2 也没有），而 app 加载的正是它 ⇒ `loadRenderModel_async('oculus_quest2_controller_right')` 恒为 `RenderModelError_InvalidModel`（左手第二次就成功）。这是厂商包里的真实缺陷，但**不是**偏移的原因。

### 试过、都无效、已全部回滚（别再走）

| 试法                                                                                                 | 结果                                                                                                                               |
| ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| 给 profile 加 `remapping` 行 + 生成 `pico_controller_remapping.json`（关掉 `simulate_render_model`） | 只改 app 请求的**名字**、几何完全不变 ⇒ 实机无变化；还与 `compatibility_mode_controller_type` 互斥（vrserver 警告并忽略后者）      |
| 补 `grip` / `openxr_grip` / `aim` / `openxr_aim` 组件                                                | SteamVR 确实读到了（`name=grip / name=aim / …`），但 `Both grip and aim are at 0…` 照旧 ⇒ 那句话读的**不是**模型组件；偏移不变     |
| 把 `rendermodels\*\*.obj` 整体沿 Z 平移 +0.069m（对齐 Oculus 约定）                                  | **反而更糟**：菜单里的手柄也变了（说明菜单画的就是同一份 PICO 几何、而它原本是对的）⇒ **几何本来没问题**，平移等于把正确的东西挪坏 |
| 用左手镜像补上右手缺失的合并网格                                                                     | 视觉变化不可控，一并回滚；缺陷本身记录在案（见上）                                                                                 |
| 改渲染分辨率 / 换 Steam 客户端 UI                                                                    | 无关（当时看错了）                                                                                                                 |

**结论**：几何与设备位姿都是对的（SteamVR 菜单用同一份几何 + 同一位姿，位置正确），偏差出在 **app 自己那套「当我是 Oculus」的特判**里。唯一已知的杠杆是**别再把手柄冒充成 `oculus_touch`**（去掉 stub 的 `simulation_settings` / 类型模拟），代价是只带 Oculus 绑定的游戏会失去绑定 —— 用户判断代价太大，**当前选择放弃**，保持「菜单正确、游戏里偏 ≈9cm」的基线。

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

- 以 app 身份（Scene 应用）读设备属性 = 一整套冒充的 Oculus：`ControllerType=oculus_touch`、`RenderModelName=oculus_quest2_controller_left`、`ModelNumber=Oculus Quest2 (Left Controller)`、`TrackingSystem=oculus`、`Manufacturer=Oculus`（探针 `temp/driver_port/scene_props_probe.py`）。
- 但 Home 的客户端日志（`Steam\logs\vrclient_steamtours.txt`）显示它加载的**几何是 PICO 的**：`...\BusinessStreamingDP\driver\resources\rendermodels\pico_neo3_*controller\*.obj` —— 即"名字是 Oculus、几何是 PICO"（与上一节实测一致）。

**试过的改动**：删掉 `resources\input\pico_controller_profile.json` 里的 `"compatibility_mode_controller_type": "oculus_touch",`（OpenVR 文档 _Binding Duplication_：找不到 app 绑定时会用被模拟设备的 profile **并设置模拟属性**）⇒ **实测：Home 手型不变、游戏里 ≈9cm 偏移也不变**。

- ⚠️ **但这个实验其实没生效**：改完后 Home 的日志里**仍然**是 `[Input] Loaded input profile for simulated controller type: oculus_touch` ⇒ SteamVR 自带的兜底 `default_pico_controller_remapping.json` 顶上了它的位置（那一档写着 `simulate_controller_type: true`）。**所以不能据此说"偏移跟冒充无关"**。
- 想真正做这个实验得让驱动提供自己的 remapping（profile 的 `remapping` 字段指向它），并把胜出 layout 的 `simulate_controller_type` / `simulate_render_model` 关掉（保留 autoremappings 以便绑定还能翻译过去）。注意：**v2 自带的 `pico_controller_remapping.json` 里 `oculus_touch`(100) 也是 `simulate_*: true`** ⇒ "v2 没有这个偏移"这个前提本身没验过。
- 用户 2026-10-17 决定：**先不追**（手型差异无伤大雅），偏移另行调查。`patch_driver.ps1` **不**碰这一行；本机实验后已用 `restore_compat_type.ps1` 还原（该行缩进目前是 4 空格而非厂商的 2 空格，JSON 等价，下次打补丁时可顺手对齐）。

### 上一轮留下的量测结论（仍然有效，别丢）

用「以 app 身份读骨架」的探针（`temp/driver_port/app_skeleton_probe.py`，**必须 `--scene`**：后台 app 拿不到输入，所有 action 都是 inactive）+ Frida 钩我们自己搬进去的更新器（`temp/driver_port/hook_updater.py`，能强制掩码）量出来的事实：

- **每帧更新在跑**：更新器 ~200 次/秒/手；不碰键时喂进去的是 `mask=0x0000, trig=0, grip=0`。
- **驱动发出的姿势原样到达 app**：把 OpenVR 的四元数按 `HmdQuaternionf_t { float w, x, y, z; }`（**w 在最前**）读，驱动的 31 根骨与 app 读回的差 **0.00 mm**（`compare_app_bones.py`）。⚠️ 之前"运行时改写了姿势"的结论是**读法错误**：`VRBoneTransform_t.orientation` 内存里是 w 开头，按 x,y,z,w 读会得到"转了一个分量"的假象。
- **v2 的算法本身是对的**（正确读法重画 `render_v2_poses.py`）：不碰键 = **张开的手**（指尖到手腕 188mm、手指伸直），摸**扳机 / 握把** = 手指**弯**下去（指尖 158/112/90/80），摸 A/X、B/Y、摇杆顶、system 只动拇指。
- **身份/绑定与手指无关**：把 app 的模拟类型从 `oculus_touch` 换成 `knuckles`（见上一节）**没有改变**症状。
- **如果修完镜像还有问题再看这些**：① 给建组件的跳板传一份**非 NULL 的 `pGripLimitTransforms`**（`docs/notes/artifacts/make_grip_limit_pose.py` 已经能生成一份，用 v2 姿势表里"握把按下"那一帧）；② `GetSkeletalReferenceTransforms(BindPose)` 对这个骨架返回全零，若 summary 还是不对，这是下一个要解释的现象。

### 参考：各家模型的原点约定（实测，量合并网格的 z 范围）

| 模型                                     | 几何 z 范围        | 约定                           |
| ---------------------------------------- | ------------------ | ------------------------------ |
| Valve `oculus_quest2_controller_*`       | `[+0.020, +0.150]` | 原点在尖端**前** 2cm（Oculus） |
| Valve `oculus_cv1` / `oculus_quest_*`    | `[+0.02, +0.14]`   | 同上                           |
| Valve `vr_controller_vive_1_5`           | `[-0.046, +0.174]` | 原点在身体**内部**（Vive）     |
| PICO `pico_neo3_*controller`（合并网格） | `[-0.049, +0.126]` | 原点在环心                     |

（约定差异真实存在，但**不是**本偏移的原因 —— 菜单证明了这一点。）

### 其它实测补充

- `component_local` **不参与静态几何**：拿 Valve 的 `oculus_quest2_controller_left` 当对照——各零件按 `origin + rotate_xyz` 变换后与它自带的合并网格差 **11–56mm**，原样用顶点则差 **0.0mm** ⇒ SteamVR 画静态几何时不叠加 `component_local`（它只是组件位姿 / 动画枢轴）。
- **app 加载的几何 = 目录里的合并网格 `<模型名>.obj`**（不是 json 里各 `filename` 零件：零件并集的 y/z 范围与加载结果对不上）。
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

## 待办

- **游戏里手柄偏 ≈9cm：已放弃**（2026-10-16）。几何与位姿都验过是对的，偏差在 app 对 `oculus_touch` 的特判里；唯一已知杠杆是别再冒充 `oculus_touch`，代价是 Oculus-only 游戏失去绑定，用户判断不划算 ⇒ 保持基线。若哪天想再碰，先读上面「渲染模型层」的实测与已排除清单，别重走平移几何那条。
