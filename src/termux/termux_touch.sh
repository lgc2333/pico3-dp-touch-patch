#!/data/data/com.termux/files/usr/bin/sh
# termux_touch.sh —— 在头显上恢复「DP 手柄电容触摸」，纯本地、零 adb
#
# 思路：
#   1) picohaxx 能以 root 执行任意命令（`-- <cmd>`）
#      ⇒ 直接 `picohaxx -- start_touch.sh`，一步完成「提权 + 注入」，完全不碰 adb
#   2) app 域读不到 `settings get system confirm_smartisan_version`
#      （SELinux 拦 binder 调用，报 "Failed transaction"），
#      而 picohaxx 的 fallback（读 ro.pvr.internal.version）在编译版里实测返回空串
#      ⇒ 用 PATH shim 让 `settings` 直接吐出正确版本串，绕过整个问题
#
# 依赖：/sdcard/Download/pico_touch/picohaxx（由 PC 侧推上去）
# 用法：bash ~/termux_touch.sh

SRC=/sdcard/Download/pico_touch/picohaxx
HAX=$HOME/picohaxx
SHIM=$HOME/.pico-shim
LOGDIR=/sdcard/Download/pico_touch/logs
TS=$(date +%Y%m%d-%H%M%S)

# 与本机固件一致（见 settings get system confirm_smartisan_version）
FWVER='5.9.9-202409100313-RELEASE-user-neo3-b5349'

mkdir -p "$LOGDIR" 2>/dev/null || true

run() {
    echo "### termux_touch.sh (纯本地) 开始 $TS"

    echo "=== 1/4 准备 picohaxx ==="
    if [ ! -x "$HAX" ]; then
        cp "$SRC" "$HAX" || { echo "[X] 拷不到 $SRC（先跑 termux-setup-storage 授权）"; return 1; }
        chmod +x "$HAX"
    fi
    echo "[+] $HAX 就绪"

    echo "=== 2/4 装 settings shim ==="
    mkdir -p "$SHIM"
    {
        echo '#!/data/data/com.termux/files/usr/bin/sh'
        echo "# 只为 picohaxx 提供固件版本串（app 域读不到真实 settings）"
        echo "echo $FWVER"
    } > "$SHIM/settings"
    chmod +x "$SHIM/settings"
    echo "[+] $SHIM/settings -> $FWVER"

    echo "=== 3/5 第一次：提权 ==="
    echo "[i] 原本没 root 时需要约 50 秒"
    echo "[i] ⚠️ picohaxx 打完 adbd 补丁会 exit(21)，所以必须分两步"
    PATH="$SHIM:$PATH" "$HAX" -noftpd 2>&1 | tail -4

    echo "=== 4/5 第二次：执行注入（此时已是 root，picohaxx 跳过补丁）==="
    PATH="$SHIM:$PATH" "$HAX" -noftpd -- /data/local/tmp/start_touch.sh
    RC=$?

    echo "=== 5/5 结果 ==="
    if [ $RC -eq 0 ]; then
        echo "[✓] 完成。hook 跑在头显本地进程里，跟 PC / adb 都无关。"
        echo "[i] 验证：SteamVR → 设置 → 控制器 → 测试控制器"
    else
        echo "[X] 失败 rc=$RC"
    fi
    return $RC
}

run 2>&1 | tee "$LOGDIR/termux_$TS.log"
echo "### 结束 $TS —— 日志：$LOGDIR/termux_$TS.log"
