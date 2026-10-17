# 04.d · 骨架 / pose 补丁（`.pitouch` 段）

> 总览：[04 · PC 端 OpenVR 驱动](04-driver.md)。
> 状态：**已实现 + 实机验证**（2026-10-16 实现；10-17 手序号修完后，Alyx 里「不碰键 = 张开、摸扳机 = 手指弯」）。

## 背景

- 姿势源侧：DP 驱动 DLL 里原本 **`/pose/*` 与 `/skeleton/*` 一个都没有**（UW / v2 有 `/pose/raw` + `/skeleton/hand/{left,right}`）⇒ Alyx 的手指动画拿不到；2026-10-16 起把 v2 的实现整段搬了进来（见下）。
- [04.c](04_c-driver-touch-patch.md) 那 15 字节换不来手指动作：Alyx 读的是 `/user/hand/*/input/skeleton/*`（见 [04.a](04_a-driver-inputs.md)），而 DP 的 `driver_pico.dll` 里连 `skeleton` / `pose/raw` 字符串都没有 ⇒ 是被厂商整段砍掉的功能，profile / 数据层都补不出来。

## 实现：`.pitouch` 段（2026-10-16，离线 + 实机都验过）

做法是**把 v2 的实现整段搬进 DP 驱动**：

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

## 真凶：手序号差一位 ⇒ 两只手各拿到对方的**镜像**姿势（2026-10-16 深夜，已修）

**症状**（用户实机）：SteamVR Home 里两只手**左右反了**、手指**扭成一团**；Alyx 里不碰键 = 握拳、碰键 = 手指伸开（"判定反了"）。

**根因**：v2 的控制器对象里手序号是 **1 = 左 / 2 = 右**（它的更新器只做 `*(a1+0xE8) == 1` 这一个判断来决定镜子），而 DP 的控制器对象 `[ctrl+8]` 是 **0 = 左 / 1 = 右**。移植时把 DP 的值**原样**写进了 `[scratch+0xE8]` ⇒ 左手拿到 `0`（≠1，走右手那套）、右手拿到 `1`（走左手那套）⇒ 两只手都用了**对方的镜像姿势**。

- **怎么定位的**：① 用户报告 SteamVR Home 左右反 + 骨扭成一团（说明骨架**确实在被 app 使用**）；② 用运行时自己的参考位姿对照（app 探针 `app_skeleton_probe.py`，Model 空间）：`/user/hand/left` 的实测手腕 x = `+0.034`，而运行时给同一个 action 的 `OpenHand` 参考是 `-0.034`（右手正好相反）⇒ **实测与参考正好互为镜像**；③ Frida 钩更新器（`hook_updater.py`）看实参：不碰键时喂的是 `mask=0`、手序号（`[scratch+0xE8]`）是 DP 的 0/1。
- **修法**：更新跳板写 `[scratch+0xE8]` 时 **+1**（`lea r8d, [rax+1]`）。暂存区/句柄数组仍按 DP 的 0/1 索引（我们自己的约定），只有喂给 v2 更新器的那一个字段用它的 1/2。
- **顺带解释"summary 反了"**：镜像的手相对掌心是"反着弯"的 ⇒ 运行时算出来的 `flFingerCurl` 自然整个反过来（实测：张开的手报 0.68、手指弯下去报 0.00）。**HL:A 就是拿 summary 画手指的**（cvar `vr_disable_skeletal` = _Disable skeletal summary_）⇒ 它忠实地画出了这个反的结果。修完镜像之后这两个值要重测一遍（预期：不碰键 ≈0、摸扳机/握把上升）。
- **回归测试**：`dp_skeleton_payload_test.py` 里加了断言（`[ctrl+8]=1` 的控制器，跳板必须写 `2` 进 `[scratch+0xE8]`）。

## 试过、无效、已回滚：把 app 模拟成 Index（`knuckles` priority 96）（2026-10-16 晚）

当时症状是「Alyx 里不碰键 = 握拳、碰键 = 手指伸开」，怀疑 app 没读驱动骨架。顺出来的背景：自动改绑挑「app 有绑定、且 `priority` 最高」的那一档（OpenVR 文档 _Automatic Rebinding_：_SteamVR will look for the highest priority layout that the application has a binding for_），而 Alyx 同时带 `knuckles`(90) 与 `oculus_touch`(95) 绑定 ⇒ 默认被当成 **Oculus Touch**。于是给驱动补了 `resources\input\pico_controller_remapping.json`（内容 = SteamVR 自带的兜底那份，只把 `knuckles` 抬到 96）并在 profile 里加 `"remapping"` 指上它。

- **实测确实生效**：`vrserver.txt` 出现 `[Remapping] … knuckles to … pico_controller`、`[Input] Loaded input profile for simulated controller type: knuckles`，Alyx 也改成加载 `bindings_knuckles.json`。
- **但症状一点没变** ⇒ 「手指不跟驱动走」**不是身份/绑定问题**（真因见上一节：手序号差一位导致两只手互换了镜像姿势）。
- **副作用**：被模拟的那一侧 app 连**模型**一起换成 Index 的（SteamVR Home 的手从「大白手」变成细长的 Index 手）—— 用户实测。
- **已全部回滚**：仓库里那份 json 删掉、profile 的 `remapping` 行去掉、`patch_driver.ps1` 里那两段删掉。**别再走这条路**。

## 上一轮留下的量测结论（仍然有效，别丢）

用「以 app 身份读骨架」的探针（`docs/notes/artifacts/app_skeleton_probe.py`，**必须 `--scene`**：后台 app 拿不到输入，所有 action 都是 inactive）+ Frida 钩我们自己搬进去的更新器（`docs/notes/artifacts/hook_updater.py`，能强制掩码）量出来的事实：

- **每帧更新在跑**：更新器 ~200 次/秒/手；不碰键时喂进去的是 `mask=0x0000, trig=0, grip=0`。
- **驱动发出的姿势原样到达 app**：把 OpenVR 的四元数按 `HmdQuaternionf_t { float w, x, y, z; }`（**w 在最前**）读，驱动的 31 根骨与 app 读回的差 **0.00 mm**（`compare_app_bones.py`）。⚠️ 之前"运行时改写了姿势"的结论是**读法错误**：`VRBoneTransform_t.orientation` 内存里是 w 开头，按 x,y,z,w 读会得到"转了一个分量"的假象。
- **v2 的算法本身是对的**（正确读法重画 `render_v2_poses.py`）：不碰键 = **张开的手**（指尖到手腕 188mm、手指伸直），摸**扳机 / 握把** = 手指**弯**下去（指尖 158/112/90/80），摸 A/X、B/Y、摇杆顶、system 只动拇指。
- **身份/绑定与手指无关**：把 app 的模拟类型从 `oculus_touch` 换成 `knuckles`（见上面「把 app 模拟成 Index」一节）**没有改变**症状。
- **如果修完镜像还有问题再看这些**：① 给建组件的跳板传一份**非 NULL 的 `pGripLimitTransforms`**（`docs/notes/artifacts/make_grip_limit_pose.py` 已经能生成一份，用 v2 姿势表里"握把按下"那一帧）；② `GetSkeletalReferenceTransforms(BindPose)` 对这个骨架返回全零，若 summary 还是不对，这是下一个要解释的现象。
