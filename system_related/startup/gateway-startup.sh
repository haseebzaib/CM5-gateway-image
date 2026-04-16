#!/bin/bash
set -euo pipefail

LOG_TAG="gateway-startup"
BASE_DIR="/opt/gateway"
SCRIPTS_DIR="${BASE_DIR}/scripts"
STORAGE_DIR="${BASE_DIR}/software_storage"
AES_STORAGE_DIR="${STORAGE_DIR}/AES"
SYSTEM_RELATED_DIR="${BASE_DIR}/system_related"
NETWORK_DIR="${SYSTEM_RELATED_DIR}/network"
NETWORK_CONFIG_DIR="${NETWORK_DIR}/config"
NETWORK_STATE_DIR="${NETWORK_DIR}/state"
NETWORK_GENERATED_DIR="${NETWORK_DIR}/generated"
DEFAULT_SETTINGS="${NETWORK_CONFIG_DIR}/default-network-settings.json"
ACTIVE_SETTINGS="${AES_STORAGE_DIR}/network_settings.json"

log() {
  logger -t "${LOG_TAG}" "$*"
  printf '%s\n' "$*"
}

install -d -m 0755 "${BASE_DIR}"
install -d -m 0755 "${SCRIPTS_DIR}"
install -d -m 0755 "${STORAGE_DIR}"
install -d -m 0755 "${AES_STORAGE_DIR}"
install -d -m 0755 "${SYSTEM_RELATED_DIR}"
install -d -m 0755 "${NETWORK_DIR}"
install -d -m 0755 "${NETWORK_CONFIG_DIR}"
install -d -m 0755 "${NETWORK_STATE_DIR}"
install -d -m 0755 "${NETWORK_GENERATED_DIR}"

log "startup script begin"

if [ -f "${DEFAULT_SETTINGS}" ] && [ ! -f "${ACTIVE_SETTINGS}" ]; then
  cp "${DEFAULT_SETTINGS}" "${ACTIVE_SETTINGS}"
  log "default network settings installed"
fi

if command -v ip >/dev/null 2>&1; then
  ip link show eth0 >/dev/null 2>&1 || true
fi

date --iso-8601=seconds > "${NETWORK_STATE_DIR}/last-boot.txt"
touch "${NETWORK_STATE_DIR}/startup-ran"

log "startup script end"
