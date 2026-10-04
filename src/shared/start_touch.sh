#!/system/bin/sh
# start_touch.sh —— 在头显本地把电容触摸 hook 挂进 pxrstreamingservice。
# 幂等；必须在 adbd 那条线上跑（root adbd）。细节与退出码见 docs/notes/09-termux.md
set -e

INJ=/data/local/tmp/frida-inject
JS=/data/local/tmp/hook.js
INJLOG=/data/local/tmp/frida-inject.log
LOG=/data/local/tmp/start_touch.log   # 自述也写一份到这里（0666）：PC 侧不 root 也读得到

PID=$(pidof pxrstreamingservice)
if [ -z "$PID" ]; then
    echo "pxrstreamingservice 未运行"
    exit 1
fi

: > "$LOG" 2>/dev/null || true
chmod 666 "$LOG" 2>/dev/null || true
say() { echo "$@"; echo "$@" >> "$LOG" 2>/dev/null || true; }
injected() { grep -q 'frida-agent' /proc/$PID/maps 2>/dev/null; }

# 0 = adbd 的后代（正常）；2 = app 的过滤器（Termux 直跑）⇒ 注入器必然被 SIGSYS 杀
say "[i] 本线路 Seccomp=$(grep -E '^Seccomp:' /proc/self/status | tr -d '\t ' | cut -d: -f2)"

if injected; then
    say "已注入（pid=$PID），跳过"
    exit 0
fi
if [ ! -x "$INJ" ] || [ ! -f "$JS" ]; then
    say "[X] 缺少 $INJ 或 $JS"
    exit 1
fi

# -e = eternalize：agent 常驻目标进程，注入器随后退出。输出进日志、不吃调用方环境（Termux 的
# LD_LIBRARY_PATH 会让它去 Termux 库目录找 libz/libcrypto ⇒ 静默死掉；stdout 会被常驻进程攥住）
env -u LD_LIBRARY_PATH -u LD_PRELOAD -u LD_LIBRARY_PATH_64 TMPDIR=/data/local/tmp \
    "$INJ" -p "$PID" -s "$JS" -e > "$INJLOG" 2>&1 </dev/null &
INJPID=$!
say "[i] 注入器已启动，等 agent 挂上……"

# exploit 刚跑完那几秒 lmkd 会连着杀进程，注入器可能被顺手杀掉 ⇒ 它退了就按退出码定位（见 notes/09）
i=0
while [ "$i" -lt 60 ]; do
    if injected; then
        say "已注入 pid=$PID"
        exit 0
    fi
    kill -0 $INJPID 2>/dev/null || break
    sleep 1
    i=$((i + 1))
    if [ $((i % 10)) -eq 0 ]; then say "  [i] 已等 ${i}s，注入器还在跑"; fi
done

if kill -0 $INJPID 2>/dev/null; then
    say "[X] 等满 60 秒，注入器还在跑、agent 没挂上 —— 再跑一次本脚本"
else
    RC=0
    wait $INJPID 2>/dev/null || RC=$?
    case $RC in
        137) HINT='被 SIGKILL（137）—— exploit 那波内存风暴里 lmkd/OOM 顺手杀了它，再跑一次本脚本' ;;
        159) HINT='被 SIGSYS（159）—— 继承了 app 的 seccomp，得让 adbd 来跑' ;;
        0)   HINT='它正常退出，却没挂上 agent' ;;
        1)   HINT='它自己报错退出（看下面的输出）' ;;
        *)   HINT='见下面的注入器输出' ;;
    esac
    say "[X] 注入器已退出（rc=$RC）：$HINT"
fi
say "    注入器输出（$INJLOG）最后 20 行："
tail -20 "$INJLOG" 2>/dev/null || say "    （没有注入器日志）"
exit 1
