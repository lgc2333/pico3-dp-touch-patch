# 04 · PC 端 OpenVR 驱动（总览）

> PC 端驱动的入口：安装布局、版本指纹、v2 移植约定，以及按主题拆开的子篇索引。
> 原来一篇 512 行 / 约 5.2 万字符，2026-10-17 拆成 5 篇；内容一条没删，只按主题重排（v2 移植约定留在本篇）。

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

另有 v2 串流（`BusinessStreaming-v2.1.2-win32-x64.exe`，Electron）：驱动在 `<安装目录>\app\openvr_driver\`，**没有 DP 模式**；两代资源差异见 [04.a](04_a-driver-inputs.md)。

### md5

| 文件                                                 | md5                                |
| ---------------------------------------------------- | ---------------------------------- |
| DP `driver\bin\win64\driver_pico.dll` **原始**       | `9017439d560747678b4550fcf6726808` |
| DP 根目录 `driver_pico.dll`（废弃副本）              | `3e411eda6ab7ce0785abb12ef39af9a6` |
| UW `driver\bin\win64\driver_pico.dll`                | `f61949bf7afb4809eaa02daa18be7995` |
| v2.1.2 `app\openvr_driver\bin\win64\driver_pico.dll` | `e6d408b2590042c3c7f796b694ffc404` |

## v2 移植约定（抄 v2 前先看）

> 从 v2 搬常量 / 分支 / 资源前必须确认的约定；手序号那条的现场记录在 [04.d](04_d-driver-skeleton.md) 的「真凶」一节，profile / 绑定侧的现状在 [04.a](04_a-driver-inputs.md)。

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
- 手序号同样是"约定"而不是自然数：v2 用 **1 = 左 / 2 = 右**（更新器只判 `== 1`），DP 的控制器对象用 **0 = 左 / 1 = 右** ⇒ 直接照搬会让两只手拿到对方的镜像姿势（见 [04.d](04_d-driver-skeleton.md) 的「真凶」一节）。
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

## 子篇（按阅读顺序）

| 篇                                                       | 回答什么                                                                                                                                          |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| [04.a 兼容身份与输入声明](04_a-driver-inputs.md)         | DP 只带通用预设：profile / legacy 绑定 / 模拟身份缺什么，哪些实验没生效                                                                           |
| [04.b 驱动二进制地图](04_b-driver-binary.md)             | 对象与句柄表、输入更新器、DP / 网络两条路径、32 位掩码位布局                                                                                      |
| [04.c 触摸补丁与键值字](04_c-driver-touch-patch.md)      | 15 字节补丁、键值字 bit 占用总表、两代系统键路由                                                                                                  |
| [04.d 骨架 / pose 补丁](04_d-driver-skeleton.md)         | `.pitouch` 段怎么搬、手序号差一位的真凶、实测                                                                                                     |
| [04.e 手柄偏移：从模型假设到根因](04_e-driver-offset.md) | 9.7cm 假线索 → 标定台 / 两帧比对 → 4.28cm/10.29° 位姿 → `apprun` 根因、排除项与方法论                                                             |
| [04.f 手和模型解耦：握把位姿](04_f-driver-hand-grip.md)  | 修完 `apprun` 暴露的新问题：VRChat / The Lab 的手不在手心 → 手与模型共用 device pose → `[controller]` 偏移 + 顶点与活动部件支点反向补偿、证伪记录 |

## 一页速览

| 问题                          | 结论                                                                                                           | 详见        |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------- | ----------- |
| A/X、B/Y 的电容触摸           | 驱动本来就读键值字 bit1 / bit3，PC 侧一行都不用改                                                              | 04.b / 04.c |
| 扳机 / 摇杆顶触摸             | 键值字 bit5 / bit7；需 15 字节补丁（零长度变化）                                                               | 04.c        |
| Alyx 的手指动画               | DP 驱动被厂商砍掉整个 `/pose/*`、`/skeleton/*` ⇒ 搬 v2 的 `.pitouch`；手序号要 +1                              | 04.d        |
| 游戏里手柄偏 4.28cm / 10.29°  | 驱动读 host 发的 `apprun` 标志给位姿加修正；补丁把 `call atoi` 换成 `xor eax,eax`                              | 04.e        |
| 虚拟手不在手心 / 手臂伸不直   | 驱动把 device pose 报在跟踪环；`[controller]` 偏移把位姿挪到握把，顶点与活动部件支点反向补偿让模型留在物理位置 | 04.f        |
| SteamVR 里 menu 键没反应      | profile 少个斜杠（厂商笔误）+ 头显 profile 漏发                                                                | 04.a        |
| 曾经以为的 9.70cm「模型偏移」 | **假线索**：9.70 与 `handgrip` 的 0.097 只是数值巧合，几何 / 挂接不参与                                        | 04.e        |

## 记录约定

- 补丁字节数 / 补丁点只在 [04.c](04_c-driver-touch-patch.md) 与 [04.d](04_d-driver-skeleton.md) 各记一次，其它文档不抄数字。
- 被推翻的旧结论不删，留在原篇并标明后来被谁推翻：04.e 里就保留着「模型挂接」那段已证伪的主线。
