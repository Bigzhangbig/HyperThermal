#!/system/bin/sh
MODDIR="$1"
CONFDIR="$MODDIR/config"
LOGFILE="$MODDIR/log.log"

# 从文件读取运行时参数（避免eval注入）
THERMAL_PATH=$(cat "$CONFDIR/rt_thermal_path" 2>/dev/null)
THERMAL_DAEMON=$(cat "$CONFDIR/rt_thermal_daemon" 2>/dev/null)
CHARGE_NODE=$(cat "$CONFDIR/rt_charge_node" 2>/dev/null)

log() {
    local lines=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
    [ "$lines" -gt 100 ] && sed -i '1,20d' "$LOGFILE"
    echo "$(date +%F_%T) $1" >> "$LOGFILE"
}

# JSON字段读取（每行一个字段的标准格式）
json_get() {
    [ -s "$CONFDIR/settings.json" ] || return
    grep "\"$1\"" "$CONFDIR/settings.json" 2>/dev/null \
        | sed 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*//' \
        | tr -d '", ' | tr -d ',' | tail -1
}

# ── 云温控覆盖：仅管理本模块创建的文件 ─────────────────

OVERLAY_DIR="$CONFDIR/overlays"

ensure_thermal_dir() {
    [ -d "$THERMAL_PATH" ] || {
        log "未找到云温控目录: $THERMAL_PATH"
        return 1
    }
}

# 首次覆盖时备份数据目录已有文件，卸载/关闭后恢复。
backup_overlay() {
    local name="$1"
    case "$name" in thermal-normal.conf|thermal-map.conf) ;; *) return 1 ;; esac
    mkdir -p "$OVERLAY_DIR" || return 1
    [ -f "$OVERLAY_DIR/$name.state" ] && return 0
    if [ -e "$THERMAL_PATH/$name" ]; then
        cp -p "$THERMAL_PATH/$name" "$OVERLAY_DIR/$name.bak" || return 1
        echo backup > "$OVERLAY_DIR/$name.state"
    else
        echo absent > "$OVERLAY_DIR/$name.state"
    fi
}

write_overlay() {
    local src="$1" name="$2"
    [ -f "$src" ] || return 1
    backup_overlay "$name" || return 1
    cp "$src" "$THERMAL_PATH/$name" || return 1
    chown root:system "$THERMAL_PATH/$name" 2>/dev/null
    chcon u:object_r:thermal_data_file:s0 "$THERMAL_PATH/$name" 2>/dev/null
    chmod 0644 "$THERMAL_PATH/$name"
}

has_overlays() {
    [ -f "$OVERLAY_DIR/thermal-normal.conf.state" ] ||
    [ -f "$OVERLAY_DIR/thermal-map.conf.state" ]
}

restore_overlays() {
    local state name status
    for name in thermal-normal.conf thermal-map.conf; do
        state="$OVERLAY_DIR/$name.state"
        [ -f "$state" ] || continue
        status=$(cat "$state" 2>/dev/null)
        case "$status" in
            backup)
                [ -f "$OVERLAY_DIR/$name.bak" ] || {
                    log "无法恢复 $name：备份缺失"; return 1
                }
                cp -p "$OVERLAY_DIR/$name.bak" "$THERMAL_PATH/$name" || return 1
                chcon u:object_r:thermal_data_file:s0 "$THERMAL_PATH/$name" 2>/dev/null
                ;;
            absent)
                rm -f "$THERMAL_PATH/$name" || return 1
                ;;
            *) log "覆盖状态异常: $name"; return 1 ;;
        esac
        rm -f "$state" "$OVERLAY_DIR/$name.bak"
    done
}

# K50 使用原厂 mi_thermald 服务重载加密配置。
start_thermal_program() {
    stop "$THERMAL_DAEMON" 2>/dev/null || return 1
    sleep 1
    start "$THERMAL_DAEMON" 2>/dev/null || return 1
    sleep 1
    log "重启温控服务: $THERMAL_DAEMON"
}

write_map_files() {
    [ -f /vendor/etc/thermal-map.conf ] ||
        [ -f /system/vendor/etc/thermal-map.conf ] || return 1
    write_overlay "$MODDIR/t_map" thermal-map.conf
}

apply_profile() {
    write_overlay "$1" thermal-normal.conf || return 1
    if ! write_map_files; then
        restore_overlays
        return 1
    fi
    start_thermal_program
}

# ── 温控模式应用 ──────────────────────────────────────

update_status() {
    sed -i "s/\[.*\]/[ 当前：$1 ]/" "$MODDIR/module.prop"
}

# 应用零档（完全无限制）：使用t_blank文件
apply_unlimited() {
    local cur_md5=$(md5sum "$THERMAL_PATH/thermal-normal.conf" 2>/dev/null | cut -d' ' -f1)
    if [ "$cur_md5" != "$MD5_BLANK" ]; then
        apply_profile "$MODDIR/t_blank" || { log "零档应用失败"; return 1; }
    fi
    local current_mode=$(cat "$CONFDIR/current_mode" 2>/dev/null)
    if [ "$current_mode" != "unlimited" ]; then
        echo "unlimited" > "$CONFDIR/current_mode"
        update_status "零档-无限制"
        log "切换: 零档-无限制"
    fi
}

# 应用档位温控（1-5档）
apply_level() {
    local lvl="$1"
    local conf="$MODDIR/thermal/${lvl}/thermal-scene.conf"
    local mode_id="level_${lvl}"
    local conf_size=$(wc -c < "$conf" 2>/dev/null || echo 0)
    if [ "$conf_size" -lt 100 ]; then
        log "无效的档位文件: $conf"
        return 1
    fi
    local cur_md5=$(md5sum "$THERMAL_PATH/thermal-normal.conf" 2>/dev/null | cut -d' ' -f1)
    local target_md5=$(md5sum "$conf" | cut -d' ' -f1)
    if [ "$cur_md5" != "$target_md5" ]; then
        apply_profile "$conf" || { log "档位 $lvl 应用失败"; return 1; }
    fi
    local current_mode=$(cat "$CONFDIR/current_mode" 2>/dev/null)
    if [ "$current_mode" != "$mode_id" ]; then
        echo "$mode_id" > "$CONFDIR/current_mode"
        update_status "${lvl}档温控"
        log "切换: ${lvl}档温控"
    fi
}

# 应用旁路供电温控（使用t_bypass_0文件）
apply_bypass_thermal() {
    local cur_md5=$(md5sum "$THERMAL_PATH/thermal-normal.conf" 2>/dev/null | cut -d' ' -f1)
    if [ "$cur_md5" != "$MD5_BYPASS_0" ] && [ "$cur_md5" != "$MD5_BYPASS_1" ]; then
        apply_profile "$MODDIR/t_bypass_0" || { log "旁路档位应用失败"; return 1; }
    fi
    local current_mode=$(cat "$CONFDIR/current_mode" 2>/dev/null)
    if [ "$current_mode" != "bypass" ]; then
        echo "bypass" > "$CONFDIR/current_mode"
        update_status "旁路供电"
        log "切换: 旁路供电"
    fi
}

# 恢复默认：只还原本模块覆盖的文件
apply_default() {
    local current_mode=$(cat "$CONFDIR/current_mode" 2>/dev/null)
    if has_overlays; then
        restore_overlays || return 1
        start_thermal_program || return 1
    fi
    if [ "$current_mode" != "default" ]; then
        echo "default" > "$CONFDIR/current_mode"
        update_status "系统默认"
        log "切换: 系统默认"
    fi
}

# 根据模式ID分发
apply_mode() {
    local mode="$1"
    ensure_thermal_dir || return 1
    case "$mode" in
        unlimited) apply_unlimited ;;
        level_1)   apply_level 1 ;;
        level_2)   apply_level 2 ;;
        level_3)   apply_level 3 ;;
        level_4)   apply_level 4 ;;
        level_5)   apply_level 5 ;;
        default)   apply_default ;;
        *)         apply_default ;;
    esac
}

# ── 电流控制 ──────────────────────────────────────────

set_charge_current() {
    local target="$1"
    # K50 的 CHARGE_NODE 为空；绝不把微安数值写入充电档位节点。
    [ "$(getprop ro.product.device)" != "rubens" ] || return 1
    [ -n "$CHARGE_NODE" ] && [ -w "$CHARGE_NODE" ] || return 1
    case "$CHARGE_NODE" in
        /sys/class/xm_power/charger/charger_thermal/wired_chg_curr|\
        /sys/class/power_supply/battery/constant_charge_current_max)
            printf '%s\n' "$target" > "$CHARGE_NODE"
            ;;
        *) return 1 ;;
    esac
}

# ── 旁路供电控制 ──────────────────────────────────────

bypass_on() {
    set_charge_current 0 || return 1
    apply_bypass_thermal || return 1
    echo "1" > "$CONFDIR/bypass_active"
}

bypass_off() {
    local max_c=$(json_get "max_charge_current")
    [ -z "$max_c" ] || [ "$max_c" = "0" ] && max_c=22000000
    [ -n "$CHARGE_NODE" ] && set_charge_current "$max_c"
    rm -f "$CONFDIR/bypass_active"
    rm -f "$CONFDIR/bypass_trigger"
}

# ── 前台应用检测 ──────────────────────────────────────

get_foreground_app() {
    local focus
    focus=$(dumpsys window displays 2>/dev/null | grep 'mCurrentFocus' | tail -1)
    [ -z "$focus" ] && focus=$(dumpsys window 2>/dev/null | grep 'mCurrentFocus' | tail -1)
    echo "$focus"
}

is_gaming() {
    local app_list=$(json_get "game_apps")
    [ -z "$app_list" ] && return 1
    get_foreground_app | grep -qF "$app_list" 2>/dev/null || \
    get_foreground_app | grep -qE "$(echo $app_list | tr '|' '|')" 2>/dev/null
}

# ── 初始化 ────────────────────────────────────────────

# 验证t_blank/t_bypass/t_map文件完整性（与旧版保持一致）
MD5_BLANK="de59942d3dffc090f0dae74dfc4d47ce"
MD5_BYPASS_0="006bb13431c52592192e710e46e76879"
MD5_BYPASS_1="959b4f8711503653abea8a019936ab2c"
MD5_MAP="43b4b914ef6b45119bbfe2030e4025a7"

check_core_files() {
    local ok=1
    [ "$(md5sum "$MODDIR/t_blank" 2>/dev/null | cut -d' ' -f1)" != "$MD5_BLANK" ] && ok=0
    [ "$(md5sum "$MODDIR/t_bypass_0" 2>/dev/null | cut -d' ' -f1)" != "$MD5_BYPASS_0" ] && ok=0
    [ "$(md5sum "$MODDIR/t_bypass_1" 2>/dev/null | cut -d' ' -f1)" != "$MD5_BYPASS_1" ] && ok=0
    [ "$(md5sum "$MODDIR/t_map" 2>/dev/null | cut -d' ' -f1)" != "$MD5_MAP" ] && ok=0
    echo "$ok"
}

# 从thermal/子目录恢复核心文件
restore_core_files() {
    for f in t_blank t_bypass_0 t_bypass_1 t_map; do
        [ -f "$MODDIR/thermal/$f" ] && cp "$MODDIR/thermal/$f" "$MODDIR/$f"
    done
}

if [ "$(check_core_files)" != "1" ]; then
    restore_core_files
    if [ "$(check_core_files)" != "1" ]; then
        sed -i 's/\[.*\]/[ 错误：核心温控文件损坏，请重装 ]/' "$MODDIR/module.prop"
        exit 1
    fi
fi

# 构建thermal_list（使用/system/vendor/etc，与mi_thermald一致）
rm -f "$MODDIR/thermal_list"
VENDOR_ETC=/vendor/etc
[ -d /system/vendor/etc ] && VENDOR_ETC=/system/vendor/etc
find "$VENDOR_ETC" -type f -iname "thermal*.conf" \
    | sed "s|$VENDOR_ETC/||" | grep -v '/' > "$MODDIR/thermal_list"

thermal_map_n=$(grep -i 'thermal-' "$MODDIR/thermal_list" 2>/dev/null \
    | grep -i '\-map' | grep -iv '\-region\-map' | wc -l)
if [ "$thermal_map_n" = "0" ]; then
    sed -i 's/\[.*\]/[ 机型不支持：未找到thermal-map文件 ]/' "$MODDIR/module.prop"
    exit 1
fi

ensure_thermal_dir || exit 1
if has_overlays; then
    restore_overlays || exit 1
    start_thermal_program || exit 1
fi
rm -f "$CONFDIR/current_mode" "$CONFDIR/bypass_active" "$CONFDIR/bypass_trigger" "$CONFDIR/bypass_manual"
log "thermal_core 启动 daemon=$THERMAL_DAEMON"

# ── 主循环 ────────────────────────────────────────────

LAST_CHARGING=0
while true; do
    # 模块禁用检查
    if [ -f "$MODDIR/disable" ]; then
        if [ "$(cat $CONFDIR/current_mode 2>/dev/null)" != "disabled" ]; then
            apply_default
            echo "disabled" > "$CONFDIR/current_mode"
            update_status "已禁用"
        fi
        sleep 5; continue
    fi

    ENABLED=$(json_get "enabled")
    if [ "$ENABLED" = "false" ]; then
        if [ "$(cat $CONFDIR/current_mode 2>/dev/null)" != "off" ]; then
            apply_default
            echo "off" > "$CONFDIR/current_mode"
            update_status "已关闭"
            log "模块关闭"
        fi
        sleep 5; continue
    fi

    # 读取电池状态
    VOLTAGE_NODE=$(cat "$CONFDIR/rt_voltage_node" 2>/dev/null)
    BAT_TEMP=$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 0)
    BAT_CURRENT=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo 0)
    BAT_CAPACITY=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo 0)
    BAT_STATUS=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo Unknown)
    BAT_VOLTAGE=$([ -n "$VOLTAGE_NODE" ] && cat "$VOLTAGE_NODE" 2>/dev/null || echo 0)
    BAT_TEMP_C=$((BAT_TEMP / 10))

    # 写实时状态供WebUI读取
    printf '{"temp":%s,"current":%s,"capacity":%s,"status":"%s","mode":"%s","voltage":%s}\n' \
        "$BAT_TEMP" "$BAT_CURRENT" "$BAT_CAPACITY" "$BAT_STATUS" \
        "$(cat $CONFDIR/current_mode 2>/dev/null)" "$BAT_VOLTAGE" > "$CONFDIR/status.json"

    IS_CHARGING=0
    case "$BAT_STATUS" in Charging|Full) IS_CHARGING=1 ;; esac

    # 防抖：mi_thermald重启瞬间充电状态会短暂中断，跳过本轮
    if [ "$IS_CHARGING" = "0" ] && [ "$LAST_CHARGING" = "1" ]; then
        LAST_CHARGING=0
        sleep 3; continue
    fi
    LAST_CHARGING=$IS_CHARGING

    BYPASS_ACTIVE=$(cat "$CONFDIR/bypass_active" 2>/dev/null)
    BYPASS_TRIGGER=$(cat "$CONFDIR/bypass_trigger" 2>/dev/null)

    # ── 旁路供电优先级最高 ──
    if [ "$IS_CHARGING" = "1" ] && [ -n "$CHARGE_NODE" ]; then
        BYPASS_TEMP_ON=$(json_get "bypass_temp_on")
        BYPASS_TEMP_OFF=$(json_get "bypass_temp_off")
        BYPASS_LEVEL=$(json_get "bypass_level")
        BYPASS_MANUAL=$(cat "$CONFDIR/bypass_manual" 2>/dev/null)

        # 温度旁路
        if [ -n "$BYPASS_TEMP_ON" ] && [ "$BYPASS_TEMP_ON" -gt 0 ] 2>/dev/null; then
            if [ "$BAT_TEMP_C" -ge "$BYPASS_TEMP_ON" ]; then
                echo "temp" > "$CONFDIR/bypass_trigger"
                bypass_on; sleep 3; continue
            elif [ "$BAT_TEMP_C" -le "${BYPASS_TEMP_OFF:-35}" ] && [ "$BYPASS_TRIGGER" = "temp" ]; then
                bypass_off
            fi
        fi

        # 手动旁路
        if [ "$BYPASS_MANUAL" = "1" ]; then
            bypass_on; sleep 3; continue
        fi

        # 电量旁路
        if [ -n "$BYPASS_LEVEL" ] && [ "$BYPASS_LEVEL" -gt 2 ] && [ "$BYPASS_LEVEL" -le 100 ] 2>/dev/null; then
            if [ "$BAT_CAPACITY" -ge "$BYPASS_LEVEL" ]; then
                echo "level" > "$CONFDIR/bypass_trigger"
                bypass_on; sleep 3; continue
            elif [ "$BYPASS_TRIGGER" = "level" ]; then
                bypass_off
            fi
        fi
    else
        # 未充电时关闭旁路
        [ "$BYPASS_ACTIVE" = "1" ] && bypass_off
    fi

    # ── 游戏场景 ──
    GAME_MODE=$(json_get "game_mode")
    if [ "$GAME_MODE" = "true" ]; then
        SCREEN_ON=$(dumpsys deviceidle get screen 2>/dev/null)
        if [ "$SCREEN_ON" != "false" ] && is_gaming; then
            GAME_LEVEL=$(json_get "game_level")
            [ -z "$GAME_LEVEL" ] && GAME_LEVEL="unlimited"
            apply_mode "$GAME_LEVEL"

            # 游戏旁路
            GAME_BYPASS=$(json_get "game_bypass")
            [ "$GAME_BYPASS" = "true" ] && [ "$IS_CHARGING" = "1" ] && [ -n "$CHARGE_NODE" ] && bypass_on

            # 锁帧
            GAME_FPS=$(json_get "game_fps")
            if [ -n "$GAME_FPS" ] && [ "$GAME_FPS" != "0" ]; then
                FPS_ID=$(dumpsys display 2>/dev/null \
                    | grep "DisplayModeRecord" | grep "fps=$GAME_FPS" \
                    | grep -v '=\[\]' | sed 's/.*id=//;s/,.*//' | head -1)
                [ -n "$FPS_ID" ] && service call SurfaceFlinger 1035 i32 $((FPS_ID - 1)) >/dev/null 2>&1
            fi
            sleep 3; continue
        fi
    fi

    # ── 充电场景 ──
    if [ "$IS_CHARGING" = "1" ]; then
        CHARGE_MODE=$(json_get "charge_mode")
        if [ "$CHARGE_MODE" = "true" ]; then
            CHARGE_LEVEL=$(json_get "charge_level")
            [ -z "$CHARGE_LEVEL" ] && CHARGE_LEVEL="unlimited"

            # 时间段切换
            TIME_START=$(json_get "time_start")
            TIME_END=$(json_get "time_end")
            TIME_LEVEL=$(json_get "time_level")
            if [ -n "$TIME_START" ] && [ -n "$TIME_END" ] && [ "$TIME_START" != "$TIME_END" ] 2>/dev/null; then
                HOUR=$(date +%k | tr -d ' ')
                if [ "$TIME_START" -gt "$TIME_END" ] 2>/dev/null; then
                    { [ "$HOUR" -ge "$TIME_START" ] || [ "$HOUR" -lt "$TIME_END" ]; } && CHARGE_LEVEL="$TIME_LEVEL"
                else
                    { [ "$HOUR" -ge "$TIME_START" ] && [ "$HOUR" -lt "$TIME_END" ]; } && CHARGE_LEVEL="$TIME_LEVEL"
                fi
            fi

            # 息屏档位
            SCREEN_ON=$(dumpsys deviceidle get screen 2>/dev/null)
            if [ "$SCREEN_ON" = "false" ]; then
                SLEEP_LEVEL=$(json_get "sleep_level")
                [ -n "$SLEEP_LEVEL" ] && CHARGE_LEVEL="$SLEEP_LEVEL"
            fi

            apply_mode "$CHARGE_LEVEL"
        else
            apply_mode "default"
        fi

        # 功率/电流限制（旁路时不限制，每轮强制写入防止mi_thermald覆盖）
        CURRENT_LIMIT=$(json_get "current_limit")
        if [ -n "$CHARGE_NODE" ] && [ -n "$CURRENT_LIMIT" ] && [ "$CURRENT_LIMIT" -gt 0 ] 2>/dev/null; then
            [ "$BYPASS_ACTIVE" != "1" ] && set_charge_current "$CURRENT_LIMIT"
        fi
    else
        # 普通场景
        DEFAULT_MODE=$(json_get "default_mode")
        [ -z "$DEFAULT_MODE" ] && DEFAULT_MODE="default"
        apply_mode "$DEFAULT_MODE"
    fi

    sleep 3
done
