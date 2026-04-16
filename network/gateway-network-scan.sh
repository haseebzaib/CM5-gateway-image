#!/bin/bash
set -euo pipefail

IFACE="${1:-wlan0}"

if ! command -v iw >/dev/null 2>&1; then
  jq -n '{ok:false,status:"scan_error",errors:[{scope:"wifi_client",code:"iw_missing",message:"iw is not installed."}]}'
  exit 1
fi

if ! ip link show "${IFACE}" >/dev/null 2>&1; then
  jq -n --arg iface "${IFACE}" '{ok:false,status:"scan_error",errors:[{scope:"wifi_client",code:"interface_missing",message:("Interface " + $iface + " is missing.")}]}'
  exit 1
fi

ip link set "${IFACE}" up >/dev/null 2>&1 || true

SCAN_OUTPUT="$(iw dev "${IFACE}" scan 2>/dev/null || true)"
if [ -z "${SCAN_OUTPUT}" ]; then
  jq -n '{ok:false,status:"scan_error",errors:[{scope:"wifi_client",code:"scan_failed",message:"No Wi-Fi scan results were returned."}]}'
  exit 1
fi

printf '%s\n' "${SCAN_OUTPUT}" | awk '
  /^BSS / {
    if (seen) {
      printf "%s\t%s\t%s\t%s\n", ssid, signal, security, freq
    }
    seen=1
    ssid=""
    signal=""
    security="open"
    freq=""
  }
  /signal:/ {
    signal=$2
  }
  /freq:/ {
    freq=$2
  }
  /^[[:space:]]*SSID:/ {
    sub(/^[[:space:]]*SSID: /, "", $0)
    ssid=$0
  }
  /^[[:space:]]*RSN:/ || /^[[:space:]]*WPA:/ {
    security="secured"
  }
  END {
    if (seen) {
      printf "%s\t%s\t%s\t%s\n", ssid, signal, security, freq
    }
  }
' | jq -Rsc '
  (split("\n") | map(select(length > 0) | split("\t"))) as $rows
  | {
      ok: true,
      status: "ok",
      networks: [
        $rows[] | {
          ssid: .[0],
          signal_dbm: (.[1] | tonumber? // 0),
          security: .[2],
          frequency_mhz: (.[3] | tonumber? // 0),
          band: (if (.[3] | tonumber? // 0) >= 5000 then "5ghz" else "2.4ghz" end)
        }
      ]
    }
'
