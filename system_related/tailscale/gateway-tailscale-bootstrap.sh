#!/bin/bash
set -euo pipefail

: "${TS_FUNNEL_PORT:=8000}"
: "${TS_HOSTNAME_PREFIX:=metacrust}"

gateway_hostname() {
  local iface mac clean

  if [ -n "${TS_HOSTNAME:-}" ]; then
    printf '%s\n' "${TS_HOSTNAME}"
    return 0
  fi

  for iface in eth0 eth1 wlan0; do
    if [ -r "/sys/class/net/${iface}/address" ]; then
      mac="$(cat "/sys/class/net/${iface}/address")"
      clean="${mac//:/}"
      clean="${clean,,}"
      if [ "${#clean}" = 12 ] && [ "${clean}" != "000000000000" ]; then
        printf '%s-%s\n' "${TS_HOSTNAME_PREFIX}" "${clean}"
        return 0
      fi
    fi
  done

  printf '%s-unknown\n' "${TS_HOSTNAME_PREFIX}"
}

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale command is not installed" >&2
  exit 1
fi

if ! systemctl is-active --quiet tailscaled; then
  systemctl start tailscaled
fi

if ! tailscale status >/dev/null 2>&1; then
  if [ -z "${TS_AUTHKEY:-}" ]; then
    echo "TS_AUTHKEY is not set; cannot authenticate Tailscale" >&2
    exit 1
  fi

  up_args=(up "--auth-key=${TS_AUTHKEY}" "--hostname=$(gateway_hostname)")

  tailscale "${up_args[@]}"
fi

tailscale funnel --bg "${TS_FUNNEL_PORT}"
