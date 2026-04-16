#!/bin/bash
set -euo pipefail

LOG_TAG="gateway-startup"
BASE_DIR="/opt/gateway"
STATE_DIR="${BASE_DIR}/state"
SCRIPTS_DIR="${BASE_DIR}/scripts"
CONFIG_DIR="${BASE_DIR}/config"
GENERATED_DIR="${BASE_DIR}/generated_network"
STORAGE_DIR="${BASE_DIR}/software_storage"
WEBPAGE_NETWORK_DIR="${STORAGE_DIR}/webpage_network"
DEFAULT_SETTINGS="${CONFIG_DIR}/default-network-settings.json"
ACTIVE_SETTINGS="${WEBPAGE_NETWORK_DIR}/network_settings.json"

log() {
  logger -t "${LOG_TAG}" "$*"
  printf '%s\n' "$*"
}

install -d -m 0755 "${BASE_DIR}"
install -d -m 0755 "${SCRIPTS_DIR}"
install -d -m 0755 "${CONFIG_DIR}"
install -d -m 0755 "${STATE_DIR}"
install -d -m 0755 "${GENERATED_DIR}"
install -d -m 0755 "${STORAGE_DIR}"
install -d -m 0755 "${WEBPAGE_NETWORK_DIR}"

log "startup script begin"

if [ -f "${DEFAULT_SETTINGS}" ] && [ ! -f "${ACTIVE_SETTINGS}" ]; then
  cp "${DEFAULT_SETTINGS}" "${ACTIVE_SETTINGS}"
  log "default network settings installed"
fi

if command -v ip >/dev/null 2>&1; then
  ip link show eth0 >/dev/null 2>&1 || true
fi

date --iso-8601=seconds > "${STATE_DIR}/last-boot.txt"
touch "${STATE_DIR}/startup-ran"

log "startup script end"
