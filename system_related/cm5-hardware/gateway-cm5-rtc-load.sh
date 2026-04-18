#!/bin/bash
set -euo pipefail

LOG_TAG="gateway-cm5-rtc-load"
RTC_DEV="/dev/rtc0"

if [ ! -e "${RTC_DEV}" ]; then
  logger -t "${LOG_TAG}" "RTC device ${RTC_DEV} not present, skipping load"
  exit 0
fi

if /usr/sbin/hwclock -s -f "${RTC_DEV}"; then
  logger -t "${LOG_TAG}" "loaded system clock from ${RTC_DEV}"
else
  logger -t "${LOG_TAG}" "failed to load system clock from ${RTC_DEV}"
fi

