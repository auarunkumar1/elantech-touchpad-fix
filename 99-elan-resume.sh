#!/bin/sh
# Re-apply ELAN I2C power settings after resume (installed by fix-touchpad-v2.sh)
[ "$1" = post ] || exit 0
for d in /sys/bus/platform/drivers/i2c_designware/* /sys/devices/platform/AMDI0010:*; do
    [ -w "$d/power/control" ] && echo on > "$d/power/control" 2>/dev/null
done
for d in /sys/bus/i2c/devices/*; do
    [ -r "$d/name" ] || continue
    case "$(cat "$d/name" 2>/dev/null)" in
        ELAN*) [ -w "$d/power/control" ] && echo on > "$d/power/control" 2>/dev/null ;;
    esac
done
exit 0