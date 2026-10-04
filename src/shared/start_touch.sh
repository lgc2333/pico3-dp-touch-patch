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

# 本脚本自己的话同时写一份到这里：PC 侧用 adb 不 root 也能读（免得只能靠 Termux 屏幕）
LOG=/data/local/tmp/start_touch.log
: > "$LOG" 2>/dev/null || true
chmod 666 "$LOG" 2>/dev/null || true
say() { echo "$@"; echo "$@" >> "$LOG" 2>/dev/null || true; }

injected() { grep -q 'frida-agent' /proc/$PID/maps 2>/dev/null; }

# 自己这条线路带没带 seccomp 过滤器：app（Termux 直跑）=2 ⇒ 注入器必然被 SIGSYS 杀掉（实测 rc=159、日志为空）。
# adbd 的后代（PC 侧、或 Termux 里 adb connect 127.0.0.1:5555）=0 ⇒ 正常。
SEC=$(grep -E '^Seccomp:' /proc/self/status 2>/dev/null | tr -d '\t ' | cut -d: -f2)
say "[i] 本线路 Seccomp=${SEC:-?}（0=无过滤器 ✓；2=app 的过滤器 ⇒ 注入器会被 SIGSYS 杀）"
if [ "${SEC:-0}" != "0" ]; then
    say "[!] 这条线路是 app 的后代（Termux 直跑），注入器继承它的 seccomp ⇒ 注入不可能成功。"
    say "    ⇒ 注入得交给 adbd 跑：PC 侧 pico_touch.bat，或 Termux 里用 adb（会自动认出本机 emulator-5554）跑本脚本。"
fi

# 已注入过？frida agent 会出现在 /proc/<pid>/maps
if injected; then
    say "已注入（pid=$PID），跳过"
    exit 0
fi

if [ ! -x "$INJ" ] || [ ! -f "$JS" ]; then
    say "缺少 $INJ 或 $JS"
    exit 1
fi

# -e = eternalize：注入后 agent 常驻目标进程，注入器自己随后退出。
# 输出**不能丢 /dev/null**：注入失败时那是唯一的线索（踩过：只报「没看到 frida-agent」，无从下手）。
# 也不能让它继承调用方 stdout（Termux 里 `| tee` 等不到 EOF、PC 侧 adb shell 会挂住）⇒ 重定向到文件。
INJLOG=/data/local/tmp/frida-inject.log

# exploit 刚跑完那几秒系统在回收内存（实测：lmkd 会在那波里连杀进程，连 su 域的也杀），
# 而注入器要读 53 MB 再载 agent ⇒ 所以：等久一点、它死了就重试、到底是「被杀」还是「慢」看退出码。
WAIT=30      # 每轮等 agent 的秒数
ROUNDS=4     # 注入器一直活着的话，最多等这么多轮
TRIES=3      # 注入器死掉的话，最多起这么多次

start_injector() {
    # ★ 注入器是普通 exec，会吃调用方环境：Termux 里带着 LD_LIBRARY_PATH=$PREFIX/lib，
    #   动态链接器会先去 Termux 的库目录里找 libz/libcrypto… ⇒ 加载到不匹配的库、静默死掉（日志 0 字节）。
    #   实测：同一条链从 adb 走能注入成功，从 Termux 走必失败，就是这一条。
    #   TMPDIR 另说：与其留着 Termux 的私有 tmp，不如指到 /data/local/tmp（root 一定有写权限）。
    env -u LD_LIBRARY_PATH -u LD_PRELOAD -u LD_LIBRARY_PATH_64 TMPDIR=/data/local/tmp \
        "$INJ" -p "$PID" -s "$JS" -e > "$INJLOG" 2>&1 </dev/null &
    INJPID=$!
}

# 0=agent 挂上了；1=注入器已退出且没挂上；2=等满 N 秒，注入器还在跑
wait_agent() {   # wait_agent <秒>
    i=0
    while [ "$i" -lt "$1" ]; do
        if injected; then return 0; fi
        if ! kill -0 $INJPID 2>/dev/null; then return 1; fi
        sleep 1
        i=$((i + 1))
        if [ $((i % 10)) -eq 0 ]; then
            say "  [i] 已等 ${i}s，注入器（pid=$INJPID）还在跑"
        fi
    done
    if injected; then return 0; fi
    if kill -0 $INJPID 2>/dev/null; then return 2; fi
    return 1
}

TRIES_LEFT=$TRIES
while [ "$TRIES_LEFT" -gt 0 ]; do
    start_injector
    say "  [i] 注入器已启动（pid=$INJPID），等 agent 挂上……"
    R=1
    S=2
    while [ "$S" -eq 2 ]; do
        S=0
        wait_agent "$WAIT" || S=$?
        if [ "$S" -eq 2 ] && [ "$R" -ge "$ROUNDS" ]; then break; fi
        if [ "$S" -eq 2 ]; then
            R=$((R + 1))
            say "  [!] 注入器还在跑，继续等（第 $R/$ROUNDS 轮，每轮约 $WAIT 秒）"
        fi
    done

    if [ "$S" -eq 0 ]; then
        say "已注入 pid=$PID"
        exit 0
    fi
    if [ "$S" -eq 2 ]; then
        say "[X] 等满 $((WAIT * ROUNDS))s，注入器（pid=$INJPID）仍在跑，agent 却没挂上"
        say "    也就是：它既没被杀、也没做完 —— attach 卡住或系统太忙"
        break
    fi

    TRIES_LEFT=$((TRIES_LEFT - 1))
    if [ "$TRIES_LEFT" -gt 0 ]; then
        say "  [!] 注入器已退出但 agent 没挂上，5 秒后重试（还剩 $TRIES_LEFT 次）"
        sleep 5
    fi
done

# ---- 收尾：把能定位原因的东西全打出来（退出码是最关键的那个数） ----
if kill -0 $INJPID 2>/dev/null; then
    say "[X] 注入器（pid=$INJPID）还活着，agent 却一直没挂上"
else
    RC=0
    wait $INJPID 2>/dev/null || RC=$?
    case $RC in
        137) HINT='被 SIGKILL（137）—— exploit 那波内存风暴里 lmkd / OOM 顺手杀了它' ;;
        139) HINT='段错误 SIGSEGV（139）' ;;
        159) HINT='被 SIGSYS（159）杀 —— 注入器继承了 app 的 seccomp 过滤器（Termux 直跑），得让 adbd 来跑' ;;
        0)   HINT='它正常退出，却没挂上 agent' ;;
        1)   HINT='它自己报错退出（看下面的输出）' ;;
        *)   HINT='见下面的内核日志 / 注入器输出' ;;
    esac
    say "[X] 注入器已退出（rc=$RC）：$HINT"
fi
say "    注入器输出（$INJLOG）最后 20 行："
tail -20 "$INJLOG" 2>/dev/null || say "    （没有注入器日志）"
say "    内核日志最后 20 行（看有没有 lmkd / OOM 杀进程）："
dmesg 2>/dev/null | tail -20 || true
{
    echo "    —— 环境里的隐患变量（LD_*/TMPDIR）："
    env | grep -E '^(LD_|TMPDIR)' || echo "    （无）"
} >> "$LOG" 2>&1 || true
exit 1
