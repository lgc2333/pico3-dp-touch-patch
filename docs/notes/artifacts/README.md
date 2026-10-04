# artifacts —— 逆向分析脚本

[`docs/notes/`](..) 里引用的分析脚本放在这里，供复现用；都是从本机一次性工作目录整理出来的。

- **运行**：多数脚本用 `uv run python <脚本>` 或 `python <脚本>`；具体用法见各文件顶部 docstring。
- **路径**：脚本里若出现 `D:\Program Files\BusinessStreaming\...`（驱动的 `hidapi.dll` /
  `openvr_api.dll` / `driver_pico.dll`），请按本机 Business Streaming DP 的实际安装位置修改。
- `gh-scripts/` 是 Ghidra headless 的 `.java` 脚本（用法见 [`../07-tooling.md`](../07-tooling.md)）。

未包含：原始抓包日志（`*.log`，体积大且与具体设备会话绑定）、`openvr.h`、厂商驱动副本等。
