# Zero Axis CM5 hardware notes

This image enables the Waveshare IPCBOX-CM5 serial interfaces and RTC helpers for CM5 builds only.

Enabled boot configuration:

- `enable_uart=1`
- `dtoverlay=uart2-pi5` for CH0
- `dtoverlay=uart3-pi5` for CH1
- `dtoverlay=uart4-pi5` for CH2
- `dtoverlay=uart0-pi5` for CH3

The image also removes `console=serial0,115200` from the kernel command line so one of the application serial channels is not polluted by the Linux serial console.

RTC notes:

- Waveshare documents the RTC as `/dev/rtc0`
- `util-linux-extra` is installed so `hwclock` is available
- `gateway-cm5-rtc-load.service` loads system time from `/dev/rtc0` at boot
- `gateway-cm5-rtc-save.service` writes system time back to `/dev/rtc0` later in boot

If you fit a rechargeable RTC battery and explicitly want charging enabled, add this to `/boot/firmware/config.txt`:

`dtparam=rtc_bbat_vchg=3000000`

GPIO-backed carrier I/O:

- `IN1` -> `GPIO23` (digitally inverted by carrier)
- `IN2` -> `GPIO24` (digitally inverted by carrier)
- `OUT1` -> `GPIO27` (open-drain, active when GPIO is driven high)
- `OUT2` -> `GPIO22` (open-drain, active when GPIO is driven high)
- `BUZZER` -> `GPIO7` (active-low)
- `USER1` -> `GPIO25` (active-low)
- `USER2` -> `GPIO26` (active-low)

No extra overlay is needed for these GPIO lines. They are controlled from userspace.

Helper script:

- `/opt/gateway/scripts/gateway-cm5-ioctl`
- `/opt/gateway/scripts/gateway-cm5-boot-chirp.sh`

Examples:

- `sudo /opt/gateway/scripts/gateway-cm5-ioctl status`
- `sudo /opt/gateway/scripts/gateway-cm5-ioctl in1`
- `sudo /opt/gateway/scripts/gateway-cm5-ioctl out1 on`
- `sudo /opt/gateway/scripts/gateway-cm5-ioctl buzzer on`
- `sudo /opt/gateway/scripts/gateway-cm5-ioctl buzzer chirp`
- `sudo /opt/gateway/scripts/gateway-cm5-ioctl user1 on`

Boot chirp:

- `gateway-cm5-boot-chirp.service` runs once after the main gateway startup/network units
- current pattern is 3 short chirps

Verification:

- `/opt/gateway/scripts/gateway-cm5-hardware-status.sh`
- `/opt/gateway/scripts/gateway-cm5-ioctl status`
- `journalctl -u gateway-cm5-rtc-load.service -b`
- `journalctl -u gateway-cm5-rtc-save.service -b`
- `dmesg | grep -Ei 'ttyAMA|serial'`
