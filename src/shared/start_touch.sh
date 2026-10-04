#!/system/bin/sh
# start_touch.sh —— 在头显本地把电容触摸 hook 挂进 pxrstreamingservice
#
# 幂等：已挂过就跳过（避免重复注入）
# 依赖：/data/local/tmp/{frida-inject,hook.js} 已就位，且已 root
set -e

INJ=/data/local/tmp/frida-inject
JS=/data/local/tmp/hook.js

PID=$(pidof pxrstreamingservice)
if [ -z "$PID" ]; then
    echo "pxrstreamingservice 未运行"
    exit 1
fi

# 已注入过？frida agent 会出现在 /proc/<pid>/maps
if grep -q 'frida-agent' /proc/$PID/maps 2>/dev/null; then
    echo "已注入（pid=$PID），跳过"
    exit 0
fi

if [ ! -x "$INJ" ] || [ ! -f "$JS" ]; then
    echo "缺少 $INJ 或 $JS"
    exit 1
fi

# -e = eternalize：注入后保持脚本运行并退出
"$INJ" -p "$PID" -s "$JS" -e
echo "已注入 pid=$PID"
