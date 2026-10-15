#!/system/bin/sh
# 仅恢复由 HyperThermal 覆盖的两个文件，不删除其他温控数据。
MODDIR=${0%/*}
THERMAL_PATH=$(cat "$MODDIR/config/rt_thermal_path" 2>/dev/null)
[ -n "$THERMAL_PATH" ] || THERMAL_PATH=/data/vendor/thermal/config
OVERLAY_DIR="$MODDIR/config/overlays"
changed=0
failed=0

for name in thermal-normal.conf thermal-map.conf; do
    state="$OVERLAY_DIR/$name.state"
    [ -f "$state" ] || continue
    case "$(cat "$state" 2>/dev/null)" in
        backup)
            if [ -f "$OVERLAY_DIR/$name.bak" ] &&
               cp -p "$OVERLAY_DIR/$name.bak" "$THERMAL_PATH/$name"; then
                chcon u:object_r:thermal_data_file:s0 "$THERMAL_PATH/$name" 2>/dev/null
            else
                echo "无法恢复 $name：原始备份缺失或复制失败"
                failed=1
                continue
            fi
            ;;
        absent)
            rm -f "$THERMAL_PATH/$name" || { failed=1; continue; }
            ;;
        *) failed=1; continue ;;
    esac
    rm -f "$state" "$OVERLAY_DIR/$name.bak"
    changed=1
done

if [ "$changed" = "1" ]; then
    if [ "$(getprop init.svc.mi_thermald)" = "running" ]; then
        stop mi_thermald; start mi_thermald
    elif [ "$(getprop init.svc.thermal-engine)" = "running" ]; then
        stop thermal-engine; start thermal-engine
    fi
fi
exit "$failed"
