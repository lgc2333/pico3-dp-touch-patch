# 04.e · 手柄偏移（4cm / 10°）：从模型假设到根因（已修复）

> 总览：[04 · PC 端 OpenVR 驱动](04-driver.md)。
> 状态：**已定位并修复**（2026-10-17）。同一个偏移问题的完整记录，按调查顺序读：现象 → 早期以为是模型挂接（已证伪，取证见下）→ 标定台与两帧比对 → 改判到设备位姿 → 根因 `apprun` 与补丁。
> 结论先行：每手偏 **4.28cm / 10.29°**，来源是 host 发的 `apprun` 标志，补丁把 `call atoi` 换成 `xor eax,eax`；9.70cm 与 `handgrip` 的 `+0.097` 只是数值巧合。

## 现象与量化

现象：SteamVR 自己的面板 / 系统场景里位置正常；进入 Scene app 后，SteamVR 的等待画面和 VRChat 游戏内都出现同一方向的偏移。用户描述为两只手柄沿各自柄身朝追踪环方向偏约 9 cm：追踪环在现实中相碰时，游戏模型会互相陷入；柄尾相碰时，游戏模型之间会出现空隙。打开 SteamVR 面板时又恢复正常。

Scene app 占场景时，两只手柄的**设备位姿**各偏一段——自身系 `d=(±0.0111,−0.0093,+0.0403)`、`|d|=4.28cm`、绕自身 `∓Z` 转 **10.29°**，左右镜像；`raw` / `standing` / `seated` 三个 universe 同步变、HMD 位姿不变；静态姿势下逐位稳定（预测时间 −0.05…+0.5 s 结果相同、速度全 0）。镜像里肉眼可见两只模型并到一起。

## 早期主线：模型挂接（已证伪）

当时的假设：Scene app / 游戏把我们当成 `oculus_touch`，于是把可见模型挂到了另一套（兼容）变换上，而不是设备位姿上。下面这串事实、实验与结论都属于这条主线 —— 保留它们是为了别重走。

目前可以确认的事实：

- **Scene app 会进入兼容身份**：设备属性表现为 `TrackingSystem=oculus`、`Manufacturer=Oculus`、`ModelNumber=Oculus Quest2 (Left Controller)`、`RenderModelName=oculus_quest2_controller_left`、`ControllerType=oculus_touch`，头显身份也会变成 `rift`。这说明 `oculus_touch` 兼容路径确实是触发条件之一；它还没有被证明就是产生 9 cm 的具体函数。
- **模型名不等于实际几何**：日志和用户截图都表明，偏移时看到的仍是白色 PICO 模型。`oculus_quest2_controller_*` 这个名字在 Scene app 中会被兼容层解析到 PICO 的资源；不能把现象描述成“实际换成了黑色的 Valve Oculus 模型”。
- **设备 pose 没有 9 cm 的整体平移**：Background / Scene 对照、手柄贴地测试，以及后续在 Alyx 进程内读取 raw、legacy 和 `HandPose` action，均只显示零点到亚毫米级的差异。后者是单帧验证，足以否定简单的设备 pose 偏移，但不等于已经定位了应用的模型矩阵。（**后被推翻**：真 Steam 游戏占 scene 时位姿确实偏 4.28cm；当时读的是没有游戏在跑的 Background 态，见「改判」。）
- **DSH 现场对照进一步把两条路径分开**（2026-10-17）：用户在同一轮切换 compositor 与游戏/等待封面时确认“1.没偏，2.贴”——标尺/客户端 pose 没偏，compositor 的白色 PICO 模型贴合实物；切回 Scene app 或 VRChat 后模型再次沿柄身朝环方向偏。用户还确认问题在骨架移植之前、原装 DP 驱动下就存在。因此这不是触摸位、骨架补丁或 compositor 设备 pose 的新回归，排查重点应保持在 Scene app / 游戏的模型挂接矩阵（**这条推断后来被证伪**：真正动的是设备位姿，见下文「改判」）。
- **模型组件值本身不是单独原因**：`body` 归零、`handgrip` 归零，以及补齐 `openxr_grip` 后重启验证，用户都确认视觉偏移没有变化。补齐 `openxr_grip` 后，暖机探针确实能读到约 `+10.19 cm`，所以“值没传到应用”与“应用不使用该值”必须区分；目前只能排除它是本问题的充分修复。
- **头显高度旋钮不是手柄偏移来源**：改变 `RVRPlugin.ini` 的 `initialOffsetY` 能改变 HMD 高度；Room Setup 也能改善 HMD 高度，但手柄模型偏移保持不变。
- **原装 DP 驱动也能复现**：因此触摸位补丁和骨架补丁不是这个视觉问题的根因。
- **Alyx 的兼容设置与模型渲染直接相关**：DP legacy binding 的 `simulate_rendermodel=true` 与 `simulated_controller_type=oculus_touch` 是当前最具体的可疑开关；IDA 中 `vrclient_x64.dll` 的 `sub_180171880` 会读取 `simulate_rendermodel`，并由后续组件路径逻辑决定是否走模拟模型分支。它仍未证明是哪一个矩阵产生 9 cm，只把实验入口从“随便平移 OBJ”收敛到了兼容渲染模型路径。
- **IDA 已把这个选项拆成三档**：`sub_1802AB800` 将 `false` / `none` 解析为 `0`，`true` / `name_only` 解析为 `1`，`full` 解析为 `2`；`sub_18016FD20` 只有在返回值为 `2` 时才向原设备请求 `GetOriginalComponentPath`。因此不能再把 JSON 里的 `true` 当作单纯布尔开关，也不能把 `simulate_rendermodel=false` 直接等同于“改回原生 PICO 模型”。
- **已完成 OpenVR 层 A/B，尚未完成游戏视觉 A/B**：用户目录克隆中只把 `simulate_rendermodel` 改为 `false`，重启 SteamVR 后仍返回 `oculus_quest2_controller_*` 兼容名和 PICO 零件路径；把 `simulated_controller_type` 改为 `none` 或 `pico_controller` 后，兼容名立即变成 `{pico}/rendermodels/pico_neo3_*controller`。这证明 Oculus 身份来自 `simulated_controller_type` 这条 legacy 选项；但 `pico_controller` 会改变只带 Oculus 绑定的游戏的输入身份，不能直接作为补丁方案，也不能据此断言 9 cm 已由它直接产生。三次实验均已恢复原 `openvrpaths.vrpath`，安装目录文件没有被改写。
- **同一 A/B 还排除了“兼容模型名直接改了组件原点”**：`simulated_controller_type=oculus_touch` 与 `none` 两次都返回 15 个 PICO 组件、相同的 PICO 零件路径，以及相同的 `mTrackingToComponentRenderModel` / `mTrackingToComponentLocal` 平移（例如 `body` / `handgrip = [0, 0.003, 0.097]`）。变化只有设备身份和 `RenderModelName`（Oculus 名 vs `{pico}` 名）。因此 9 cm 若仍只在 Scene app 出现，候选更接近 app 侧的兼容绑定或最终父节点矩阵，而不是 `component_local` 被 Oculus 名单独改写。
- **当前最强但尚未证实的假设是 pose action 语义错配**：SteamVR 的 Oculus 兼容 profile 明确声明 `/pose/handgrip` 和 `/pose/openxr_grip`；PICO 模型的 `handgrip` 恰好是本地 `+0.097 m`。常见 Unity `SteamVR_RenderModel` 源码把网格子节点放在 `mTrackingToComponentRenderModel`，只把 `mTrackingToComponentLocal` 写到 `attach` 点；若 Scene app 用模拟 Oculus 的 handgrip/openxr grip pose 作为模型根节点，就会得到“模型几何没有变、设备 raw pose 正确、app 里固定约 9 cm”的组合。现有专门 action 探针没有建立有效 origin，所以这仍是待验证假设，不是根因结论（后来的改判与它无关：见「改判」）。

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

### 当时的结论（后续已推翻）

现阶段只能把根因定位到：**出问题的 Scene app 控制器模型渲染路径，与 SteamVR 面板路径使用了不同的模型挂接 / 兼容变换**。自制 Scene app 的标准 render-model 分支不会自然偏移，只有故意把 `component_local` 当可见根才出现 9.70 cm；VRChat 的 OVRPlugin 路径又证明应用会在模型加载后自行写父节点局部变换。`oculus_touch` 特判仍是高相关线索，但“真实游戏具体哪一层矩阵、哪一个函数加了 9.70 cm”仍未定位。

因此暂时不要把“应用硬编码偏移”或“只需把零件 OBJ 平移精确数值”写成定论。下一步应在真实游戏进程中捕获 render-model component state、应用创建的模型父节点和最终绘制矩阵，再与 compositor 的同一帧结果对照；继续改 `body`、`handgrip`、`openxr_grip`、地面高度或几何文件，只会重复已经做过的实验。

> 2026-10-17 晚复盘：真因不在渲染模型 —— 驱动被 host 的 `apprun` 标志给位姿加了一段修正（每手 4.28cm、绕自身 `∓Z` 转 10.29°）。上面「应继续追模型父节点矩阵」的方向就此作废，保留这段只为记住做过的实验；继续读下面的「翻案」与「根因」。

## 取证：逐层排除「像是根因」的候选

这条主线做过的取证，每个候选一段，结论都是**排除**。

### 0.097m 是资源坐标候选，不是已定位的加法点

- PICO Neo 3 的 `pico_neo3_leftcontroller.json` / `rightcontroller.json` 中，`body.component_local.origin` 与 `handgrip.component_local.origin` 都是 `[0.0, 0.003, 0.097]`；`base` 则是 `[0.0, -0.014, 0.174]`。相同数值也存在于 v2 资源。SteamVR 备份的 Oculus legacy JSON 中，`body.component_local.origin` 是 `[0.0, 0.0, 0.0]`，而 `handgrip` 仍是 `[0.0, 0.003, 0.097]`。这使“Scene legacy 路径把 PICO body 资源坐标当模型根，却没有按预期应用 component-local 语义”成为与用户观测完全对齐的候选：数值、方向和现象中的约 9.7cm 一致。
- 这条候选不能写成根因：把 PICO JSON 的 `body` 或 `handgrip` 原点归零并完整重启后，用户视觉上仍报告同样偏移；因此至少有一层缓存、父节点或 app 侧挂接语义没有被该 A/B 改到。OBJ 的 DP/v2 版本也不是统一平移 97mm，不能用“把所有顶点平移 0.097m”替代定位。
- IDA `vrclient_x64.dll` 的 `sub_18016C2D0`（`GetComponentStateForBinding` 路径）会先把输出的 3×4 状态清为单位矩阵，再依据 `OriginInfoList` 解析 render model、component 和 input source，最后调用输入服务虚表取得状态；函数自身没有 0.097m 常量或矩阵乘法。`sub_1802C0040` 解析 `component_local` 时只把 `origin` / `rotate_xyz` 保存到组件结构（`origin` 位于该结构偏移 `+472`），本函数也没有应用平移。因此下一步应追 `+472` 结构字段的读取者，以及真实 Scene app 的最终父节点矩阵，而不是继续改 JSON 原点。

### 已排除：`mTrackingToComponentLocal` / Scene 挂接（死路，别重走）

- 当时的假设：Scene app 把 `mTrackingToComponentLocal`（`[0,0.003,0.097]`）当作可见模型根，就会精确多出 9.70 cm。用一次性 Scene 探针验证过——把 local 矩阵当模型根确实能在真正的 compositor 帧里复现 9.70 cm 分离；而 Valve 的 Unity helper（`SteamVR_RenderModel.cs`，已核对过源码，副本不必留）也不会这么用：它把 `mTrackingToComponentRenderModel` 写给可见子节点，`local` 只喂 `attach` 点。
- **真根因不是它**：实测两态下 12 个组件的 `mTrackingToComponentLocal` **逐字节相同**，变的是**设备位姿**（每手 4.28 cm / 10.29°），来源是 host 发的 `apprun` 消息（见下文「根因与修法」）。9.70 cm 与 `handgrip` 的 `+0.097` 只是数值巧合。
- 相关的一次性 Scene 探针与那份 `.cs` 副本都已随这条死路一起删掉；要重看「local 当模型根」，用 `GetComponentStateForDevicePath` 取矩阵相乘即可，不值得留脚本。

### VRChat/Unity OVRPlugin 的应用侧模型路径（2026-10-17）

- VRChat `GameAssembly.dll` 中的 `sub_1872FD420(a1, a2)` 先调用 `sub_1872AF7A0`（包装 `ovrp_GetRenderModelProperties2` / `ovrp_GetRenderModelProperties`）和 `sub_1872AFCF0`（包装 `ovrp_LoadRenderModel`），再创建 Unity 对象并写入 `Transform`。它只有一个上层调用点：`sub_1872FE0E0+0x4AD`，说明这不是通用 SteamVR C# helper 的被动结果，而是 VRChat 自己的渲染模型构建路径。
- 模型加载成功后，`sub_1872FD420` 通过 `UnityEngine.Transform::set_localPosition_Injected` 写入常量本地位置 `(0, -0.03, -0.04)` m；随后调用 `UnityEngine.Quaternion::AngleAxis_Injected`，再用 `set_localRotation_Injected` 写入本地旋转。这证明应用端在拿到 OVRPlugin 模型后还会自行挂接一层局部变换。
- 这组平移的长度约 5 cm，不能直接解释运行时稳定测得的 9.70 cm；目前也没有把该函数的父节点、输入手序号和最终绘制矩阵连起来。因此当前结论是：**应用侧存在独立模型父变换，且 VRChat 的 OVRPlugin 路径值得继续抓取；但 9.70 cm 的具体加法点仍未定位。**
- 与之相对，SteamVR `vrclient_x64.dll` 的 IDA 交叉引用显示，`component_local` 的 `+472/+496` 只进入 `GetComponentState` 和合成 pose；render-model template/cache 构建路径不读取这些字段。故不能把 `component_local` 直接写成“SteamVR 可见网格根被改写”的定论。
- **运行时命中仍未证明**：GameAssembly 还包含 `ovrp_GetRenderModelProperties(2)`、`ovrp_GetRenderModelPaths`、`ovrp_LoadRenderModel` 的动态解析包装（例如 `sub_1872C6540`、`sub_1872C42F0`、`sub_1872C4250`），但这些包装没有静态直接 caller，疑似由 IL2CPP 方法表间接分派。`OVRPlugin.dll` 的导出本身只是转发到 `CompositorCAPI` 虚表槽 230/231；当前检查到的 D3D11、D3D12、OpenGL、Vulkan 对应实现均为 `return -1002`（unsupported）。因此上面那段 GameAssembly 代码只能记录为“静态存在的候选 app 路径”，不能当成 VRChat 在 OpenVR 会话中一定实际使用的模型加载链。日志里的 `RendermodelManager` 仍需用运行时 API/调用栈确认其真正入口。

### 日志对「兼容身份」和「实际资源」的区分（2026-10-17）

- `vrclient_VRChat.txt` 的一轮完整启动（05:23:26–05:23:27）先记录 `Loaded input profile for simulated controller type: oculus_touch`，并对两只手柄执行 `Simulation ... override properties for oculus_touch`；随后 `RendermodelManager` 以 `oculus_quest2_controller_left/right` 作为模型名，却从 DP 的 `pico_neo3_leftcontroller/rightcontroller.json` 读取，并加载对应的 `left_*.obj` / `right_*.obj`。这证明“兼容身份名”和“实际几何资源”是两层，白色 PICO 模型并不能排除 app 侧兼容变换。
- 同一进程退出后又重新读 `{pico}/rendermodels/pico_neo3_*controller`，说明模型名会随 app/绑定上下文切换；它不是固定的驱动资源替换。
- 当前 `vrclient_vrcompositor.txt` 与备份中，控制器模型记录是 `{pico}/rendermodels/pico_neo3_*controller`，没有 `oculus_quest2_controller_*`。因此“compositor 自己加载了 Valve Oculus 几何”目前没有本机日志支持；此前相关说法应视为误归因。能看到 Valve Oculus JSON 的是 binding-callouts/overlay 类日志，不能拿来代表主控制器渲染路径。
- 这与用户的状态切换完全一致：打开 Dashboard 时走 Dashboard/compositor 的 PICO 路径；关闭后进入等待封面或游戏 app client，才触发 `oculus_touch` 模拟和另一套 app 侧模型挂接。它仍不能单独证明哪一个矩阵加了 9.70 cm，但已经排除了“只改 PICO OBJ 或 compositor 资源选择就能解释全部现象”。

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

## 翻案 ①：先把网格与姿态量出来（2026-10-17 晚）

之前只能从截图推断「模型整体平移 9.7cm」；这轮把网格和姿态的关系做成了可测的：

- **网格长轴与 +Z 的关系已定死**：`left_body.obj` 占 `x[-0.040,+0.048] y[-0.005,+0.085] z[-0.031,+0.136]`；沿 z 的剖面里 `z[-0.031,+0.02]` 是最大半径 0.085 的「环 + 面盘」区，`z[+0.02,+0.136]` 收窄到 0.044→0.028 的柄身区，且空心判据只在 `z[+0.015,+0.030]` 出现 40% 空芯（环的截面）。⇒ 模型原点位于**环—柄交界**，柄身朝 **+Z** 伸出约 13.6cm，`body`/`handgrip` 的 `+0.097` 落在柄身靠末端。
- **世界方向已用运行时标定**：一个一次性的标尺探针（不入库）沿控制器自己的 +Z 摆一列彩色刻度（`-6/-3/0/+3/+6/+9.7/+13/+16cm`，蓝→青→绿→黄→品红→橙→红），并把「设备姿态原点」和「+9.7cm 点」投影到左眼视口记账。同一帧里用 SteamVR 自带「VR 视图」镜像核对：刻度 x 随 z 单调递增，且与 compositor 白模型的柄身方向一致 ⇒ **模型 +Z = 柄身 = 朝环外**，`mTrackingToComponent*` 的 0.097 方向与用户描述的「偏」方向可以做符号判断。
- **镜像视口映射不能想当然**：镜像窗口不是 1:1 的眼缓冲（实测把日志里的视口坐标线性映射到窗口像素后，左右手残差不同）。要在镜像里做逐点量测，必须先用一列已知位置的标尺色块反解「缩放 + 偏移」，不能直接用 `getProjectionMatrix` 的结果换算像素。
- **镜像同时画 compositor 内建模型与 app 帧**：`vrmonitor` 的「VR 视图」在「无 Scene app」和「SteamVR Home 持有 Scene 焦点」两种状态下，compositor 的控制器模型位置逐像素一致（阈值 40 的差分只剩 2763 px，全是抗锯齿/抖动）⇒ 那两张图里画的是 compositor 的内建模型（`{pico}` 路径），和用户口径一致：compositor 那条一直是对的，偏的是 app 那条。**但镜像本身不是「只画 compositor」**，见下一条更正。
- **更正（同日）：镜像是可以显示 Scene app 帧的** —— 只要 app 真的在提交。判据：最小 Scene app 把双眼涂成品红后，镜像里品红占 69650/131k 采样点。之前几次「镜像只看得到 compositor 模型」是因为捕获时 app 已经退出（帧数跑完）。⇒ **用镜像量测 app 侧渲染是可行的**，前提是①捕获必须在 app 运行期间；②别用「窗口置顶」截图（会打断用户），改用 `PrintWindow`（见下条）。
- **无人值守抓镜像的办法**：一个一次性的抓窗脚本（`PrintWindow(PW_RENDERFULLCONTENT)`，按 `-Hwnd <hwnd>` 指定窗口）可以在**不抢前台**的情况下抓到「VR 视图」窗口，窗口被遮挡也没关系；`-Foreground` 才置顶。注意窗口 hwnd 会变（`SteamVR 状态` 与 `VR 视图` 都在 `vrmonitor.exe` 下），抓之前先用 `Get-Process | ? MainWindowHandle -ne 0` 复查。
- **位置对照标尺（本次新增的定量工具）**：一次性 Scene 探针的 `--mode ladder` 模式会在同一帧里把同一个手柄网格画 7 份，沿模型 +Z 分别偏移 `-9.7 / -5 / -2.5 / 0 / +2.5 / +5 / +9.7 cm`，颜色 `红 / 橙 / 黄 / 灰 / 绿 / 青 / 蓝`，其中**灰色＝compositor 的摆放（设备姿态 + 单位阵）**。镜像里已确认 7 份都能渲染。游戏里模型与哪一份重合，就直接读出偏移量与符号 —— 这是目前唯一能把「app 侧偏移」变成数值的仪器。
- **地面高度反推原点位置不可行**：遍历网格所有「贴地」朝向（绕 z/x 各 15° 步进）后，原点离地高度的取值覆盖 `0.5–12.9cm`（中位 5.65cm）⇒ 用户测到的 `Y=+0.0575` 无法判别姿态原点对应实物哪个点，别再拿这条数据做结论。
- **原点在实物上的位置（体积加权，双手机械对称）**：`*_body.obj` 体积 137.8cm³、体积重心 `z=+0.0462`（轴向 46.2%）；**原点是整个几何里离 -Z 端最近的点，位于轴向 18.5%、柄身半径最低处**（`z=0` 的顶点只剩 439 个）。体积沿 z 的分布是两端重（28.1% / 36.3%）中间轻 —— 环在一端、柄身朝 +Z 收窄到 12.6cm 处，与镜像里「柄身朝 +Z、环在 -Z」一致。⇒ **姿态原点落在环—柄交界（环根），而手掌实际握在柄身中段（z≈+0.05~0.09）**，两者相距约 5–9cm，量级正好覆盖用户报的 9.7cm。
- **截面「实心度」再确认一次形状**：按 z 逐层求表面与平面的交线并算包围盒填充率，`z≤+0.013` 的层宽 8.6–8.8cm（环），`z≥+0.023` 骤降到 5.4cm 并一路收窄到 2.1cm（柄身）⇒ **环只占 z∈[-0.031,+0.013]，柄身从 z≈+0.013 一直到 +0.136**；手握点（体积重心 +0.046、`button_grip` 网格 +0.060~0.079）落在柄身中段，和模型自己声明的 `handgrip=+0.097` 差 2–4cm（模型声明值比实测握点更靠柄尖）。
- **姿态源侧的数值（旧探针实测，别读错列）**：旧的 pose 路径探针（`--oculus-only`、跑在 Scene app 里）的结论是 **`raw` / `legacy` / `openxr_grip = 0.00cm`、`handgrip = +9.70cm`、`base = +17.46cm`、`tip = +1.22cm`**（相对设备姿态）。⇒ **驱动报的设备姿态原点与网格原点同为一点，握把/`base` 都在它前方（+Z）**，两者内部自洽；这也解释了为什么「把 `handgrip.origin` 归零」改不动视觉偏移（那只挪动握把点，不挪网格）。
- **为什么「compositor 对 / app 偏」这条对照无法判别**：两条路都把网格摆到「设备姿态原点」上（compositor 用设备姿态，app 用 `device * mTrackingToComponentRenderModel(=单位阵)`），差值恒为 0。所以「哪一侧对」实际取决于**实物握把相对姿态原点的位置**这个外部事实：若原点在环根而握把在 z≈+0.05，则「app 偏」与「compositor 偏」在数据上不可区分，必须用实物指认来破对称。
- **另一个同源实测**：另一个一次性探针在 `VRSkeletalMotionRange_WithController` 下读骨架，`j0` 恒为 `(0,0,0)`、`j1/j2` 是固定的小偏移（约 `±0.034, +0.037, +0.165`），与设备位姿相差 130cm 以上 ⇒ **骨架返回的不是世界坐标，不能用它来判定手的位置**（那次「骨架根偏多少」的猜想就此作废）；要测手的位置得换 `GetSkeletalReferenceTransforms` 或走 app 侧。
- **下一个最小实验（一次指认即可破对称，探针已就绪）**：戴着头显、正常握住手柄，报「彩色刻度梯里**哪一格压在掌心/握把上**」。刻度梯为 `蓝 -6 / 青 -3 / 绿 原点 / 黄 +3 / 品红 +6 / 橙 +9.7 / 红 +13cm`。
  - 若答案是「**绿（原点）**」⇒ 驱动姿态与网格一致，9.7cm 来自 app 侧的模型挂接（继续追 `+472` 的读取者与 app 父节点）；
  - 若答案是「**品红/橙（+6~+9.7）**」⇒ 网格原点与实物握把差 9.7cm，修法是把网格与 `component_local` 一起平移 −9.7cm（面板与游戏会同时对齐）。
- **仍缺的唯一量**：驱动报的姿态原点落在实物上哪个点（环交界 / 柄身中段 / 掌心）。标定探针已经把这道题变成「戴上看哪一格压在掌心」，不需要再改 JSON 或长方形网格。

## 翻案 ②：WebXR 标定台（可直接读数）

自制了一个最小的 WebXR 页面 + 一个能用 CDP 操作它的脚本（都不入库），静态服务起在 `127.0.0.1:8010`：

- **不需要人点 ENTER VR**：Chrome 带 `--remote-debugging-port=9333` 起一个独立 profile，脚本用 CDP `Input.dispatchMouseEvent` 点 `#VRButton` —— 这是**可信点击**，`requestSession()` 的用户激活条件满足；随后读 `window.__probe.state()` 的 `presenting / tracked / frames`，不必再问用户「进去了没有」。
- **别用 `renderer.xr.getControllerGrip(i)` 量姿态**：本机 Three.js r169 下若在 session 起来之后才创建，grip 的 `matrix` 恒为单位阵（`position` 全 0，镜像里模型落在原点），换成自己按 `XRFrame.getPose(inputSource.gripSpace, referenceSpace)` 写 `Group.matrix` 才准（页面里就是这么做的）。
- **镜像能直接看 WebXR 帧**：用同一个一次性抓窗脚本（`-Hwnd <VR 视图>`，`PrintWindow`，不抢前台）即可，和抓 compositor 是同一套；SteamVR 的 "VR 视图" hwnd 会变，先枚举 `vrmonitor.exe` 的窗口。
- **标定结果（用户现场指认）**：以 grip 空间为原点、沿模型自身 +Z 摆 `-19.4 / -9.7 / 0 / +9.7 / +19.4 cm` 五份，**`-9.7`（绿）＝ 正确位置 ＝ compositor 的摆放**；更往里（`-19.4`）已被用户否掉，不是游戏里的位置。⇒ **网格要落在 grip 空间原点往后 9.7cm 处才对**，也就是「网格挂到手柄空间原点」这一档（0）恰好偏出 9.7cm —— 与用户报的偏移量、与 JSON 里 `handgrip=+0.097` 同一个量级，方向为「朝环 / 往上」。
- **下一步只差一次物理指认**：页面现在只留两份（**白 = 挂手柄空间原点**、**绿 = 正确**）。把两只手柄的环怼在一起，看白的模型是否像游戏里那样互相陷进去；是则「游戏把模型挂到了 grip 姿态而不是设备姿态」成立，接着追 Scene app 侧拿到 +9.7 的那个位姿源（`/pose/grip` vs 设备姿态），而不是再动资源。

## 翻案 ③：游戏自身两帧的定量比对（20:1x，用户现场截图）

用户给了同一姿势下的一对截图（`正常位置` = 无 drift / `不正常位置` = Scene app 等封面时）：

- **相机没动**：两帧天空带与地面带逐像素平均差 `0.40 / 0.09`（/255），山区带的大差异全来自手柄模型本身 ⇒ 可以把手柄的像面位移直接当成模型漂移。
- **正常帧是两个独立连通块，漂移帧并成一个**：白模型的连通域在正常帧是 `n=17886` 与 `18814` 两块，漂移帧合并成 `n=28675` 一块（bbox `x[459,859]`）⇒ 漂移让两只模型在像面上真的叠在一起（用户说的 overlap 有了像素级证据）。
- **漂移方向 = 各自朝内**：正常帧两模型 bbox 外缘 `392 / 920`（跨度 528px），漂移帧 `459 / 859`（跨度 400px），每只向内缩 ≈64px；高度 145→159 略长。⇒ 每只模型沿「自己柄身朝环」方向位移，横向分量约 3–4cm，其余在深度里（模型变长/变近）。
- **因此 sweep 探针的范围是对的**：另一个自制页面（不入库）让白色模型沿模型自身 +Z 连续扫 `-30 … +10cm`，绿色 22% 透明度参考固定在 `-9.7`（= 正确 = compositor），**扣扳机冻结**并把冻结值写进 `window.__probe.state().history`（CDP 可直接读，不需要用户读数）；冻结再扣一次继续扫。
- 待定：漂移的**精确标量**（用户现场扣一次扳机即可；下一节用真游戏量出是 4.28cm）。已知它朝环方向、量级 3–9cm，且 `-19.4` 已被用户否掉 ⇒ 真值大概在 `-0.097` 与 `-0.194` 之间，不能直接套用 `handgrip` 的 9.7。

## 改判：漂移在**设备位姿**，不在渲染模型（20:2x）

用真游戏复现成功（HL:Alyx appid 546560，`steam://rungameid/546560` 拉起后 `hlvr.exe` 一出现即进入漂移态）：

- **和用户两张截图的数字逐项吻合**：正常帧两个白色连通块 `n=18128 / 18968`、外缘跨度 **528px**；漂移帧并成一块 `n=28813`、跨度 **400px**（用户那对是 528/400 与 17886/18814/28675）。背景天空带逐像素平均差 `0.073/255` ⇒ 相机没动，可以逐像素比。
- **确定性 A/B**：杀 `hlvr.exe` 后 8 秒再抓，两个连通块与外缘坐标**回到原值**（`400..661 / 668..928`，跨度 528）⇒ 漂移随「游戏占着 scene」开关，不是手抖、不是追踪漂移。
- **关键改判（推翻「模型挂接矩阵」这条主线）**：同一个静态姿势下，用 `VRApplication_Background` 探针（一次性脚本，不入库）读 `getDeviceToAbsoluteTrackingPose`：
  - 正常：L `(+0.03608,+0.60136,-0.27770)`、R `(+0.10133,+0.59220,-0.26753)`
  - 游戏加载中：L `(+0.07864,+0.60547,-0.27497)`、R `(+0.06079,+0.59870,-0.25529)`
  - 每只手位移 **4.28cm**；换算到**手柄自身坐标系**是 `(±0.0099, +0.0115, -0.0401)`，同时姿态整体转了 **10.29°**（转轴在自身系里 ≈ `(0,-0.096,+0.994)`，即沿柄身轴 + 一点 Y）；左右手镜像对称。
  - **头显位姿完全不变**（`+0.07053/+0.71034/+0.13816` → `+0.07077/+0.71035/+0.13802`）⇒ 不是 universe origin 平移，是**逐设备**的位姿修正。
  - 杀游戏后再读，数值**逐位回到**正常值 ⇒ 是一个确定性的固定刚体变换，不是噪声。
- ⇒ **模型本身没动，是喂给渲染器的位姿动了**。这解释了为什么所有资源侧改法（`body`/`handgrip` 原点归零、换模型名、补组件、平移 OBJ）都没用：它们改的是几何，而错在 pose。历史上的「9.7cm = `handgrip` 偏移」是**数值巧合**；真实每手漂移是 4.28cm，两只手柄相对位置偏 8.6cm，正好对应 `528→400px`。
- **触发条件不是「声明 oculus 绑定」**：自制 Scene app 用 oculus-only manifest（一次性脚本，不入库；日志确认 `[Simulation] ... oculus_touch`、`type=oculus_touch`）占着 scene 时，位姿**逐位不变**、镜像里也不漂。⇒ 真 Steam 游戏（有 appid / vrmanifest、走 `vrclient_x64.dll`）还做了别的事才会触发这段修正。这是当时下一个要定位的点（下文「根因与修法」已定位：`apprun` 标志）。
- **日志侧已定位到「兼容/重映射」这条链**（`Steam\logs\vrserver.txt`）：`steam.app.546560` 连接后立刻出现
  - `[Input] steam.app.546560 (pico_controller) attempting to load default config from .../hlvr/cfg/bindings_touch.json`（Alyx 自己的 **oculus_touch** 绑定）
  - `[Remapping] Beginning remapping from controller type: oculus_touch to controller type: pico_controller` → 成功
  - 而 `pico_controller_profile.json` 里写着 **`"compatibility_mode_controller_type": "oculus_touch"`** ⇒ 「没写 pico 绑定的 app 自动当 Oculus Touch」是驱动自己声明的，重映射与模拟都由此而来。
- **下一步（按性价比排序）**：①把 Alyx 的 `bindings_touch.json` 当作自制 manifest 的 `oculus_binding` 再跑 standby 探针，看位姿是否跟着变（能一次性锁定是不是这份绑定/重映射引入的修正）；②换第二个游戏（VRChat / The Lab）看是否同样触发，确认是通病而不是 Alyx 特例；③若确认在重映射里，就去 `vrclient_x64.dll` 追 remap 的 pose 分支（上文「早期主线」里 `simulate_rendermodel` 的三档线索在 `sub_1802AB800` / `sub_18016FD20` 附近）。

## 根因与修法：`apprun` 标志

**根因链**：Steam 启动游戏 → PICO PC 侧 host 通过本机 socket 反复发 `apprun <n>` → `driver_pico.dll` 的收包线程 `sub_18002CE90` 用 `atoi` 写入全局 `dword_18009B080`（RVA `0x9B080`）→ 位姿发布函数 `sub_180018340` 读这个标志，给 `DriverPose_t` 多加一段 → 客户端读到的就是偏的。`apprun` 在整个 DLL 里只有这一处消费，所以补掉它不影响串流画质等其他行为。

**取证**

- **免游戏复现**：`IVRApplications::identifyApplication(pid, "steam.app.<已安装id>")` 把空进程挂到某个已安装 Steam 应用上，约 2 秒内进入漂移，进程退出即恢复。换 `openvr.tool.steamvr_room_setup` 这类工具 key 不触发 ⇒ 只有被当成「Steam 游戏」才偏。
- **发布函数入口/出口成对取值**：输入 `(+1.01164,+0.55034,+1.08921)` 两态**一字不差**，写出的 `vPosition` 不同（`+0.97067,…` vs `+0.92877,…`），而出口值就是客户端读到的值 ⇒ 偏移由驱动产生，vrserver 只转发。
- **整个 `.data`（10.7 KB）两态只差两处**，其一是 `0x9B080`（0→1）。
- **闭环**：漂移态下每 5 ms 把该标志写 0，位姿立刻回到基线（`+0.90857/+0.97067`），停止写入又回漂移。

**修法**：`patch_driver.ps1` 把写标志前的 `call atoi` 换成 `xor eax, eax`（零长度变化）⇒ 标志恒 0。验证：identify 测试 **4.28 cm → 0.04 cm**；The Lab 运行中位姿保持基线、两只模型分开。

## 已排除（都有数值或 A/B 证据，别再试）

- **不是 vrserver**：两态下驱动喂入的 `DriverPose_t`、`.data` 全局、设备属性集全部一致，vrserver 只转发；`simulate_rendermodel`、`compatibility_mode_controller_type`、`simulated_controller_type`、Valve 的 priority-95 `simulate_*` 布局逐项 A/B 均为负。
- **不是模型挂接**：两态下 12 个组件的 `mTrackingToComponentLocal` **逐字节相同**；把两份 rendermodel 的 13 个 `component_local` 全部归零后漂移**一字不差** ⇒ 几何 / 组件原点 / 模型名这条路原理上不可能修好它。9.70 cm 与 `handgrip` 的 `+0.097` 只是数值巧合。
- **不是本项目的补丁**：换成厂商原版 `driver_pico.dll.orig`（无 `.pitouch`）照样漂。
- **不看控制器类型 / profile**：把 `pico_controller` 等长改名（DLL 三处 + profile）后照样漂。
- **不是预测外推**：−0.05…+0.5 s 各预测一遍结果完全相同、速度全 0。
- **不是 `vrlink`**（Steam Link 驱动）：虽加载并连着头显 IP，但从未建立会话（`Null VTE_CLIENT_SESSION_ID`）。**不是 `app_check.exe`**：连续 kill 不影响。
- `[poseFeeder] initialOffset*` 只影响头显高度；`debug.log` / `sendlog*.txt` 不含位姿数值。

## 旁证与方法论

**公开资料对上了**：[SteamVR 论坛「Offset problems using Pico 4 controllers」](https://steamcommunity.com/app/250820/discussions/0/3828666917400432090) 里 PICO 用户描述「in game hands are being offset and appearing at the wrong angle」「It starts from the tip of controllers and angled」，与实测的 **4.28 cm + 10.29°（不是单纯平移）**逐条吻合；那边把控制器显示成 Quest 2 手柄后偏移消失，本质也是换了位姿约定。

**两个方法论坑（下次省时间）**

- 只 hook 发布函数的**入口**会得出「驱动没变」的错误结论——必须入口 + 出口成对取值。
- `identifyApplication` 之后漂移态会**卡住**（vrserver 一直以为应用在跑）；每次测量前重启 SteamVR，并先打印一次基线位姿确认（`dev2.x≈+0.97067` 干净 / `≈+0.92877` 已卡住）。
