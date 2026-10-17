# 04.f · 手和模型的解耦：握把位姿（2026-10-18）

> 总览：[04 · PC 端 OpenVR 驱动](04-driver.md)。
> 状态：**已定稿，实机验证**。
> 由来：04.e 修掉「游戏里手柄偏 4.28cm / 10.29°」之后，暴露出另一个问题——VRChat / The Lab 里虚拟手不在手心、手臂伸不直。本篇只记这一条；4.28cm / 10.29° 的来龙去脉见 [04.e](04_e-driver-offset.md)。（下文 `device pose` = 驱动发布给所有消费者的手柄位姿；`/pose/raw` 就是它。）

## 现象与判据

- 应用里：虚拟手（VRChat 的 avatar 手、The Lab 的机器人手）落在手柄柄尾 / 下方，手柄模型浮在手心外；手腕处的 IK（反解手臂的逆运动学）显得短一截（「手伸不直」）。
- SteamVR 面板：模型和实物对位正常（说明 device pose 本身没漂）。
- `apprun` 补丁（见 [04.e](04_e-driver-offset.md)）前后都在；补完之后反而更明显——那 4.28cm 正好把手往外推了一点，把问题盖住了一半。

## 根因：手和模型吃的是同一个 device pose

- **VRChat 的手 = legacy device pose**（不走 SteamVR Input 动作绑定、直接读设备位姿的老路径）：`bindings_oculus_touch.json`（VRChat 的 SteamVR 绑定）里 pose 绑 `/user/hand/*/pose/raw`（raw = device pose），但 `vrclient_VRChat.txt` 里记着 `app appears to not be using SteamVR Input`；改绑 `handgrip`、加 SteamVR `pose_offset` 都没让手相对模型动（`device_offsets` 则是把两者一起移，相对位置不变）⇒ 手不是从 SteamVR Input 的 pose 来的。
- **手柄模型 = 同一个 device pose + OBJ 顶点**：`component_local.origin` 只影响 pose / 挂接点，不参与网格摆放（实测：把 `body` 的 `component_local.origin.z` 从 0.097 改成 0 并重启 SteamVR，渲染网格一动不动）。
- 驱动把 device pose 报在**跟踪环附近**；握把在柄身 `+Z` 约 9.7cm 处。手按 device pose 抓握，就落在环附近，比握把低 / 前一截。

## 试过、无效（别再走）

| 试法                                                                 | 结果                                                   |
| -------------------------------------------------------------------- | ------------------------------------------------------ |
| `component_local.origin`（`body.component_local.origin.z: 0.097→0`） | 渲染网格不动 ⇒ 只影响 pose / 挂接点，不能移模型        |
| VRChat 改绑 `pose/handgrip`                                          | 手动没动（app 不吃这条 pose）                          |
| SteamVR `pose_offset`（创意工坊绑定的 pose 里加 `pose_offset`）      | 手动没动；`vrserver` 无解析报错                        |
| `device_offsets` / 「原始设备偏移」                                  | 手和游戏自己画的手柄一起移，相对位置不变               |
| 补 `openxr_grip`                                                     | app 绑的是 `pose/raw`，看不到它                        |
| 只改 `[controller]`、不补顶点                                        | 手对了，模型跟着偏 4.28 cm（两环相碰时模型会互相穿插） |

⇒ app 改不了、pose 一改就两者一起动，**网格是唯一能单独动模型的旋钮**。

## 定稿：成对改位姿 + 顶点

**位姿**：`RVRPlugin.ini` 的 `[controller]`（`sub_180032AE0` 每 5 ms 读一次；`sub_180018340` 按 `q' = q·q_off` 旋转、`p' = p + R(q')·t` 平移）。

**顶点**：`resources\rendermodels\pico_neo3_{left,right}controller\*.obj` 用 `v' = Rz(-roll)·Ry(-yaw)·v - t` 反向补偿（旋转先做、再减 `t`）。

### 数值与来源

- 平移 `t`：左 `(+0.0099, +0.0115, -0.0401)`、右 `(-0.0099, +0.0115, -0.0401)`——就是 04.e 量到的 4.28 cm 在自身系的分解。
- 旋转：绕自身轴 `≈(0,-0.096,+0.994)` 的 10.29°；ini 写成左 `yaw=-0.99 / roll=+10.23`、右 `yaw=+0.99 / roll=-10.23`（pitch 0）。
- 左右手的 `t.x` 符号相反（模型在 x 上镜像）；顶点旋转先做、再减 `t`。
- 实机：VRChat / The Lab / Alyx / SteamVR 面板四组都正常；两环相碰不再互相穿插。

### 代价与注意

- `[controller]` 是**全局**的：所有 app 的 device pose 都挪 4.3 cm；用 `handgrip` / `base` 组件（手柄 JSON 里声明的握把 / 底部挂接点）的 app 会跟着多偏 4 cm（VRChat / Alyx 走 `raw` / 骨架，不受影响）。
- 旋转只用了 `roll≈10.23° + yaw≈0.99°`；要调手掌朝向就改 ini 并**同步重算顶点**。
- 顶点补偿要重启 SteamVR 才重载模型；ini 基本实时生效。
- 落地：`patch_driver.ps1` 的手柄阶段（`.orig` = 脚本动手前的备份（见 README「还原」）；17 个原始 OBJ 的 sha256 卡死、从 `.orig` 重算，幂等）。
