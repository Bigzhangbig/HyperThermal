#!/system/bin/sh
MODDIR=${0%/*}
CONFDIR="$MODDIR/config"
LOGFILE="$MODDIR/log.log"

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 3; done
sleep 5

mkdir -p "$CONFDIR"
[ ! -f "$CONFDIR/settings.json" ] && cp "$MODDIR/default_settings.json" "$CONFDIR/settings.json"

# 检测温控进程
THERMAL_DAEMON=""
if [ -x /vendor/bin/mi_thermald ] && [ "$(getprop init.svc.mi_thermald)" = "running" ]; then
    THERMAL_DAEMON="mi_thermald"
elif [ -x /vendor/bin/thermal-engine ] && [ "$(getprop init.svc.thermal-engine)" = "running" ]; then
    THERMAL_DAEMON="thermal-engine"
fi

if [ -z "$THERMAL_DAEMON" ]; then
    sed -i 's/\[.*\]/[ 错误：未找到温控进程 ]/' "$MODDIR/module.prop"
    exit 1
fi

# 检测云温控路径
if [ -d "/data/vendor/thermal/config" ]; then
    THERMAL_PATH="/data/vendor/thermal/config"
else
    THERMAL_PATH="/data/thermal/config"
fi

# K50/rubens 的 charge_control_limit 是档位，不能写入微安数值。
# 未确认适配的 K50 电流节点不参与控制。
CHARGE_NODE=""
if [ "$(getprop ro.product.device)" != "rubens" ]; then
    for n in /sys/class/xm_power/charger/charger_thermal/wired_chg_curr \
             /sys/class/power_supply/battery/constant_charge_current_max; do
        if [ -f "$n" ] && [ -w "$n" ]; then
            CHARGE_NODE="$n"
            break
        fi
    done
fi

# 用独立文件传递运行时参数（避免eval注入）
printf '%s' "$THERMAL_DAEMON" > "$CONFDIR/rt_thermal_daemon"
printf '%s' "$THERMAL_PATH"   > "$CONFDIR/rt_thermal_path"
printf '%s' "$CHARGE_NODE"    > "$CONFDIR/rt_charge_node"

# 获取商品名（优先marketname，其次model）
MARKET_NAME=$(getprop ro.product.marketname 2>/dev/null)
[ -z "$MARKET_NAME" ] && MARKET_NAME=$(getprop ro.product.model 2>/dev/null)

# 探测电压节点
VOLTAGE_NODE=""
for vn in /sys/class/power_supply/battery/voltage_now \
          /sys/class/power_supply/battery/voltage_ocv; do
    if [ -f "$vn" ]; then VOLTAGE_NODE="$vn"; break; fi
done

printf '%s' "$VOLTAGE_NODE" > "$CONFDIR/rt_voltage_node"

# 写runtime.json供WebUI读取
printf '{"thermal_daemon":"%s","os_version":"%s","thermal_path":"%s","charge_node":"%s","voltage_node":"%s","platform":"%s","model":"%s","market_name":"%s"}\n' \
    "$THERMAL_DAEMON" \
    "$(getprop ro.mi.os.version.incremental 2>/dev/null | sed 's/OS//' | cut -d'.' -f1)" \
    "$THERMAL_PATH" \
    "$CHARGE_NODE" \
    "$VOLTAGE_NODE" \
    "$(getprop ro.board.platform)" \
    "$(getprop ro.product.model)" \
    "$MARKET_NAME" \
    > "$CONFDIR/runtime.json"

# 设置脚本权限
chmod 0755 "$MODDIR/thermal_core.sh"

log_start() {
    local lines=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
    [ "$lines" -gt 100 ] && sed -i '1,20d' "$LOGFILE"
    echo "$(date +%F_%T) 模块启动 daemon=$THERMAL_DAEMON path=$THERMAL_PATH" >> "$LOGFILE"
}
log_start
sed -i 's/\[.*\]/[ 运行中 ]/' "$MODDIR/module.prop"

exec "$MODDIR/thermal_core.sh" "$MODDIR"
