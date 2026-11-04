# 00 · 笔记索引

| 篇                             | 回答什么                                                                                |
| ------------------------------ | --------------------------------------------------------------------------------------- |
| [01](01-device.md)             | 设备型号、系统版本、锁定状态，串流 app 与各进程 / 库的分工                              |
| [02](02-hid-protocol.md)       | DP 的 HID 报文协议：64 字节布局、键值字位义、抓包与时间对齐                             |
| [03](03-pipeline.md)           | 完整链路：谁组装报文、谁写 `/dev/hidg0`、为什么改 APK 改不到报文                        |
| [04](04-driver.md)             | PC 端 OpenVR 驱动总览：安装布局、版本指纹、v2 移植约定；子篇 04.a–04.g 的索引在该篇表里 |
| [05](05-injection.md)          | 头显端注入实现：在 `pxrstreamingservice` 进程内把两端接起来                             |
| [06](06-root.md)               | 免解 BL 的临时 root（picohaxx），重启失效                                               |
| [07](07-tooling.md)            | 工具链清单与踩坑                                                                        |
| [08](08-dead-ends.md)          | 走过的死路与原因，保留为 facts                                                          |
| [09](09-termux.md)             | Termux 路径：不需要 PC 的日常恢复，以及为什么整条链借 adbd 跑                           |
| [10](10-permanent-root.md)     | 解锁 Bootloader + 刷 Magisk，永久 root                                                  |
| [11](11-magisk-module.md)      | Magisk 模块：无 Frida 的永久注入                                                        |
| [12](12-controller-battery.md) | 手柄电量上报：驱动缺口、头显侧数据源、方案与未决项                                      |

- `artifacts/` 放笔记引用的分析脚本，用法见 [artifacts/README.md](artifacts/README.md)。
