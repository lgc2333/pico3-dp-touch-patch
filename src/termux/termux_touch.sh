#!/data/data/com.termux/files/usr/bin/sh
# termux_touch.sh —— 在头显本地（Termux）一键恢复「DP 手柄电容触摸」，不需要 PC
#
# ★ 为什么这条链必须交给 adbd 跑：
#   Termux 是 app 进程，带着 app 的 seccomp 过滤器（BPF，跨 exec 继承、且不可撤销）。
#   在 Termux 里 fork 出来的 frida-inject 一碰被拦的 syscall，就被内核 SIGSYS 当场打死
#   —— 实测 rc=159、注入器日志恒为 0 字节（「设备本地怎么都挂不上、adb 一下就好」就是这个原因）。
#   adbd 由 init 起、没有 app 的过滤器（`/proc/self/status` 里 `Seccomp: 0`）
#   ⇒ 让 adbd 跑整条链：提权 + 注入。
#   前提：头显「设置 → 开发者选项」里打开 adb / 无线调试，让 adbd 在 5555 上监听（同 README）。
#
# ★ 提权 = 把 adbd 自己换成 root（和 PC 侧同一条路）：
#   `adb tcpip 5555`（picohaxx 会重启 adbd，得先设好易失的 service.adb.tcp.port）→
#   `picohaxx -adbd` 补 adbd ⇒ adbd 重启并以 root 回来 ⇒ Termux 侧的 adb 直接是 root，
#   注入就是一句 `adb shell start_touch.sh`；同一次开机里再跑（重启流媒体服务后补注入）**秒完**。
#   万一 adbd 没变成 root，就回退到 `picohaxx -noadbd -- start_touch.sh`（一样能注入，见下）。
#
# 运行期不碰 /sdcard：kit 拷到哪都能跑（放 $HOME 下才能执行二进制）
#   kit 里要有 picohaxx.neo3.bin / frida-inject / hook.js / start_touch.sh（同目录或 ./temp/）
#   运行时会把这四件推到 /data/local/tmp，再让 adbd 去跑（kit 里缺的会先 sh get_deps.sh 拉）
# 用法：dptouch（= 本脚本，PC 侧装成 $PREFIX/bin/dptouch）   日志：~/pico_touch/logs/

HERE=$(cd "$(dirname "$0")" && pwd)
PORT=5555
TMP_DIR=/data/local/tmp
WAIT=90                              # 等远端 [[RC]] 标记的轮数（每轮 2 秒 ⇒ 最多 3 分钟）
LOGDIR=$HERE/logs
TS=$(date +%Y%m%d-%H%M%S)
LOG=$LOGDIR/termux_$TS.log
RLOG=$TMP_DIR/dptouch_run.log        # 设备端那份（输出重定向到它，避免常驻子进程攥着 adb 连接不放）
DEV=                                 # 本机设备的 adb 名（设备上跑 adb 会自动认成 emulator-5554）

mkdir -p "$LOGDIR" 2>/dev/null || true

kit() {   # kit <名字>：在 kit 里找（$HERE 或 $HERE/temp/）
    for c in "$HERE/temp/$1" "$HERE/$1"; do
        if [ -f "$c" ]; then printf '%s' "$c"; return 0; fi
    done
    return 1
}

A() { adb -s "$DEV" "$@"; }

find_dev() {   # 设备上跑 adb：本机 adbd 会以 emulator-5554 出现（第一眼可能 offline，随后变 device）
    DEV=$(adb devices 2>/dev/null | sed -n 's/[[:space:]][[:space:]]*device$//p' | head -1)
    if [ -z "$DEV" ]; then
        DEV=$(adb devices 2>/dev/null | sed -n 's/[[:space:]][[:space:]]*\(offline\|unauthorized\)$//p' | head -1)
    fi
    if [ -n "$DEV" ]; then return 0; fi
    return 1
}

shell_ok() { A shell true >/dev/null 2>&1; }

wait_dev() {   # wait_dev <轮数>：每轮 2 秒，等到 adb 能通
    i=0
    while [ "$i" -lt "$1" ]; do
        if find_dev; then
            if shell_ok; then return 0; fi
        fi
        i=$((i + 1))
        sleep 2
    done
    return 1
}

run() {
    echo "### termux_touch.sh（借本机 adbd）开始 $TS"

    echo "=== 1/5 准备 adb 客户端 ==="
    if ! command -v adb >/dev/null 2>&1; then
        echo "[=] 装 android-tools（adb 客户端）..."
        pkg install -y android-tools >/dev/null 2>&1 || {
            echo '[X] 装不上：手动 pkg install android-tools'
            return 1
        }
    fi
    echo "[+] $(command -v adb)"

    echo "=== 2/5 找本机设备 ==="
    # ★ 本机 adbd 自己占着 127.0.0.1:5037（实测它的 fd 就指着那个 LISTEN socket），
    #   客户端再起 server 会：could not install *smartsocket* listener: Address already in use（然后 abort）。
    #   ⇒ 让客户端的 server 换个端口（ANDROID_ADB_SERVER_PORT），本机设备照样会被认成 emulator-5554。
    export ANDROID_ADB_SERVER_PORT=${ADB_PORT:-5038}
    echo "[i] adb server 端口：$ANDROID_ADB_SERVER_PORT（5037 被本机 adbd 占着）"
    adb start-server >/dev/null 2>&1 || true
    if ! wait_dev 6; then
        echo "[X] adb devices 里没有本机设备；原始输出："
        adb devices 2>&1 | sed 's/^/    /'
        echo "    ⇒ 头显「设置 → 开发者选项」里打开 adb / 无线调试（adbd 要在 $PORT 上监听），再跑一次 dptouch"
        return 1
    fi
    echo "[+] 本机设备：$DEV"
    echo "[i] $(A shell id | tr -d '\r')"
    echo "[i] 这条线路的 $(A shell 'grep -E "^Seccomp:" /proc/self/status' | tr -d '\r\t')（0=没有 app 的过滤器 ✓）"

    echo "=== 3/5 推设备端四件套 ==="
    for pair in picohaxx:picohaxx.neo3.bin frida-inject:frida-inject hook.js:hook.js start_touch.sh:start_touch.sh; do
        dst=${pair%%:*}
        src=${pair#*:}
        L=$(kit "$src" || true)
        if [ -z "$L" ]; then
            echo "[=] kit 里没有 $src，先拉依赖..."
            sh "$HERE/get_deps.sh" >/dev/null 2>&1 || true
            L=$(kit "$src" || true)
        fi
        if [ -z "$L" ]; then
            echo "[X] 找不到 $src（手动 sh $HERE/get_deps.sh）"
            return 1
        fi
        A shell "rm -f $TMP_DIR/$dst" >/dev/null 2>&1 || true   # 老文件可能是 root 属主，先删才覆盖得动
        A push "$L" "$TMP_DIR/$dst" >/dev/null 2>&1 || {
            echo "[X] 推 $dst 失败"
            return 1
        }
    done
    A shell "chmod 755 $TMP_DIR/picohaxx $TMP_DIR/frida-inject $TMP_DIR/start_touch.sh; chmod 644 $TMP_DIR/hook.js" >/dev/null 2>&1
    echo "[+] $TMP_DIR 就绪"

    echo "=== 4/5 提权：把 adbd 换成 root（Termux 侧 adb 也就成了 root） ==="
    ROOTADB=
    U=$(A shell 'id -u' 2>/dev/null | tr -d '\r')
    if [ "$U" = "0" ]; then
        echo "[=] adbd 已经是 root，跳过提权"
        ROOTADB=1
    else
        # 先 tcpip：picohaxx 会 kill adbd，重起的 adbd 读的是易失的 service.adb.tcp.port，
        # 不先设好，重启后 $PORT 就不监听了（PC 侧同理，见 AGENTS.md 设备端一节）。
        echo "[i] adb tcpip $PORT（让重启后的 adbd 仍监听 $PORT）"
        A tcpip "$PORT" >/dev/null 2>&1 || true
        if ! wait_dev 6; then
            echo "[X] tcpip 之后设备没回来"
            return 1
        fi

        # exploit 不可靠：同一开机里跑多了它会在提权阶段 `FATAL: SPINLOCK TIMEOUT at root.c:206` 自己中止
        #（符号标定跑偏），所以这里重试；两次都不成就不再折腾 adbd，退回非 root 那条路（→ 5/5）。
        n=1
        while [ "$n" -le 2 ]; do
            echo "[i] picohaxx -adbd -noftpd（补 adbd 成 root，约 50 秒；第 $n 次）——"
            echo "    它打完补丁会 kill adbd 并自己退出 ⇒ 本次连接必断，所以不等它、输出直接跟着看"
            sleep 2   # picohaxx 一开刷日志就会把上面的提示顶出屏幕，停 2 秒让人看清
            A shell "cd $TMP_DIR && ./picohaxx -adbd -noftpd" &
            HAXPID=$!
            sleep 8                                  # 让它把补丁打完（它会自己重启 adbd）
            kill $HAXPID 2>/dev/null || true          # 连接已经没意义了，别等

            echo "[i] 等 adbd 以 root 回来…"
            i=0
            while [ "$i" -lt 15 ]; do
                if wait_dev 2; then
                    if [ "$(A shell 'id -u' 2>/dev/null | tr -d '\r')" = "0" ]; then ROOTADB=1; break; fi
                fi
                i=$((i + 1))
            done
            if [ -n "$ROOTADB" ]; then
                echo "[+] adbd 已是 root：$(A shell id | tr -d '\r')"
                break
            fi
            echo "[!] 第 $n 次没成（exploit 偶发挂掉：FATAL: SPINLOCK TIMEOUT at root.c:206）"
            n=$((n + 1))
        done
        if [ -z "$ROOTADB" ]; then
            echo "[!] adbd 没变成 root ⇒ 回退到非 root 路子（picohaxx -noadbd 里直接注入）"
        fi
    fi

    echo "=== 5/5 注入（都由 adbd 跑） ==="
    # root adbd ⇒ 一句 start_touch.sh 就完事；不是 root ⇒ 用 `--` 让 picohaxx 提权后接着注入。
    # 远端命令把输出写进设备端 $RLOG，末尾追加 [[RC]]=<rc>；stdin 也给 /dev/null。
    # 但**不**等这个 adb 客户端返回：picohaxx 会留下常驻子进程，它们让 adb 连接迟迟不关
    # （实测：命令早跑完、[[RC]] 都写进日志了，客户端还挂着）⇒ 改成轮询设备端日志拿结果，拿到就杀客户端。
    if [ -n "$ROOTADB" ]; then
        REMOTE="$TMP_DIR/start_touch.sh"
    else
        sleep 2
        echo '[*] 2 秒后开始提权并注入'
        REMOTE=" $TMP_DIR/picohaxx -noadbd -noftpd -- $TMP_DIR/start_touch.sh"
    fi
    A shell "rm -f $RLOG" >/dev/null 2>&1 || true
    A shell "cd $TMP_DIR && { $REMOTE; echo \"[[RC]]=\$?\"; } > $RLOG 2>&1 < /dev/null" >/dev/null 2>&1 &
    ADBPID=$!
    A shell "tail -n +1 -f $RLOG" 2>/dev/null &        # 边跑边看（tail 是我们起的，随时能杀）
    TAILPID=$!

    RC=
    i=0
    while [ "$i" -lt "$WAIT" ]; do
        RC=$(A shell "sed -n 's/^\[\[RC\]\]=//p' $RLOG 2>/dev/null" 2>/dev/null | tr -d '\r' | tail -1)
        if [ -n "$RC" ]; then break; fi
        i=$((i + 1))
        sleep 2
    done
    sleep 0.3
    kill $TAILPID $ADBPID 2>/dev/null || true

    echo "=== 结果 ==="
    if [ "$RC" = "0" ]; then
        echo "[✓] 完成。hook 跑在头显本地进程里，跟 PC 无关。"
        echo "[i] 验证：SteamVR → 设置 → 控制器 → 测试控制器"
    else
        echo "[X] 失败 rc=${RC:-?}"
        echo "[i] 设备端自述（$TMP_DIR/start_touch.log）："
        A shell "cat $TMP_DIR/start_touch.log" 2>/dev/null | tr -d '\r'
        echo "[i] 注入器输出（$TMP_DIR/frida-inject.log）最后 20 行："
        A shell "tail -20 $TMP_DIR/frida-inject.log" 2>/dev/null | tr -d '\r'
        echo "[i] 远端全过程（$RLOG）最后 20 行："
        A shell "tail -20 $RLOG" 2>/dev/null | tr -d '\r'
        echo "[i] 其中若有 'FATAL: SPINLOCK TIMEOUT at root.c:206' ⇒ 是 exploit 自己挂了（偶发），再跑一次，"
        echo "    或者重启头显（root 本来就是一次性的，重启后 exploit 状态最干净）。"
    fi
    [ "$RC" = "0" ] && return 0
    return 1
}

# 输出写日志文件再 tail 出来，**不接管道**：picohaxx / frida-inject 留下的常驻进程会继承调用方的
# stdout —— 用 `| tee` 管道永远等不到 EOF，脚本就不返回了。文件当 sink 没这个问题（路径见 $LOG）。
run > "$LOG" 2>&1 &
RUNPID=$!
tail -f -n +1 "$LOG" &                      # 边跑边显示
TAILPID=$!
wait $RUNPID
RC=$?
sleep 0.2
kill $TAILPID 2>/dev/null || true
echo "### 结束 $TS rc=$RC —— 日志：$LOG"
exit $RC
