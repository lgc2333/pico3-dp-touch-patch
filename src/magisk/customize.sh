# 安装时确认固件匹配，否则中止。
# 判据是系统属性，不是库文件：模块会挂载覆盖 /system/lib64，覆盖安装时读到的是补过的库，
# 用库的 sha256 判会把任何固件都放过去（见 docs/notes/11-magisk-module.md）。
# shellcheck disable=SC2034  # SKIPUNZIP 由 Magisk 安装器读取
SKIPUNZIP=0

FW=202409100313

# 与 picohaxx 认固件同样的两条来源，分隔符不同，所以按子串匹配
VERSION=$(getprop ro.pvr.internal.version)
[ -n "$VERSION" ] || VERSION=$(settings get system confirm_smartisan_version)
case "$VERSION" in
    *"$FW"*) ui_print "[i] 固件 $VERSION" ;;
    *) abort "[X] 固件不匹配（${VERSION:-未知}），本模块只对 PUI 5.9.9-$FW 有效" ;;
esac
