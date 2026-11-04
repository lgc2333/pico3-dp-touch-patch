# 10 · 解 BL + Magisk 永久 root

> [06-root.md](06-root.md) 是 picohaxx 临时提权（不动磁盘、重启失效）；这篇是另一条路：解锁 Bootloader 后刷 Magisk，root 常驻。
> 状态：工具链与前提已核实；本机执行记录待补。

## 工具

[chaixshot/more-picohaxx-tool](https://github.com/chaixshot/more-picohaxx-tool)（PicoUnlock）：

1. 备份（LUN / userdata / 分区，可回刷）。
2. 刷入工程 abl + devinfo，打开 bootloader token。
3. 用 serial_number（Chip ID）生成解锁命令 fastboot oem picoXXXXXXXX unlock。
4. fastboot flashing unlock_critical → fastboot flashing unlock → fastboot oem setenforce 0。
5. 回刷原厂 abl，恢复出厂设置，刷 Magisk 补丁过的 boot.img。

支持列表（上游 README）：Pico 4 / 4 Pro / 4 Enterprise / **Neo 3（v5.11.2 及以下）**。本机 PUI 5.9.9 在范围内。

## ⚠️ 设备密钥（企业设置 → 设备信息）

- 设备密钥需为 **seksa**，才能走工程 ABL 解锁。
- 设备密钥是 **ksa** 时，刷工程 ABL 会变砖；**回刷原厂 ABL 可救**（工具自带 rollback）。
- 来源：教程视频评论区，**尚未实测验证**。动手前先备份原厂 ABL 与 boot 分区。

## 代价

- 解锁与上锁都会清 userdata（恢复出厂）。
- ro.boot.verifiedbootstate 变 orange，AVB/dm-verity 状态改变；OTA 前要先回锁或回原厂。

## 与 08 的关系

[08-dead-ends.md](08-dead-ends.md) 里「装 Magisk / 改 boot = 硬砖」的结论**只在 Bootloader 锁定前提下成立**；解锁后该约束解除，boot 分区可以正常刷写。系统分区仍建议走模块 overlay，而不是改分区。
