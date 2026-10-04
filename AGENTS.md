# AGENTS.md

PICO Neo 3 Pro（企业版）在「Business Streaming DP 直连」下补回手柄电容触摸：头显端 Frida hook + PC 驱动 14 字节补丁。面向用户的说明在 `README.md`；完整逆向记录在 `docs/`。

## Structure

```text
src/
  windows/            PC（Windows）侧脚本，PowerShell 5.1+
    get_deps.ps1      从上游拉取 frida-inject / picohaxx 并打 Neo 3 补丁
    pico_touch.ps1    一键：找头显 → 无线 adb → picohaxx 提权 → 推送 → 设备端注入
    patch_driver.ps1  驱动 14 字节补丁（管理员，须先退出 SteamVR）
    _run_patch.ps1    以管理员运行补丁并记日志的小助手
  termux/             头显端（Termux，纯本地、不用 adb）
    get_deps.sh / termux_setup.sh / termux_touch.sh
  shared/             两端共用的设备端脚本
    hook.js           Frida 脚本：键值字 bit1/3/5/7 ← controller_data_t +32/+36/+40/+44
    start_touch.sh    幂等启动（检查 /proc/<pid>/maps 是否已有 frida-agent）
docs/notes/           逆向笔记 01 → 09（设备 / HID 协议 / 链路 / 驱动 / 注入 / root / 工具 / 死路 / Termux）
  artifacts/         笔记引用的分析脚本（已脱敏）
temp/                 本地工作区（安装了原始材料），整目录被 .gitignore 忽略
```

## Commands

本仓库无可构建产物；改动脚本后做语法检查（在仓库根运行）：

```powershell
# PowerShell：仅解析、不执行
powershell -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('src/windows/pico_touch.ps1',[ref]$null,[ref]$null)"
```

```sh
sh -n src/shared/start_touch.sh src/termux/*.sh   # POSIX 语法
node --check src/shared/hook.js                   # Frida 脚本（JS）
```

拉取依赖二进制（联网，写入对应 `src/<平台>/`，不入库）：

```powershell
powershell -ExecutionPolicy Bypass -File src\windows\get_deps.ps1
```

## Rules

- 文档等 Prettier / Ruff 支持处理的文件改动后，须使用对应工具格式化（`pnpx prettier -cw` / `ruff format`）。
- `get_deps` 必须保持逐字节校验（上游 md5 + 补丁点原字节），任一不符即中止、不写入。
- `.ps1` 含中文必须存为 UTF-8 BOM，否则 PowerShell 5.1 按 GBK 读会乱码。
- 驱动补丁只对 md5 `9017439d560747678b4550fcf6726808` 的 `driver_pico.dll` 有效；写入前必须校验原字节，失败即中止。
- 固件版本决定 `picohaxx` 的内核符号偏移；换固件须重取符号（见 `docs/notes/06-root.md`），不要假设偏移通用。

## Commit

Use English conventional commit messages:

```text
type(optional scope): description

- List of change briefs, focus one point per row

Optional footer(s)
```
