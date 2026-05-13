#!/bin/bash
set -Eeuo pipefail

LOG_TAG="gateway-grow-rootfs"
BASE_DIR="/opt/gateway"
NETWORK_DIR="${BASE_DIR}/network"
STATE_FILE="${NETWORK_DIR}/rootfs-grow-state.json"
DONE_FILE="${NETWORK_DIR}/rootfs-grow-complete"

log() {
  logger -t "${LOG_TAG}" "$*" || true
  printf '%s\n' "$*"
}

json_escape() {
  printf '%s' "$1" | jq -Rsa .
}

write_state() {
  local status="$1" reason="$2" root_dev="$3" disk="$4" before_part="$5" after_part="$6" before_fs="$7" after_fs="$8"
  local tmp
  install -d -m 0755 "${NETWORK_DIR}"
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  cat > "${tmp}" <<EOF
{
  "timestamp": "$(date --iso-8601=seconds)",
  "status": $(json_escape "${status}"),
  "reason": $(json_escape "${reason}"),
  "root_device": $(json_escape "${root_dev}"),
  "disk": $(json_escape "${disk}"),
  "partition_bytes_before": ${before_part:-0},
  "partition_bytes_after": ${after_part:-0},
  "filesystem_bytes_before": ${before_fs:-0},
  "filesystem_bytes_after": ${after_fs:-0}
}
EOF
  chmod 0644 "${tmp}"
  mv "${tmp}" "${STATE_FILE}"
}

bytes_or_zero() {
  "$@" 2>/dev/null || printf '0\n'
}

main() {
  local root_source root_dev root_fs parent_name part_num disk
  local before_part after_part before_fs after_fs grow_output grow_rc

  install -d -m 0755 "${NETWORK_DIR}"

  if [ -f "${DONE_FILE}" ]; then
    log "rootfs expansion already completed"
    return 0
  fi

  root_source="$(findmnt -n -o SOURCE --target / 2>/dev/null || true)"
  root_dev="$(readlink -f "${root_source}" 2>/dev/null || true)"
  root_fs="$(findmnt -n -o FSTYPE --target / 2>/dev/null || true)"

  if [ -z "${root_dev}" ] || [ ! -b "${root_dev}" ]; then
    write_state "skipped" "root block device not found" "${root_dev}" "" 0 0 0 0
    log "skipping rootfs expansion: root block device not found"
    return 0
  fi

  if [ "${root_fs}" != "ext4" ]; then
    write_state "skipped" "unsupported root filesystem: ${root_fs}" "${root_dev}" "" 0 0 0 0
    log "skipping rootfs expansion: unsupported root filesystem ${root_fs}"
    return 0
  fi

  if ! command -v growpart >/dev/null 2>&1; then
    write_state "skipped" "growpart command missing" "${root_dev}" "" 0 0 0 0
    log "skipping rootfs expansion: growpart command missing"
    return 0
  fi

  parent_name="$(lsblk -no PKNAME "${root_dev}" 2>/dev/null | head -n1 | tr -d '[:space:]')"
  part_num="$(lsblk -no PARTN "${root_dev}" 2>/dev/null | head -n1 | tr -d '[:space:]')"

  if [ -z "${parent_name}" ] || [ -z "${part_num}" ]; then
    write_state "skipped" "could not identify root disk/partition" "${root_dev}" "" 0 0 0 0
    log "skipping rootfs expansion: could not identify root disk/partition"
    return 0
  fi

  disk="/dev/${parent_name}"
  before_part="$(bytes_or_zero blockdev --getsize64 "${root_dev}")"
  before_fs="$(df -B1 --output=size / 2>/dev/null | awk 'NR == 2 {print $1}')"
  before_fs="${before_fs:-0}"

  log "expanding root partition ${root_dev} on ${disk} partition ${part_num}"

  set +e
  grow_output="$(growpart "${disk}" "${part_num}" 2>&1)"
  grow_rc=$?
  set -e

  if [ "${grow_rc}" -ne 0 ] && ! printf '%s\n' "${grow_output}" | grep -qi 'NOCHANGE'; then
    after_part="$(bytes_or_zero blockdev --getsize64 "${root_dev}")"
    after_fs="$(df -B1 --output=size / 2>/dev/null | awk 'NR == 2 {print $1}')"
    after_fs="${after_fs:-0}"
    write_state "failed" "growpart failed: ${grow_output}" "${root_dev}" "${disk}" "${before_part}" "${after_part}" "${before_fs}" "${after_fs}"
    log "root partition expansion failed: ${grow_output}"
    return 0
  fi

  log "growpart result: ${grow_output:-ok}"
  partprobe "${disk}" >/dev/null 2>&1 || true
  partx -u "${disk}" >/dev/null 2>&1 || true
  udevadm settle >/dev/null 2>&1 || true

  if resize2fs "${root_dev}" >/tmp/gateway-grow-rootfs-resize2fs.log 2>&1; then
    after_part="$(bytes_or_zero blockdev --getsize64 "${root_dev}")"
    after_fs="$(df -B1 --output=size / 2>/dev/null | awk 'NR == 2 {print $1}')"
    after_fs="${after_fs:-0}"
    write_state "complete" "root filesystem expanded" "${root_dev}" "${disk}" "${before_part}" "${after_part}" "${before_fs}" "${after_fs}"
    touch "${DONE_FILE}"
    chmod 0644 "${DONE_FILE}"
    log "root filesystem expansion complete: partition ${before_part}->${after_part} bytes, filesystem ${before_fs}->${after_fs} bytes"
  else
    after_part="$(bytes_or_zero blockdev --getsize64 "${root_dev}")"
    after_fs="$(df -B1 --output=size / 2>/dev/null | awk 'NR == 2 {print $1}')"
    after_fs="${after_fs:-0}"
    write_state "failed" "resize2fs failed: $(tr '\r\n' '  ' </tmp/gateway-grow-rootfs-resize2fs.log | cut -c1-300)" "${root_dev}" "${disk}" "${before_part}" "${after_part}" "${before_fs}" "${after_fs}"
    log "root filesystem resize failed"
  fi
}

main "$@"
