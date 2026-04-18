#!/bin/bash
set -euo pipefail

printf '=== RTC ===\n'
ls -l /dev/rtc* 2>/dev/null || true
if command -v hwclock >/dev/null 2>&1; then
  /usr/sbin/hwclock -r -f /dev/rtc0 2>/dev/null || true
fi
printf '\n=== Serial Devices ===\n'
ls -l /dev/ttyAMA* /dev/ttyS* 2>/dev/null || true
printf '\n=== Serial Kernel Messages ===\n'
dmesg | grep -Ei 'ttyAMA|serial' || true
printf '\n=== Boot Firmware Config ===\n'
grep -n 'Zero Axis CM5 hardware\|dtoverlay=uart[0-9]-pi5\|enable_uart=1\|rtc_bbat_vchg' /boot/firmware/config.txt || true
printf '\n=== Kernel Cmdline ===\n'
cat /proc/cmdline

