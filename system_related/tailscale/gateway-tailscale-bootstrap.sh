#!/bin/bash
set -euo pipefail

: "${TS_FUNNEL_ENABLE:=true}"
: "${TS_FUNNEL_PORT:=8000}"
: "${TS_HOSTNAME_PREFIX:=metacrust}"
: "${TS_ROUTE_STABLE_SECONDS:=12}"
: "${TS_ROUTE_STABLE_TIMEOUT:=120}"
: "${TS_CERT_RETRIES:=6}"
: "${TS_FUNNEL_RETRIES:=6}"
: "${TS_RETRY_DELAY:=10}"

LOG_TAG="gateway-tailscale-bootstrap"

log() {
  logger -t "${LOG_TAG}" "$*"
  printf '%s\n' "$*"
}

default_route_key() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") dev = $(i + 1)
        if ($i == "via") via = $(i + 1)
        if ($i == "src") src = $(i + 1)
      }
      if (dev != "") {
        printf "dev=%s via=%s src=%s\n", dev, via, src
      }
    }
  '
}

wait_for_stable_default_route() {
  local previous current stable_for waited step
  previous=""
  stable_for=0
  waited=0
  step=2

  while [ "${waited}" -lt "${TS_ROUTE_STABLE_TIMEOUT}" ]; do
    current="$(default_route_key)"
    if [ -n "${current}" ] && [ "${current}" = "${previous}" ]; then
      stable_for=$((stable_for + step))
      if [ "${stable_for}" -ge "${TS_ROUTE_STABLE_SECONDS}" ]; then
        log "default route stable for ${stable_for}s: ${current}"
        return 0
      fi
    else
      [ -n "${current}" ] && log "default route observed: ${current}"
      previous="${current}"
      stable_for=0
    fi
    sleep "${step}"
    waited=$((waited + step))
  done

  log "default route did not stabilize within ${TS_ROUTE_STABLE_TIMEOUT}s; continuing"
  return 0
}

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

wait_for_stable_default_route

if ! tailscale status >/dev/null 2>&1; then
  if [ -z "${TS_AUTHKEY:-}" ]; then
    echo "TS_AUTHKEY is not set; cannot authenticate Tailscale" >&2
    exit 1
  fi

  up_args=(up "--auth-key=${TS_AUTHKEY}" "--hostname=$(gateway_hostname)")

  tailscale "${up_args[@]}"
fi

wait_for_stable_default_route

tailscale_dns_name() {
  if command -v jq >/dev/null 2>&1; then
    tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//'
  fi
}

run_with_retries() {
  local description="$1" max_attempts="$2"
  shift 2
  local attempt
  attempt=1
  while [ "${attempt}" -le "${max_attempts}" ]; do
    log "${description}: attempt ${attempt}/${max_attempts}"
    if "$@"; then
      log "${description}: ok"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep "${TS_RETRY_DELAY}"
    wait_for_stable_default_route
  done
  log "${description}: failed after ${max_attempts} attempts"
  return 1
}

prepare_funnel_cert() {
  local dns_name
  dns_name="$(tailscale_dns_name)"
  if [ -z "${dns_name}" ] || [ "${dns_name}" = "null" ]; then
    log "tailscale DNS name unavailable; skipping explicit certificate preparation"
    return 0
  fi
  tailscale cert \
    --cert-file="/run/gateway-tailscale-funnel.crt" \
    --key-file="/run/gateway-tailscale-funnel.key" \
    "${dns_name}"
}

if [ "${TS_FUNNEL_ENABLE}" = "true" ]; then
  run_with_retries "tailscale certificate preparation" "${TS_CERT_RETRIES}" prepare_funnel_cert || true
  run_with_retries "tailscale funnel setup" "${TS_FUNNEL_RETRIES}" tailscale funnel --bg "${TS_FUNNEL_PORT}"
else
  log "tailscale funnel disabled by TS_FUNNEL_ENABLE=${TS_FUNNEL_ENABLE}"
fi
