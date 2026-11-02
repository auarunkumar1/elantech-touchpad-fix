#!/usr/bin/env bash
# fix-touchpad-v2.sh — stop ELAN I2C touchpad dropouts on AMD (AMDI00xx) laptops.
#
# Symptom this addresses: the cursor freezes for a second or two, then resumes.
# On AMD APUs the DesignWare I2C host controller (AMDI0010:xx) runtime-suspends
# with a 1s autosuspend delay. The ELAN client does not implement runtime PM, so
# nothing holds the controller awake: it suspends underneath the running touchpad
# and every touch after an idle second needs an I2C controller resume. When that
# resume stalls, input stops for a second or two. Keeping the controller out of
# runtime PM is the fix; the cost is a little idle power.
#
set -euo pipefail

UDEV_FILE=/etc/udev/rules.d/99-elan-power.rules
# systemd 255 reads /usr/lib/systemd/system-sleep only (/lib is a symlink to it).
SLEEP_HOOK=/usr/lib/systemd/system-sleep/99-elan-resume.sh
LEGACY_GRUB=/etc/default/grub.d/99-elan-polling.cfg

ACTION=install
ASSUME_YES=0
DRY_RUN=0

die() { echo "[!] $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok() { echo "[+] $*"; }
warn() { echo "[!] $*"; }

usage() {
    cat <<'EOF'
Usage:
  sudo ./fix-touchpad-v2.sh            # runtime fix, then ask about permanent rules
  sudo ./fix-touchpad-v2.sh -y         # same, no prompts
  sudo ./fix-touchpad-v2.sh --revert   # undo everything this script installed
       ./fix-touchpad-v2.sh --status   # show current state (no root needed)
       ./fix-touchpad-v2.sh -n          # dry run, print what would change
EOF
    exit "${1:-0}"
}

for arg in "$@"; do
    case "$arg" in
        -y|--yes|--install) ASSUME_YES=1 ;;
        -n|--dry-run) DRY_RUN=1 ;;
        -r|--revert|--uninstall) ACTION=revert ;;
        -s|--status) ACTION=status ;;
        -h|--help) usage 0 ;;
        *) die "unknown argument: $arg (try --help)" ;;
    esac
done

# --- discovery -------------------------------------------------------------

# I2C client devices (the touchpad itself), e.g. /sys/bus/i2c/devices/i2c-ELAN1300:00
elan_devs() {
    local d
    for d in /sys/bus/i2c/devices/*; do
        [ -r "$d/name" ] || continue
        [[ $(<"$d/name") == ELAN* ]] && printf '%s\n' "$d"
    done
    return 0
}

# I2C host controllers driven by i2c_designware (bind/unbind/module/uevent filtered out)
ctrl_devs() {
    local d
    for d in /sys/bus/platform/drivers/i2c_designware/* /sys/devices/platform/AMDI0010:*; do
        [ -e "$d/power/control" ] && readlink -f "$d"
    done | sort -u
    return 0
}

mapfile -t ELAN < <(elan_devs)
mapfile -t CTRL < <(ctrl_devs)

# --- helpers ---------------------------------------------------------------

set_power() { # <sysfs path> <on|auto>
    [ -e "$1" ] || return 0
    # Devices that do not implement runtime PM reject the write with EIO and
    # spam the journal, so check before writing.
    if [ "$(cat "$(dirname "$1")/runtime_status" 2>/dev/null)" = unsupported ]; then
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "      would write '$2' -> $1"
        return 0
    fi
    if printf '%s\n' "$2" > "$1" 2>/dev/null; then
        echo "      $1 -> $2"
    else
        warn "could not write $2 to $1 (read-only or unsupported)"
    fi
}

verify_touchpad() {
    local p
    for p in /sys/bus/i2c/devices/*ELAN*/[0-9]*/input/input*/name; do
        if [ -r "$p" ] && grep -qi touchpad "$p"; then
            ok "touchpad input device present: $(<"$p")"
            return 0
        fi
    done
    warn "no touchpad input device found"
    warn "this script will try to rebind the driver; if that fails, reboot"
    return 1
}

# --- actions ---------------------------------------------------------------

show_status() {
    local d
    echo "ELAN I2C touchpad status"
    echo "------------------------"
    if [ "${#ELAN[@]}" -eq 0 ]; then
        warn "no ELAN device found on the I2C bus"
    fi
    for d in "${ELAN[@]}"; do
        echo "  device : $d"
        echo "    driver        : $(basename "$(readlink -f "$d/driver" 2>/dev/null)")"
        echo "    power/control : $(cat "$d/power/control" 2>/dev/null || echo n/a)"
        echo "    runtime_status: $(cat "$d/power/runtime_status" 2>/dev/null || echo n/a)"
    done
    for d in "${CTRL[@]}"; do
        echo "  controller: $d"
        echo "    power/control : $(cat "$d/power/control" 2>/dev/null || echo n/a)"
        echo "    runtime_status: $(cat "$d/power/runtime_status" 2>/dev/null || echo n/a)"
        echo "    suspended_time: $(cat "$d/power/runtime_suspended_time" 2>/dev/null || echo n/a) ms"
        echo "    autosuspend   : $(cat "$d/power/autosuspend_delay_ms" 2>/dev/null || echo n/a) ms"
    done
    echo "  permanent config:"
    for d in "$UDEV_FILE" "$SLEEP_HOOK"; do
        if [ -f "$d" ]; then ok "installed: $d"; else echo "      absent: $d"; fi
    done
    if [ -f "$LEGACY_GRUB" ]; then
        warn "stale GRUB drop-in from an older run: $LEGACY_GRUB (run --revert)"
    fi
    if command -v powerprofilesctl >/dev/null 2>&1; then
        local prof
        prof=$(powerprofilesctl get 2>/dev/null || echo unknown)
        if [ "$prof" = "power-saver" ]; then
            warn "power profile is '$prof' (AMD CPU EPP downclock can cause mid-movement stalls; use 'balanced')"
        else
            ok "power profile: $prof"
        fi
    fi
    verify_touchpad || true
}

apply_runtime() {
    local d
    info "keeping I2C controllers and ELAN client out of runtime suspend"
    for d in "${CTRL[@]}" "${ELAN[@]}"; do
        set_power "$d/power/control" on
    done
}

# Only used as a recovery path when the touchpad is already missing: unbind and
# rebind it through sysfs (no module unload needed, so the module stays in use).
rebind() {
    local drv d name
    for drv in i2c_hid_acpi i2c_hid; do
        [ -d "/sys/bus/i2c/drivers/$drv" ] || continue
        for d in "/sys/bus/i2c/drivers/$drv"/*; do
            [ -e "$d/power/control" ] || continue   # skip bind/unbind/module/uevent
            name=${d##*/}
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "      would rebind $name on $drv"
                continue
            fi
            info "rebinding $name on $drv"
            printf '%s\n' "$name" > "/sys/bus/i2c/drivers/$drv/unbind" 2>/dev/null || true
            sleep 0.5
            printf '%s\n' "$name" > "/sys/bus/i2c/drivers/$drv/bind" 2>/dev/null || true
        done
    done
}

write_file() { # <path> ; content on stdin
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "      would write $1"
        cat > /dev/null
        return 0
    fi
    mkdir -p "$(dirname "$1")"
    cat > "$1"
    ok "wrote $1"
}

install_permanent() {
    info "installing udev rules (re-applied on every boot and every device bind)"
    write_file "$UDEV_FILE" <<'EOF'
# ELAN I2C touchpad on AMD APUs: keep the DesignWare host controller out of
# runtime suspend. Suspending it loses touch input for a second or two.
ACTION!="remove", SUBSYSTEM=="platform", DRIVER=="i2c_designware", TEST=="power/control", ATTR{power/control}="on"
ACTION!="remove", SUBSYSTEM=="platform", KERNEL=="AMDI0010:*", TEST=="power/control", ATTR{power/control}="on"
ACTION!="remove", SUBSYSTEM=="i2c", ATTR{name}=="ELAN*", TEST=="power/control", ATTR{power/runtime_status}!="unsupported", ATTR{power/control}="on"
# Some AMD laptops expose the I2C controller as a PCI device instead.
ACTION!="remove", SUBSYSTEM=="pci", ATTR{class}=="0x0c80*", TEST=="power/control", ATTR{power/control}="on"
EOF

    info "installing suspend/resume hook"
    write_file "$SLEEP_HOOK" <<'EOF'
#!/bin/sh
# Re-apply ELAN I2C power settings after resume (installed by fix-touchpad-v2.sh)
[ "$1" = post ] || exit 0
for d in /sys/bus/platform/drivers/i2c_designware/* /sys/devices/platform/AMDI0010:*; do
    [ -w "$d/power/control" ] && echo on > "$d/power/control" 2>/dev/null
done
for d in /sys/bus/i2c/devices/*; do
    [ -r "$d/name" ] || continue
    case "$(cat "$d/name" 2>/dev/null)" in
        ELAN*) [ -w "$d/power/control" ] && [ "$(cat "$d/power/runtime_status" 2>/dev/null)" != "unsupported" ] && echo on > "$d/power/control" 2>/dev/null ;;
    esac
done
exit 0
EOF
    if [ "$DRY_RUN" -eq 0 ]; then
        chmod 755 "$SLEEP_HOOK"
        udevadm control --reload-rules
        udevadm trigger --subsystem-match=platform --subsystem-match=i2c
    fi

    # Older versions of this script added i2c_hid.polling_mode=1 to GRUB. That
    # module parameter does not exist in modern kernels, so drop the dead file.
    if [ -f "$LEGACY_GRUB" ]; then
        info "removing obsolete GRUB drop-in $LEGACY_GRUB"
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$LEGACY_GRUB"
            update-grub >/dev/null 2>&1 || warn "update-grub failed; check /boot space"
        fi
    fi
    ok "permanent configuration installed (effective from next boot/resume)"
}

revert_all() {
    local d had_grub=0
    info "reverting ELAN touchpad configuration"
    for d in "$UDEV_FILE" "$SLEEP_HOOK" "$LEGACY_GRUB"; do
        if [ -e "$d" ]; then
            if [ "$d" = "$LEGACY_GRUB" ]; then had_grub=1; fi
            if [ "$DRY_RUN" -eq 0 ]; then rm -f "$d"; fi
            ok "removed $d"
        fi
    done
    if [ "$DRY_RUN" -eq 0 ]; then
        udevadm control --reload-rules
        udevadm trigger --subsystem-match=platform --subsystem-match=i2c
        if [ "$had_grub" -eq 1 ]; then
            update-grub >/dev/null 2>&1 || warn "update-grub failed; check /boot space"
        fi
    fi
    info "restoring default runtime power management"
    for d in "${CTRL[@]}" "${ELAN[@]}"; do
        set_power "$d/power/control" auto
    done
    ok "reverted; reboot to fully restore defaults"
}

# --- main ------------------------------------------------------------------

if [ "$ACTION" = status ]; then
    show_status
    exit 0
fi

if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    die "run with sudo: sudo $0 $*"
fi

# Revert must work even when the touchpad is currently missing (that is often
# exactly why someone runs it), so it comes before the device check.
if [ "$ACTION" = revert ]; then
    revert_all
    exit 0
fi

if [ "${#ELAN[@]}" -eq 0 ]; then
    die "no ELAN I2C touchpad found on this machine (nothing to fix)"
fi

if [ "$(findmnt -n -o FSTYPE / 2>/dev/null)" = overlay ] || [ -d /run/casper ]; then
    warn "live session detected: permanent configuration will be skipped"
    IS_LIVE=1
else
    IS_LIVE=0
fi

apply_runtime
if ! verify_touchpad; then
    # The device is already dead (e.g. after a failed resume): cycle it once.
    rebind
    apply_runtime   # rebinding resets power/control, so re-apply
    if ! verify_touchpad && [ "$DRY_RUN" -eq 0 ]; then
        # Last resort: make udev re-probe the bus so the driver binds again.
        warn "touchpad still missing; asking udev to re-add I2C devices"
        udevadm trigger --action=add --subsystem-match=i2c
        sleep 1
        apply_runtime
        verify_touchpad || warn "touchpad did not come back; a reboot will restore it"
    fi
fi
ok "runtime fix active"

if [ "$IS_LIVE" -eq 1 ]; then
    info "skipping permanent install in live session"
    exit 0
fi

do_install=0
if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    do_install=1
elif [ -t 0 ]; then
    echo ""
    read -r -p "Install udev + resume hook so this survives reboots? [y/N]: " choice
    case "$choice" in [yY]*) do_install=1 ;; esac
else
    warn "no terminal: skipping permanent install (use -y to install non-interactively)"
fi

if [ "$do_install" -eq 1 ]; then
    install_permanent
else
    info "skipped permanent install; the runtime fix lasts until reboot"
fi
