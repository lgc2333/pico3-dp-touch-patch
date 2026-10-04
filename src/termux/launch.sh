#!/data/data/com.termux/files/usr/bin/sh
# launch.sh —— PC 侧装成 Termux 的 $PREFIX/bin/dptouch（也随 kit 一起推）
# 唯一目的：VR 里少打字。Termux 里敲 `dptouch` == 跑 ~/pico_touch/termux_touch.sh
exec "$HOME/pico_touch/termux_touch.sh" "$@"
