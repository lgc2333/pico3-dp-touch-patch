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
- **Alyx 的手指动画走 `skeleton` 输入，不是 capsense 绑定**（实测它的 `bindings_touch.json`：`/user/hand/*/input/skeleton/*` → `/actions/default/in/HandSkeletonLeft|Right`，整份里**没有**任何 `touch` 条目；这里的 Touch 指 Oculus Touch 手柄）⇒ 本项目补的 capsense 要变成手指动作，得靠 SteamVR 自己**合成骨架**（而 DP 驱动没实现 skeleton ⇒ 骨架输出建不出来，见文末「待办」）。VRChat 那套才是显式 `touch → gesture_activator_thumb/index/grip`，而 SteamVR 的自动重映射**不丢** touch（实测 `SteamVR\config\openxr\auto-remapping_{from,to}Binding.json` 只差一句 description）。
- SteamVR 的 stub profile 另有一整块 `simulation_settings`（`hmd_profile: rift`、模型号、`tracking_system_name: oculus`、`manufacturer_name: Oculus`、`legacy_buttons/axis`），厂商 profile 没有这块 —— 推测「模拟成 Oculus Touch 后 SteamVR 才会合成骨架/手指」就靠它，**未实测**。
- **profile 里没声明的输入，`CreateBooleanComponent` 静默失败、句柄留 0**（驱动从不检查返回值）
- `triggertest`（`RVRPlugin.ini` 的 `[PICO] triggertest=202`）是**死配置**：全二进制只有 1 处写、0 处读

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
- 姿势源侧：DP 驱动 DLL 里 **`/pose/*` 与 `/skeleton/*` 一个都没有**（UW / v2 有 `/pose/raw` + `/skeleton/hand/{left,right}`）⇒ Alyx 的手指动画拿不到，见「待办」。

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

- **DP 驱动没实现 pose/raw & skeleton 输入**：DP / UW / v2 / SteamVR stub 四份 profile 都声明了 `/pose/raw` 与 `/input/skeleton/{left,right}`，但 DP 的 `driver_pico.dll`（669,536B）里**一个 `skeleton` 字符串都没有**，而 UW 驱动（905,216B）有 `/skeleton/hand/{left,right}` ⇒ Alyx 日志报 `Item /user/hand/left/input/skeleton/left in "skeleton" array missing path invalid device path for skeleton output`。
  表现（用户实测）：**Alyx 里手部模型正常显示**，缺的是**手指只是搭在按键/摇杆上（不按下）时**的手指动作 —— Alyx 的手指动画走 `skeleton` 输入而不是 capsense 绑定（见上面「输入声明层」），骨架输出建不出来 ⇒ 触摸没有手指反馈。这是驱动功能缺失，数据层修不了。
- **游戏里手柄偏 ≈9cm：已放弃**（2026-10-16）。几何与位姿都验过是对的，偏差在 app 对 `oculus_touch` 的特判里；唯一已知杠杆是别再冒充 `oculus_touch`，代价是 Oculus-only 游戏失去绑定，用户判断不划算 ⇒ 保持基线。若哪天想再碰，先读上面「渲染模型层」的实测与已排除清单，别重走平移几何那条。
