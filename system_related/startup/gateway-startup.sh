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
LAST_GOOD_SETTINGS="${AES_STORAGE_DIR}/network_settings.last_good.json"
APPLY_RESULT_FILE="${NETWORK_STATE_DIR}/network_apply_result.json"
BOOT_FAIL_COUNT_FILE="${NETWORK_STATE_DIR}/boot_fail_count"
RECOVERY_STATE_FILE="${NETWORK_STATE_DIR}/startup_recovery_state.json"
SAFE_MODE_FILE="${NETWORK_STATE_DIR}/safe_mode_active"
BOOT_FAIL_THRESHOLD=2

log() {
  logger -t "${LOG_TAG}" "$*"
  printf '%s\n' "$*"
}

write_json_file() {
  local target="$1"
  local tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  cat > "${tmp}"
  mv "${tmp}" "${target}"
}

read_fail_count() {
  if [ -f "${BOOT_FAIL_COUNT_FILE}" ]; then
    cat "${BOOT_FAIL_COUNT_FILE}" 2>/dev/null || printf '0'
  else
    printf '0'
  fi
}

write_fail_count() {
  printf '%s\n' "$1" > "${BOOT_FAIL_COUNT_FILE}"
}

record_recovery_state() {
  local mode="$1"
  local details="$2"
  write_json_file "${RECOVERY_STATE_FILE}" <<EOF
{
  "timestamp": "$(date --iso-8601=seconds)",
  "mode": "${mode}",
  "details": ${details}
}
EOF
}

restore_last_good() {
  cp "${LAST_GOOD_SETTINGS}" "${ACTIVE_SETTINGS}"
  rm -f "${SAFE_MODE_FILE}"
  record_recovery_state "restored_last_good" '{"reason":"previous_apply_failed"}'
  log "previous apply failed, restored last known good network settings"
}

restore_safe_defaults() {
  cp "${DEFAULT_SETTINGS}" "${ACTIVE_SETTINGS}"
  touch "${SAFE_MODE_FILE}"
  record_recovery_state "safe_defaults" '{"reason":"repeated_apply_failures"}'
  log "recovery safe mode active, restored default Ethernet-first network settings"
}

handle_previous_apply_result() {
  local previous_ok previous_status fail_count

  [ -f "${APPLY_RESULT_FILE}" ] || return 0

  previous_ok="$(jq -r '.ok // false' "${APPLY_RESULT_FILE}" 2>/dev/null || printf 'false')"
  previous_status="$(jq -r '.status // "unknown"' "${APPLY_RESULT_FILE}" 2>/dev/null || printf 'unknown')"

  if [ "${previous_ok}" = "true" ]; then
    write_fail_count 0
    rm -f "${SAFE_MODE_FILE}"
    record_recovery_state "normal_boot" "{\"previous_status\":\"${previous_status}\"}"
    return 0
  fi

  fail_count="$(read_fail_count)"
  fail_count=$((fail_count + 1))
  write_fail_count "${fail_count}"

  if [ -f "${LAST_GOOD_SETTINGS}" ] && [ "${fail_count}" -lt "${BOOT_FAIL_THRESHOLD}" ]; then
    restore_last_good
  else
    restore_safe_defaults
  fi
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

handle_previous_apply_result

if command -v ip >/dev/null 2>&1; then
  ip link show eth0 >/dev/null 2>&1 || true
fi

date --iso-8601=seconds > "${NETWORK_STATE_DIR}/last-boot.txt"
touch "${NETWORK_STATE_DIR}/startup-ran"

log "startup script end"
