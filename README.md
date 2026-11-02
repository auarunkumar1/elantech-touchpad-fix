# ELAN I2C Touchpad Freeze Fix (AMD APUs & Laptops)

A permanent, tested fix and diagnostic toolkit for ELAN I2C touchpads (such as `ELAN1300`, `ELAN1200`, `ELAN06xx`) on AMD Ryzen laptops (ASUS VivoBook, ZenBook, Lenovo, Acer, etc.) running Linux.

---

## The Problem

On many AMD APU laptops running modern Linux distributions (Ubuntu, Linux Mint, Debian, Arch, Fedora), the touchpad **momentarily freezes or stops responding for 1 to 2 seconds**, then resumes.

Through kernel instrumentation and hardware tracing, this issue was proven to stem from **two distinct root causes**:

### Cause 1: Host Controller Runtime Autosuspend (Idle Dropout)
* **Symptom:** You pause for a second or two without touching the pad. When you touch it again, the cursor does not move for 1–2 seconds.
* **Mechanism:** AMD's DesignWare I2C host controller (`AMDI0010:xx`) runtime-suspends with an aggressive 1-second autosuspend timeout. The ELAN client device does not implement runtime power management, so nothing signals the controller to remain awake. The I2C controller suspends underneath the running touchpad. Every new touch after a brief idle period requires waking the I2C controller, which frequently stalls for 1–2 seconds before resuming.

### Cause 2: Power-Saver EPP & Deep C3 Latency (Mid-Drag Dropout)
* **Symptom:** The cursor suddenly freezes while your finger is actively moving or dragging across the touchpad.
* **Mechanism:** In Linux power-saving mode (e.g. `power-saver` via `power-profiles-daemon`), the AMD P-State Energy Performance Preference (EPP) is set to `power` (0xFF). This forces the CPU and SoC to its minimum frequency floor (~400–1100 MHz) and triggers aggressive deep C3 CPU idle states (350 µs exit latency). 
* When the ELAN touchpad streams 170–290 reports per second over I2C (IRQ 6 / IRQ 50), the starved SoC takes too long to wake and service the I2C transfer buffer. The hardware watchdog trips, causing a ~1.25s silence across all interrupt lines (`gpio=+0 i2c=+0 parent=+0`) before resetting.

---

## The Solution

A complete fix requires two complementary configurations:

1. **Keep the I2C Host Controller Awake:**
   Prevent the AMD DesignWare I2C controller from runtime-suspending using persistent udev rules and a systemd post-resume hook.
2. **Use the `balanced` Power Profile:**
   Keep the system power profile on **`balanced`** (or cap deep sleep via `processor.max_cstate=2`). On AMD Ryzen APUs, `balanced` already dynamically conserves power while keeping the SoC bus responsive enough to prevent I2C buffer starvation.

---

## Quick Start

### 1. Install the Permanent Fix
Clone the repository and run the installer:

```bash
git clone https://github.com/auarunkumar1/elantech-touchpad-fix.git
cd elantech-touchpad-fix
sudo ./fix-touchpad.sh
```

This will:
- Discover all ELAN I2C devices and AMD DesignWare controllers (`AMDI0010:*`).
- Install `/etc/udev/rules.d/99-elan-power.rules` to keep controllers awake (`power/control = on`).
- Install `/usr/lib/systemd/system-sleep/99-elan-resume.sh` to maintain settings across sleep/wake cycles.
- Clean up any legacy or obsolete GRUB polling parameters.

### 2. Verify Status
Check the real-time status of your I2C devices, runtime PM status, and installed rules without needing root:

```bash
./fix-touchpad.sh --status
```

Expected output:
```text
ELAN I2C touchpad status
------------------------
  device : /sys/bus/i2c/devices/i2c-ELAN1300:00
    driver        : i2c_hid_acpi
    power/control : auto
    runtime_status: unsupported
  controller: /sys/devices/platform/AMDI0010:03
    power/control : on
    runtime_status: active
    suspended_time: 0 ms
    autosuspend   : 1000 ms
  permanent config:
[+] installed: /etc/udev/rules.d/99-elan-power.rules
[+] installed: /usr/lib/systemd/system-sleep/99-elan-resume.sh
[+] power profile: balanced
[+] touchpad input device present: ELAN1300:00 04F3:3104 Touchpad
```

### 3. Ensure Balanced Power Profile
Ensure your system uses the `balanced` profile:

```bash
powerprofilesctl set balanced
```

*(Optional)* If you must run `power-saver` mode and want to prevent C3 stalls, you can cap the maximum idle C-state to C2 in your GRUB config:
```bash
sudo tee /etc/default/grub.d/99-touchpad-cstate.cfg << 'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT processor.max_cstate=2"
EOF
sudo update-grub
```

---

## Advanced Diagnostics: `diagnose-elan-irq.sh`

This repository includes a kernel-level diagnostic tool designed to pinpoint exactly which layer stalls when a touchpad freezes:

- **ELAN GPIO Pin:** `irq50` (`amd_gpio 16`)
- **Pin Controller Parent:** `irq7` (`pinctrl_amd`)
- **DesignWare Controller:** `irq6` (`AMDI0010:03`)
- **Input Subsystem:** `/dev/input/eventX` reports & delivery lag

### Running the Diagnostic

```bash
sudo ./diagnose-elan-irq.sh -d 120
```

- Drag your finger continuously around the pad.
- If the cursor stops while your finger is moving, press **`F9`** to drop a timestamped marker.
- The script analyzes `ftrace` (`irq_handler_entry`) and kernel logs, outputting a verdict:
  - **`gpio silent`**: The AMD GPIO path missed the interrupt.
  - **`i2c silent`**: The DesignWare controller stalled mid-transfer.
  - **`both active`**: Hardware delivered data; the stall is in `libinput` / desktop compositor.

---

## Uninstallation

To revert all configuration changes and remove installed rules:

```bash
sudo ./fix-touchpad.sh --revert
```

---

## Tested Hardware & Environment

- **Laptop:** ASUS VivoBook 15 (X513UA / KM513UA)
- **CPU:** AMD Ryzen 5 5500U (Lucienne / Cezanne Zen 2/3)
- **Touchpad:** `ELAN1300:00 04F3:3104` (HID over I2C)
- **OS:** Linux Mint 22.3 / Ubuntu 24.04 LTS (Kernel 6.8+, 6.14+, 7.0+)
- **Desktop:** Cinnamon / GNOME / X11

---

## License

MIT License. See [LICENSE](LICENSE) for details.
