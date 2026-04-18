#!/bin/bash
set -euo pipefail

LOG_TAG="gateway-cm5-rtc-save"
RTC_DEV="/dev/rtc0"

if [ ! -e "${RTC_DEV}" ]; then
  logger -t "${LOG_TAG}" "RTC device ${RTC_DEV} not present, skipping save"
  exit 0
fi

if /usr/sbin/hwclock -w -f "${RTC_DEV}"; then
  logger -t "${LOG_TAG}" "saved system clock to ${RTC_DEV}"
else
  logger -t "${LOG_TAG}" "failed to save system clock to ${RTC_DEV}"
fi

