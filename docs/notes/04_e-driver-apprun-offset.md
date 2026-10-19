# 04.e · 手柄偏移（4.28cm / 10.29°）：`apprun` 根因与修法

> 总览：[04 · PC 端 OpenVR 驱动](04-driver.md)。
> 状态：**已定位并修复**（2026-10-17）。
> 本篇只留结论与修法；排查过程、证伪与旧结论因篇幅过大拆分到 [04.f](04_f-driver-offset-investigation.md)。
> 结论先行：每手偏 **4.28cm / 10.29°**，来源是 host 发的 `apprun` 标志，补丁把 `call atoi` 换成 `xor eax,eax`；9.70cm 与 `handgrip` 的 `+0.097` 只是数值巧合。

## 现象

SteamVR 自己的面板 / 系统场景里位置正常；进入 Scene app 后，SteamVR 的等待画面、VRChat 和真实 Steam 游戏（HL:Alyx）里都出现同一方向的偏移：两只手柄沿各自柄身朝追踪环方向偏。

Scene app 占场景时，两只手柄的**设备位姿**各偏一段——自身系 `d=(±0.0099,+0.0115,−0.0401)`、`|d|=4.28cm`、绕自身 `∓Z` 转 **10.29°**（转轴在自身系里 ≈ `(0,-0.096,+0.994)`，即沿柄身轴 + 一点 Y），左右镜像；`raw` / `standing` / `seated` 三个 universe 同步变、**HMD 位姿不变**；静态姿势下逐位稳定（预测时间 −0.05…+0.5 s 结果相同、速度全 0）。镜像里肉眼可见两只模型并到一起。

## 根因链

Steam 启动游戏 → PICO PC 侧 host 通过本机 socket 反复发 `apprun <n>` → `driver_pico.dll` 的收包线程 `sub_18002CE90` 用 `atoi` 写入全局 `dword_18009B080`（RVA `0x9B080`）→ 位姿发布函数 `sub_180018340` 读这个标志，给 `DriverPose_t` 多加一段 → 客户端读到的就是偏的。`apprun` 在整个 DLL 里只有这一处消费，所以补掉它不影响串流画质等其他行为。

## 取证

- **免游戏复现**：`IVRApplications::identifyApplication(pid, "steam.app.<已安装id>")` 把空进程挂到某个已安装 Steam 应用上，约 2 秒内进入漂移，进程退出即恢复。换 `openvr.tool.steamvr_room_setup` 这类工具 key 不触发 ⇒ 只有被当成「Steam 游戏」才偏。
- **发布函数入口 / 出口成对取值**：输入 `(+1.01164,+0.55034,+1.08921)` 两态**一字不差**，写出的 `vPosition` 不同（`+0.97067,…` vs `+0.92877,…`），而出口值就是客户端读到的值 ⇒ 偏移由驱动产生，vrserver 只转发。
- **整个 `.data`（10.7 KB）两态只差两处**，其一是 `0x9B080`（0→1）。
- **闭环**：漂移态下每 5 ms 把该标志写 0，位姿立刻回到基线（`+0.90857/+0.97067`），停止写入又回漂移。
- **确定性 A/B**：游戏占 scene 时偏，杀进程 8 秒后位姿逐位回到基线；两帧截图的连通块形状与外缘跨度（528→400px）也和用户现场一致。

## 修法

`patch_driver.ps1` 把写标志前的 `call atoi` 换成 `xor eax, eax`（零长度变化）⇒ 标志恒 0。验证：identify 测试 **4.28 cm → 0.04 cm**；The Lab 运行中位姿保持基线、两只模型分开。

## 别在资源侧找原因

几何 / `component_local` / 模型名 / `handgrip` / `openxr_grip` / `simulate_rendermodel` / `compatibility_mode_controller_type` / 控制器类型改名逐项 A/B 均为负，证据在 [04.f](04_f-driver-offset-investigation.md) 的「已排除」。一句话：错在 **pose**，不在几何；9.70cm 是假线索。

## 旁证

**公开资料对上了**：[SteamVR 论坛「Offset problems using Pico 4 controllers」](https://steamcommunity.com/app/250820/discussions/0/3828666917400432090) 里 PICO 用户描述「in game hands are being offset and appearing at the wrong angle」「It starts from the tip of controllers and angled」，与实测的 **4.28 cm + 10.29°（不是单纯平移）**逐条吻合；那边把控制器显示成 Quest 2 手柄后偏移消失，本质也是换了位姿约定。

## 两个方法论坑（下次省时间）

- 只 hook 发布函数的**入口**会得出「驱动没变」的错误结论——必须入口 + 出口成对取值。
- `identifyApplication` 之后漂移态会**卡住**（vrserver 一直以为应用在跑）；每次测量前重启 SteamVR，并先打印一次基线位姿确认（`dev2.x≈+0.97067` 干净 / `≈+0.92877` 已卡住）。

## 后续

修掉 `apprun` 偏移后，应用里的虚拟手仍然不在手心、手臂伸不直——那是**另一个**问题：手和模型吃的是同一个 device pose。实验与定稿见 [04.g](04_g-driver-hand-grip.md)；本篇只保留「4.28cm / 10.29° 偏移」这条线。
