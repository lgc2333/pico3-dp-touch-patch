#!/data/data/com.termux/files/usr/bin/sh
# dptouch.sh —— 头显里敲 `dptouch` 跑的一键恢复（Termux，不需要 PC）。
# 流程、为什么整条链都借本机 adbd、前提、失败怎么办：见 docs/notes/09-termux.md

# $PREFIX/bin/dptouch 是指向本脚本的 symlink ⇒ 先找真身再算 HERE（readlink 不可用就按标准装法）
REAL=$(readlink -f "$0" 2>/dev/null) || REAL=$HOME/pico_touch/dptouch.sh
HERE=$(cd "$(dirname "$REAL")" && pwd)
PORT=5555
DEV=127.0.0.1:$PORT        # 设备上跑 adb：本机 adbd 就在这个 TCP 口上
TMP=/data/local/tmp
LOGDIR=$HERE/logs
TS=$(date +%Y%m%d-%H%M%S)
LOG=$LOGDIR/termux_$TS.log
RLOG=$TMP/dptouch_run.log  # 注入那条命令的输出：写文件，别等 adb 客户端（常驻子进程攥着它不放）
HLOG=$TMP/picohaxx.log     # picohaxx 自己的输出（判它是打完补丁还是自己中止）
WAIT=90                    # 等 [[RC]] 标记的轮数（每轮 2 秒）

# 本机 adbd 自己占着 127.0.0.1:5037，客户端的 server 起不来（could not install *smartsocket* listener）
export ANDROID_ADB_SERVER_PORT="${ADB_PORT:-5038}"

mkdir -p "$LOGDIR" 2>/dev/null || true

A() { adb -s "$DEV" "$@"; }

up() {   # up <轮数>：最多试 <轮数> 次、每次间隔 2 秒，成功立刻返回（计数器必须是自己独有的变量）
    up_left=$1
    while [ "$up_left" -gt 0 ]; do
        adb connect "$DEV" >/dev/null 2>&1
        A shell true >/dev/null 2>&1 && return 0
        up_left=$((up_left - 1))
        sleep 2
    done
    return 1
}

kit() {   # kit <名字>：在 kit 里找（$HERE 或 $HERE/temp/）
    for c in "$HERE/temp/$1" "$HERE/$1"; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

run() {
    echo "[i] dptouch 开始（$TS）"
    echo "[i] 第 1/4 步：准备 adb"
    # 本机 adbd 占着 127.0.0.1:5037 ⇒ 客户端的 server 换 5038；写进 ~/.bashrc（幂等），新开的 Termux 会话也生效
    RC=$HOME/.bashrc
    grep -qs 'ANDROID_ADB_SERVER_PORT' "$RC" 2>/dev/null || {
        {
            echo ''
            echo '# dptouch 加的：本机 adbd 占着 5037，adb 客户端得换 server 端口（见 docs/notes/09-termux.md）'
            echo "export ANDROID_ADB_SERVER_PORT=$ANDROID_ADB_SERVER_PORT"
        } >> "$RC" 2>/dev/null && echo "[=] 已写进 ~/.bashrc：ANDROID_ADB_SERVER_PORT=$ANDROID_ADB_SERVER_PORT"
    }
    if ! command -v adb >/dev/null 2>&1 || ! adb version >/dev/null 2>&1; then
        if command -v pkg >/dev/null 2>&1; then
            echo '[!] adb 不在或跑不起来（CANNOT LINK EXECUTABLE = 包旧了/装残了）⇒ 先更新系统包再装它'
            echo '[i] pkg update / upgrade / install android-tools（可能几分钟，输出全量跟着看）'
            export DEBIAN_FRONTEND=noninteractive
            # 别把 pkg 的输出吞掉（静默几分钟用户会以为卡死），也别收窄它
            pkg update -y && pkg upgrade -y -o Dpkg::Options::=--force-confnew && pkg install -y android-tools || true
        fi
        if ! command -v adb >/dev/null 2>&1 || ! adb version >/dev/null 2>&1; then
            echo '[X] adb 还是不可用。手动补一刀：'
            echo '    pkg upgrade -y -o Dpkg::Options::=--force-confnew && pkg install -y --reinstall android-tools'
            return 1
        fi
    fi
    echo "[+] adb 可用：$(adb version 2>/dev/null | head -1)"
    adb start-server >/dev/null 2>&1 || true
    if ! up 6; then
        echo "[X] 连不上本机 adbd。adb devices："
        adb devices 2>&1 | sed 's/^/    /'
        echo "    ⇒ 头显「设置 → 开发者选项」里打开 adb / 无线调试（adbd 要在 $PORT 上监听）？"
        return 1
    fi
    echo "[+] 头显：$DEV"

    echo "[i] 第 2/4 步：推设备端文件"
    for p in picohaxx:picohaxx.neo3.bin frida-inject:frida-inject hook.js:hook.js start_touch.sh:start_touch.sh; do
        dst=${p%%:*}
        src=${p#*:}
        L=$(kit "$src") || { echo "[X] kit 里缺 $src —— 在 PC 上重跑 push.bat 把整个 kit 推过来"; return 1; }
        A shell "rm -f $TMP/$dst" >/dev/null 2>&1 || true   # 上一次可能是 root 属主，先删才覆盖得动
        A push "$L" "$TMP/$dst" >/dev/null 2>&1 || { echo "[X] 推 $dst 失败"; return 1; }
    done
    A shell "chmod 755 $TMP/picohaxx $TMP/frida-inject $TMP/start_touch.sh; chmod 644 $TMP/hook.js" >/dev/null 2>&1
    echo "[+] 设备端文件已就位（$TMP）"

    echo "[i] 第 3/4 步：提权（把 adbd 换成 root）"
    if [ "$(A shell 'id -u' 2>/dev/null | tr -d '\r')" = "0" ]; then
        echo "[=] adbd 已经是 root，跳过提权"
    else
        A tcpip "$PORT" >/dev/null 2>&1 || true
        up 6 || { echo '[X] tcpip 之后设备没回来'; return 1; }
        echo '[i] 开始提权（约 50 秒；下面是 exploit 的原始输出）'
        sleep 2   # picohaxx 一开刷日志就会把上面的提示顶出屏幕，停 2 秒让人看清
        A shell "rm -f $HLOG" >/dev/null 2>&1 || true
        A shell "cd $TMP && ./picohaxx -noftpd -- /system/bin/id > $HLOG 2>&1 < /dev/null" >/dev/null 2>&1 &
        HAXPID=$!
        A shell "tail -n +1 -f $HLOG" 2>/dev/null &   # 边跑边看（tail 是我们起的，随时能杀）
        HTAIL=$!
        sleep 8
        kill $HAXPID $HTAIL 2>/dev/null || true       # 连接已经没意义了，别等
        echo '[i] 等 adbd 以 root 回来…（15 轮，每轮 2 秒）'
        i=0
        while [ "$i" -lt 15 ]; do
            sleep 2   # 节奏由这圈自己定：adbd 已经连得上时 up 会立刻返回，不能指望它当计时器
            echo "[i] 还在等 adbd 变成 root（第 $((i + 1))/15 轮）"
            if up 1 && [ "$(A shell 'id -u' 2>/dev/null | tr -d '\r')" = "0" ]; then break; fi
            # 自己中止（FATAL）时 adbd 没被动过：既不掉线也不变 root ⇒ 再等 30 秒也是白等
            if A shell "grep -q 'FATAL: SPINLOCK TIMEOUT' $HLOG" 2>/dev/null; then
                echo '[!] picohaxx 自己中止了（FATAL: SPINLOCK TIMEOUT at root.c:206）'
                break
            fi
            i=$((i + 1))
        done
        if [ "$(A shell 'id -u' 2>/dev/null | tr -d '\r')" != "0" ]; then
            echo '[X] adbd 没变成 root —— picohaxx 自己中止了（FATAL: SPINLOCK TIMEOUT at root.c:206）'
            echo '    重启头显后重跑 dptouch 通常就好；要是每次都挂，多半是 Termux 那套环境的问题：'
            echo '    清 Termux 数据，之后重跑 PC 提权来恢复脚本（有能力也可以自己推脚本过来）'
            return 1
        fi
        echo "[+] adbd 已是 root"
    fi

    echo "[i] 第 4/4 步：注入（由 adbd 跑）"
    # 远端输出写进 $RLOG、末尾追加 [[RC]]=<rc>；**不**等 adb 客户端（常驻子进程攥着连接不放）⇒ 轮询日志拿结果
    A shell "rm -f $RLOG" >/dev/null 2>&1 || true
    A shell "cd $TMP && { ./start_touch.sh; echo \"[[RC]]=\$?\"; } > $RLOG 2>&1 < /dev/null" >/dev/null 2>&1 &
    ADBPID=$!
    A shell "tail -n +1 -f $RLOG" 2>/dev/null &       # 边跑边看
    TAILPID=$!

    RC=
    i=0
    while [ "$i" -lt "$WAIT" ]; do
        RC=$(A shell "sed -n 's/^\[\[RC\]\]=//p' $RLOG 2>/dev/null" 2>/dev/null | tr -d '\r' | tail -1)
        [ -n "$RC" ] && break
        i=$((i + 1))
        if [ $((i % 5)) -eq 0 ]; then echo "[i] 等注入结果…已等 $((i * 2))s"; fi
        sleep 2
    done
    sleep 0.3
    kill $TAILPID $ADBPID 2>/dev/null || true

    if [ "$RC" = "0" ]; then
        echo "[+] 完成（hook 在头显本地进程里，可以拔线 / 关窗口）"
        echo "[i] 验证：SteamVR → 设置 → 控制器 → 测试控制器"
        return 0
    fi
    echo "[X] 失败 rc=${RC:-?}"
    echo "[i] 设备端自述（$TMP/start_touch.log）："
    A shell "cat $TMP/start_touch.log" 2>/dev/null | tr -d '\r'
    echo "[i] 注入器输出（$TMP/frida-inject.log）最后 20 行："
    A shell "tail -20 $TMP/frida-inject.log" 2>/dev/null | tr -d '\r'
    echo "[i] 全过程（$RLOG）最后 20 行："
    A shell "tail -20 $RLOG" 2>/dev/null | tr -d '\r'
    return 1
}

# 输出写日志文件再 tail 出来（不接管道：常驻子进程会攥着调用方 stdout）；stdout 就是 $LOG 时不 tail（自我喂养，见 notes/09）
run > "$LOG" 2>&1 &
RUNPID=$!
TAILPID=
if [ "$(stat -c %i "$LOG" 2>/dev/null)" != "$(stat -c %i /proc/self/fd/1 2>/dev/null)" ]; then
    tail -f -n +1 "$LOG" &
    TAILPID=$!
fi
wait $RUNPID
RC=$?
sleep 0.2
[ -n "$TAILPID" ] && kill $TAILPID 2>/dev/null || true
SHARE=/sdcard/Download/pico_touch/logs   # 镜像一份到 /sdcard：不 root 的 adb / PC 也读得到（见 AGENTS 设备端）
mkdir -p "$SHARE" 2>/dev/null && cp -f "$LOG" "$SHARE/" 2>/dev/null || true
echo "[i] dptouch 结束（rc=$RC；日志：$LOG）"
exit $RC
