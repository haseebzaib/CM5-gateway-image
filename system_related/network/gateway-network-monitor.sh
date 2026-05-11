#!/bin/bash
# gateway-network-monitor.sh
#
# PURPOSE: Uplink connectivity monitoring ONLY.
#   - Watches eth0, eth1, wifi_client for uplink health
#   - Switches active uplink based on priority and connectivity checks
#   - Triggers gateway-network-apply on config change or recovery
#   - Does NOT manage eth0/eth1 interface state — those are permanently up
#
set -euo pipefail

LOG_TAG="gateway-network-monitor"
BASE_DIR="/opt/gateway"
NETWORK_DIR="${BASE_DIR}/network"
STORAGE_DIR="${BASE_DIR}/software_storage/AES"
ACTIVE_SETTINGS="${STORAGE_DIR}/network_settings.json"
STATE_FILE="${NETWORK_DIR}/state.json"
RESULT_FILE="${NETWORK_DIR}/apply-result.json"
MONITOR_STATE_FILE="${NETWORK_DIR}/monitor-state.json"
UPLINK_STATS_FILE="${NETWORK_DIR}/uplink-stats.json"
RECOVERY_STATE_FILE="${NETWORK_DIR}/recovery-state.json"
CELLULAR_STATE_FILE="${NETWORK_DIR}/cellular-state.json"
CELLULAR_RETRY_STATE_FILE="${NETWORK_DIR}/cellular-retry-state.json"
TAILSCALE_RECOVERY_STATE_FILE="${NETWORK_DIR}/tailscale-recovery-state.json"
NETWORKCTL="${BASE_DIR}/scripts/gateway-networkctl"
CELLULARCTL="${BASE_DIR}/scripts/gateway-cellular-qmi"
TAILSCALE_BOOTSTRAP_SERVICE="gateway-tailscale-bootstrap.service"
TAILSCALE_ENV_FILE="${BASE_DIR}/secrets/tailscale.env"

MONITOR_INTERVAL=5
SUMMARY_INTERVAL=60
RECOVERY_COOLDOWN=30
APPLY_GRACE_PERIOD=20
CELLULAR_RETRY_MIN_INTERVAL=60
CELLULAR_RETRY_MAX_INTERVAL=300
TAILSCALE_RECOVERY_COOLDOWN=180
TAILSCALE_HEALTH_INTERVAL=60

log() {
  logger -t "${LOG_TAG}" "$*"
  printf '%s\n' "$*"
}

json_escape() {
  printf '%s' "$1" | jq -Rsa .
}

write_json_file() {
  local target="$1"
  local tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  cat > "${tmp}"
  mv "${tmp}" "${target}"
}

ensure_runtime_files() {
  install -d -m 0755 "${NETWORK_DIR}" "${STORAGE_DIR}"
  local json_file
  for json_file in "${MONITOR_STATE_FILE}" "${UPLINK_STATS_FILE}" "${RECOVERY_STATE_FILE}" "${CELLULAR_RETRY_STATE_FILE}" "${TAILSCALE_RECOVERY_STATE_FILE}"; do
    if [ -f "${json_file}" ] && ! jq empty "${json_file}" >/dev/null 2>&1; then
      log "runtime state file is invalid JSON, recreating: ${json_file}"
      rm -f "${json_file}"
    fi
  done
  if [ ! -f "${MONITOR_STATE_FILE}" ]; then
    write_json_file "${MONITOR_STATE_FILE}" <<'EOF'
{
  "last_config_hash": "",
  "pending_candidate": "",
  "pending_since_epoch": 0,
  "active_uplink": "none",
  "last_switch_timestamp": "",
  "uplinks": {
    "eth0":        { "ready_count": 0, "fail_count": 0, "eligible": false, "last_ready": false, "internet_ok": false },
    "eth1":        { "ready_count": 0, "fail_count": 0, "eligible": false, "last_ready": false, "internet_ok": false },
    "wifi_client": { "ready_count": 0, "fail_count": 0, "eligible": false, "last_ready": false, "internet_ok": false },
    "cellular":    { "ready_count": 0, "fail_count": 0, "eligible": false, "last_ready": false, "internet_ok": false }
  }
}
EOF
  fi
  if [ ! -f "${UPLINK_STATS_FILE}" ]; then
    write_json_file "${UPLINK_STATS_FILE}" <<'EOF'
{
  "started_timestamp": "",
  "started_epoch": 0,
  "updated_timestamp": "",
  "updated_epoch": 0,
  "active_uplink": "none",
  "active_since_timestamp": "",
  "active_since_epoch": 0,
  "switch_count": 0,
  "last_switch": {
    "from": "none",
    "to": "none",
    "started_epoch": 0,
    "completed_epoch": 0,
    "duration_seconds": 0,
    "reason": ""
  },
  "network": {
    "has_uplink": false,
    "down_since_timestamp": "",
    "down_since_epoch": 0,
    "current_down_seconds": 0,
    "last_down_duration_seconds": 0,
    "total_down_seconds": 0,
    "down_events": 0
  },
  "interfaces": {
    "eth0": {"enabled": true, "eligible": false, "status": "unknown", "down_since_timestamp": "", "down_since_epoch": 0, "current_down_seconds": 0, "last_down_duration_seconds": 0, "total_down_seconds": 0, "down_events": 0, "last_up_timestamp": "", "last_down_timestamp": ""},
    "eth1": {"enabled": true, "eligible": false, "status": "unknown", "down_since_timestamp": "", "down_since_epoch": 0, "current_down_seconds": 0, "last_down_duration_seconds": 0, "total_down_seconds": 0, "down_events": 0, "last_up_timestamp": "", "last_down_timestamp": ""},
    "wifi_client": {"enabled": false, "eligible": false, "status": "disabled", "down_since_timestamp": "", "down_since_epoch": 0, "current_down_seconds": 0, "last_down_duration_seconds": 0, "total_down_seconds": 0, "down_events": 0, "last_up_timestamp": "", "last_down_timestamp": ""},
    "cellular": {"enabled": false, "eligible": false, "status": "disabled", "down_since_timestamp": "", "down_since_epoch": 0, "current_down_seconds": 0, "last_down_duration_seconds": 0, "total_down_seconds": 0, "down_events": 0, "last_up_timestamp": "", "last_down_timestamp": ""}
  }
}
EOF
  fi
  if [ ! -f "${RECOVERY_STATE_FILE}" ]; then
    write_json_file "${RECOVERY_STATE_FILE}" <<'EOF'
{ "last_recovery_timestamp": "", "last_recovery_epoch": 0, "recovery_count": 0, "last_recovery_reason": "" }
EOF
  fi
  if [ ! -f "${CELLULAR_RETRY_STATE_FILE}" ]; then
    write_json_file "${CELLULAR_RETRY_STATE_FILE}" <<'EOF'
{ "last_attempt_timestamp": "", "last_attempt_epoch": 0, "next_attempt_epoch": 0, "attempt_count": 0, "last_result": "", "last_reason": "" }
EOF
  fi
  if [ ! -f "${TAILSCALE_RECOVERY_STATE_FILE}" ]; then
    write_json_file "${TAILSCALE_RECOVERY_STATE_FILE}" <<'EOF'
{ "last_trigger_timestamp": "", "last_trigger_epoch": 0, "trigger_count": 0, "last_reason": "" }
EOF
  fi
}

bool_json() { [ "$1" = "true" ] && printf true || printf false; }

interface_up()   { ip -j link show "$1" 2>/dev/null | jq -r 'if length == 0 then false else (.[0].flags | index("UP") != null) end'; }
interface_link() { ip -j link show "$1" 2>/dev/null | jq -r 'if length == 0 then false else .[0].operstate == "UP" end'; }
interface_addr() { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -n1; }

load_connectivity_targets() {
  mapfile -t CONNECTIVITY_TARGETS < <(jq -r '.network.uplink.connectivity_targets[]? // empty' "${ACTIVE_SETTINGS}")
  if [ "${#CONNECTIVITY_TARGETS[@]}" -eq 0 ]; then
    CONNECTIVITY_TARGETS=("1.1.1.1" "8.8.8.8")
  fi
}

cellular_state_json() {
  if [ -f "${CELLULAR_STATE_FILE}" ] && jq empty "${CELLULAR_STATE_FILE}" >/dev/null 2>&1; then
    cat "${CELLULAR_STATE_FILE}"
  else
    printf '{}\n'
  fi
}

cellular_state_key() {
  cellular_state_json | jq -r '
    [
      (.enabled // false),
      (.present // false),
      (.sim_status // "unknown"),
      (.operator // ""),
      (.signal_percent // 0),
      (.registered // false),
      (.connected // false),
      (.address // ""),
      (.internet_ok // false),
      (.last_error // "")
    ] | @tsv
  '
}

cellular_status_text() {
  cellular_state_json | jq -r '
    "cellular state enabled=\(.enabled // false)" +
    " present=\(.present // false)" +
    " sim=\(.sim_status // "unknown")" +
    " operator=\(.operator // "")" +
    " signal=\(.signal_percent // 0)" +
    " registered=\(.registered // false)" +
    " connected=\(.connected // false)" +
    " address=\(.address // "")" +
    " internet=\(.internet_ok // false)" +
    " error=\((.last_error // "") | gsub("[\r\n]+"; " ") | .[0:180])"
  '
}

log_cellular_state_if_changed() {
  local current_key="$1" previous_key="$2"
  [ "${current_key}" = "${previous_key}" ] && return 0
  log "$(cellular_status_text)"
}

run_apply() {
  local reason="$1" output status active warnings
  output="/tmp/gateway-network-monitor-apply.log"
  log "${reason}, triggering apply"
  if "${NETWORKCTL}" apply >"${output}" 2>&1; then
    status="$(jq -r '.status // "unknown"' "${RESULT_FILE}" 2>/dev/null || printf unknown)"
    active="$(jq -r '.active_uplink // "none"' "${RESULT_FILE}" 2>/dev/null || printf none)"
    warnings="$(jq -r '[.warnings[]?.message] | join("; ")' "${RESULT_FILE}" 2>/dev/null || true)"
    log "apply finished status=${status} active_uplink=${active}$([ -n "${warnings}" ] && printf ' warnings=%s' "${warnings}")"
  else
    log "apply command failed: $(tr '\r\n' '  ' < "${output}" | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-240)"
  fi
}

internet_ok() {
  local iface="$1" target
  for target in "${CONNECTIVITY_TARGETS[@]}"; do
    if ping -I "${iface}" -c 1 -W 2 "${target}" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

priority_for() {
  local target="$1"
  jq -r --arg t "${target}" '
    .network.uplink.uplink_priority
    | to_entries
    | map(select(.value == $t))
    | if length == 0 then 999 else (.[0].key + 1) end
  ' "${ACTIVE_SETTINGS}"
}

effective_ready() {
  local iface="$1" require_check="$2" link address
  link="$(interface_link "${iface}")"
  address="$(interface_addr "${iface}")"
  [ "${link}" = "true" ] || return 1
  [ -n "${address}" ] || return 1
  if [ "${require_check}" = "true" ]; then internet_ok "${iface}"; else return 0; fi
}

monitor_value()   { jq -r "$1" "${MONITOR_STATE_FILE}"; }
stats_value() { jq -r "$1" "${UPLINK_STATS_FILE}"; }
recovery_value()  { jq -r "$1" "${RECOVERY_STATE_FILE}"; }
cellular_retry_value() { jq -r "$1" "${CELLULAR_RETRY_STATE_FILE}"; }
tailscale_recovery_value() { jq -r "$1" "${TAILSCALE_RECOVERY_STATE_FILE}"; }

last_apply_epoch() {
  [ -f "${RESULT_FILE}" ] && stat -c %Y "${RESULT_FILE}" 2>/dev/null || printf '0\n'
}

write_recovery_state() {
  write_json_file "${RECOVERY_STATE_FILE}" <<EOF
{
  "last_recovery_timestamp": "$(date --iso-8601=seconds)",
  "last_recovery_epoch": $1,
  "recovery_count": $2,
  "last_recovery_reason": $(json_escape "$3")
}
EOF
}

reset_recovery_state() {
  write_json_file "${RECOVERY_STATE_FILE}" <<'EOF'
{ "last_recovery_timestamp": "", "last_recovery_epoch": 0, "recovery_count": 0, "last_recovery_reason": "" }
EOF
}

write_cellular_retry_state() {
  local last_epoch="$1" next_epoch="$2" attempt_count="$3" result="$4" reason="$5"
  local timestamp
  timestamp=""
  [ "${last_epoch}" -gt 0 ] && timestamp="$(date --date="@${last_epoch}" --iso-8601=seconds 2>/dev/null || date --iso-8601=seconds)"
  write_json_file "${CELLULAR_RETRY_STATE_FILE}" <<EOF
{
  "last_attempt_timestamp": $(json_escape "${timestamp}"),
  "last_attempt_epoch": ${last_epoch},
  "next_attempt_epoch": ${next_epoch},
  "attempt_count": ${attempt_count},
  "last_result": $(json_escape "${result}"),
  "last_reason": $(json_escape "${reason}")
}
EOF
}

reset_cellular_retry_state() {
  write_cellular_retry_state 0 0 0 "" ""
}

epoch_to_iso() {
  local epoch="$1"
  [ "${epoch}" -gt 0 ] || { printf ''; return 0; }
  date --date="@${epoch}" --iso-8601=seconds 2>/dev/null || date --iso-8601=seconds
}

interface_timing_json() {
  local key="$1" enabled="$2" eligible="$3" last_ready="$4" internet_state="$5" now="$6"
  local prev_down_since prev_total prev_events prev_last_duration prev_last_up prev_last_down
  local down_since current_down total events last_duration last_up last_down status

  prev_down_since="$(stats_value ".interfaces[\"${key}\"].down_since_epoch // 0")"
  prev_total="$(stats_value ".interfaces[\"${key}\"].total_down_seconds // 0")"
  prev_events="$(stats_value ".interfaces[\"${key}\"].down_events // 0")"
  prev_last_duration="$(stats_value ".interfaces[\"${key}\"].last_down_duration_seconds // 0")"
  prev_last_up="$(stats_value ".interfaces[\"${key}\"].last_up_timestamp // \"\"")"
  prev_last_down="$(stats_value ".interfaces[\"${key}\"].last_down_timestamp // \"\"")"

  down_since="${prev_down_since}"
  current_down=0
  total="${prev_total}"
  events="${prev_events}"
  last_duration="${prev_last_duration}"
  last_up="${prev_last_up}"
  last_down="${prev_last_down}"

  if [ "${enabled}" != "true" ]; then
    status="disabled"
    down_since=0
    current_down=0
  elif [ "${eligible}" = "true" ]; then
    status="up"
    if [ "${prev_down_since}" -gt 0 ]; then
      last_duration=$((now - prev_down_since))
      [ "${last_duration}" -lt 0 ] && last_duration=0
      total=$((prev_total + last_duration))
    fi
    down_since=0
    current_down=0
    last_up="$(epoch_to_iso "${now}")"
  else
    status="down"
    if [ "${prev_down_since}" -gt 0 ]; then
      down_since="${prev_down_since}"
    else
      down_since="${now}"
      events=$((prev_events + 1))
      last_down="$(epoch_to_iso "${now}")"
    fi
    current_down=$((now - down_since))
    [ "${current_down}" -lt 0 ] && current_down=0
  fi

  jq -n \
    --arg status "${status}" \
    --arg down_since_ts "$(epoch_to_iso "${down_since}")" \
    --arg last_up "${last_up}" \
    --arg last_down "${last_down}" \
    --argjson enabled "$(bool_json "${enabled}")" \
    --argjson eligible "$(bool_json "${eligible}")" \
    --argjson last_ready "$(bool_json "${last_ready}")" \
    --argjson internet_ok "$(bool_json "${internet_state}")" \
    --argjson down_since "${down_since}" \
    --argjson current_down "${current_down}" \
    --argjson last_duration "${last_duration}" \
    --argjson total "${total}" \
    --argjson events "${events}" \
    '{
      enabled: $enabled,
      eligible: $eligible,
      last_ready: $last_ready,
      internet_ok: $internet_ok,
      status: $status,
      down_since_timestamp: $down_since_ts,
      down_since_epoch: $down_since,
      current_down_seconds: $current_down,
      last_down_duration_seconds: $last_duration,
      total_down_seconds: $total,
      down_events: $events,
      last_up_timestamp: $last_up,
      last_down_timestamp: $last_down
    }'
}

update_uplink_stats() {
  local now="$1" active="$2" previous_active="$3" pending_since="$4"
  local eth0_eligible="$5" eth0_last="$6" eth0_internet="$7"
  local eth1_eligible="$8" eth1_last="$9" eth1_internet="${10}"
  local wifi_enabled="${11}" wifi_eligible="${12}" wifi_last="${13}" wifi_internet="${14}"
  local cellular_enabled="${15}" cellular_eligible="${16}" cellular_last="${17}" cellular_internet="${18}"
  local prev_active prev_active_since prev_started_epoch prev_started_timestamp prev_switch_count
  local prev_network_down_since prev_network_total prev_network_events prev_network_last_duration
  local network_down_since network_current_down network_total network_events network_last_duration
  local has_uplink active_since switch_count switch_started switch_duration
  local last_switch_json eth0_json eth1_json wifi_json cellular_json

  prev_active="$(stats_value '.active_uplink // "none"')"
  prev_active_since="$(stats_value '.active_since_epoch // 0')"
  prev_started_epoch="$(stats_value '.started_epoch // 0')"
  prev_started_timestamp="$(stats_value '.started_timestamp // ""')"
  prev_switch_count="$(stats_value '.switch_count // 0')"
  prev_network_down_since="$(stats_value '.network.down_since_epoch // 0')"
  prev_network_total="$(stats_value '.network.total_down_seconds // 0')"
  prev_network_events="$(stats_value '.network.down_events // 0')"
  prev_network_last_duration="$(stats_value '.network.last_down_duration_seconds // 0')"

  [ "${prev_started_epoch}" -gt 0 ] || prev_started_epoch="${now}"
  [ -n "${prev_started_timestamp}" ] || prev_started_timestamp="$(epoch_to_iso "${now}")"

  has_uplink="false"
  [ "${active}" != "none" ] && has_uplink="true"

  network_down_since="${prev_network_down_since}"
  network_current_down=0
  network_total="${prev_network_total}"
  network_events="${prev_network_events}"
  network_last_duration="${prev_network_last_duration}"

  if [ "${has_uplink}" = "true" ]; then
    if [ "${prev_network_down_since}" -gt 0 ]; then
      network_last_duration=$((now - prev_network_down_since))
      [ "${network_last_duration}" -lt 0 ] && network_last_duration=0
      network_total=$((prev_network_total + network_last_duration))
    fi
    network_down_since=0
  else
    if [ "${prev_network_down_since}" -gt 0 ]; then
      network_down_since="${prev_network_down_since}"
    else
      network_down_since="${now}"
      network_events=$((prev_network_events + 1))
    fi
    network_current_down=$((now - network_down_since))
    [ "${network_current_down}" -lt 0 ] && network_current_down=0
  fi

  active_since="${prev_active_since}"
  switch_count="${prev_switch_count}"
  last_switch_json="$(jq -c '.last_switch // {"from":"none","to":"none","started_epoch":0,"completed_epoch":0,"duration_seconds":0,"reason":""}' "${UPLINK_STATS_FILE}")"

  if [ "${active}" != "${prev_active}" ]; then
    active_since="${now}"
    switch_count=$((prev_switch_count + 1))
    switch_started="${now}"
    if [ "${active}" != "none" ]; then
      if [ "${prev_network_down_since}" -gt 0 ]; then
        switch_started="${prev_network_down_since}"
      elif [ "${pending_since}" -gt 0 ]; then
        switch_started="${pending_since}"
      fi
    fi
    switch_duration=$((now - switch_started))
    [ "${switch_duration}" -lt 0 ] && switch_duration=0
    last_switch_json="$(jq -n \
      --arg from "${prev_active}" \
      --arg to "${active}" \
      --arg reason "active_uplink_changed" \
      --arg started_ts "$(epoch_to_iso "${switch_started}")" \
      --arg completed_ts "$(epoch_to_iso "${now}")" \
      --argjson started "${switch_started}" \
      --argjson completed "${now}" \
      --argjson duration "${switch_duration}" \
      '{from:$from,to:$to,started_timestamp:$started_ts,started_epoch:$started,completed_timestamp:$completed_ts,completed_epoch:$completed,duration_seconds:$duration,reason:$reason}')"
  fi

  eth0_json="$(interface_timing_json "eth0" "true" "${eth0_eligible}" "${eth0_last}" "${eth0_internet}" "${now}")"
  eth1_json="$(interface_timing_json "eth1" "true" "${eth1_eligible}" "${eth1_last}" "${eth1_internet}" "${now}")"
  wifi_json="$(interface_timing_json "wifi_client" "${wifi_enabled}" "${wifi_eligible}" "${wifi_last}" "${wifi_internet}" "${now}")"
  cellular_json="$(interface_timing_json "cellular" "${cellular_enabled}" "${cellular_eligible}" "${cellular_last}" "${cellular_internet}" "${now}")"

  jq -n \
    --arg started_ts "${prev_started_timestamp}" \
    --arg updated_ts "$(epoch_to_iso "${now}")" \
    --arg active "${active}" \
    --arg active_since_ts "$(epoch_to_iso "${active_since}")" \
    --arg network_down_ts "$(epoch_to_iso "${network_down_since}")" \
    --argjson started_epoch "${prev_started_epoch}" \
    --argjson updated_epoch "${now}" \
    --argjson active_since "${active_since}" \
    --argjson switch_count "${switch_count}" \
    --argjson last_switch "${last_switch_json}" \
    --argjson has_uplink "$(bool_json "${has_uplink}")" \
    --argjson network_down_since "${network_down_since}" \
    --argjson network_current_down "${network_current_down}" \
    --argjson network_last_duration "${network_last_duration}" \
    --argjson network_total "${network_total}" \
    --argjson network_events "${network_events}" \
    --argjson eth0 "${eth0_json}" \
    --argjson eth1 "${eth1_json}" \
    --argjson wifi "${wifi_json}" \
    --argjson cellular "${cellular_json}" \
    '{
      started_timestamp: $started_ts,
      started_epoch: $started_epoch,
      updated_timestamp: $updated_ts,
      updated_epoch: $updated_epoch,
      active_uplink: $active,
      active_since_timestamp: $active_since_ts,
      active_since_epoch: $active_since,
      active_duration_seconds: (if $active_since > 0 then ($updated_epoch - $active_since) else 0 end),
      switch_count: $switch_count,
      last_switch: $last_switch,
      network: {
        has_uplink: $has_uplink,
        down_since_timestamp: $network_down_ts,
        down_since_epoch: $network_down_since,
        current_down_seconds: $network_current_down,
        last_down_duration_seconds: $network_last_duration,
        total_down_seconds: $network_total,
        down_events: $network_events
      },
      interfaces: {
        eth0: $eth0,
        eth1: $eth1,
        wifi_client: $wifi,
        cellular: $cellular
      }
    }' > "${UPLINK_STATS_FILE}.tmp"
  mv "${UPLINK_STATS_FILE}.tmp" "${UPLINK_STATS_FILE}"
}

write_tailscale_recovery_state() {
  local now="$1" count="$2" reason="$3"
  write_json_file "${TAILSCALE_RECOVERY_STATE_FILE}" <<EOF
{
  "last_trigger_timestamp": "$(date --date="@${now}" --iso-8601=seconds 2>/dev/null || date --iso-8601=seconds)",
  "last_trigger_epoch": ${now},
  "trigger_count": ${count},
  "last_reason": $(json_escape "${reason}")
}
EOF
}

write_monitor_state() {
  # args: hash pending pending_since active last_switch
  #       eth0: ready fail eligible last_ready internet
  #       eth1: ready fail eligible last_ready internet
  #       wifi: ready fail eligible last_ready internet
  #       cellular: ready fail eligible last_ready internet
  write_json_file "${MONITOR_STATE_FILE}" <<EOF
{
  "last_config_hash": "$1",
  "pending_candidate": "$2",
  "pending_since_epoch": $3,
  "active_uplink": "$4",
  "last_switch_timestamp": "$5",
  "uplinks": {
    "eth0":        { "ready_count": $6,  "fail_count": $7,  "eligible": $(bool_json "$8"),  "last_ready": $(bool_json "$9"),  "internet_ok": $(bool_json "${10}") },
    "eth1":        { "ready_count": ${11}, "fail_count": ${12}, "eligible": $(bool_json "${13}"), "last_ready": $(bool_json "${14}"), "internet_ok": $(bool_json "${15}") },
    "wifi_client": { "ready_count": ${16}, "fail_count": ${17}, "eligible": $(bool_json "${18}"), "last_ready": $(bool_json "${19}"), "internet_ok": $(bool_json "${20}") },
    "cellular":    { "ready_count": ${21}, "fail_count": ${22}, "eligible": $(bool_json "${23}"), "last_ready": $(bool_json "${24}"), "internet_ok": $(bool_json "${25}") }
  }
}
EOF
}

# Sample a single uplink candidate.
# For ethernet (eth0/eth1): always considered enabled — just needs link+IP.
# For wifi_client: needs enabled=true in settings.
sample_uplink() {
  local key="$1" iface="$2" enabled="$3" require_check="$4" fail_threshold="$5" recover_threshold="$6"
  local ready_count fail_count current_ready eligible internet_state

  ready_count="$(monitor_value ".uplinks[\"${key}\"].ready_count // 0")"
  fail_count="$(monitor_value ".uplinks[\"${key}\"].fail_count // 0")"
  current_ready="false"
  internet_state="false"

  if [ "${enabled}" = "true" ] && effective_ready "${iface}" "${require_check}"; then
    current_ready="true"
    ready_count=$((ready_count + 1))
    fail_count=0
    [ "${require_check}" = "true" ] && internet_state="true"
  else
    fail_count=$((fail_count + 1))
    ready_count=0
  fi

  [ "${ready_count}" -ge "${recover_threshold}" ] && eligible="true" || eligible="false"
  printf '%s %s %s %s %s\n' "${ready_count}" "${fail_count}" "${eligible}" "${current_ready}" "${internet_state}"
}

set_iface_metric() {
  local iface="$1" new_metric="$2" routes gateway
  routes="$(ip -4 route show default dev "${iface}" || true)"
  [ -n "${routes}" ] || return 0
  if printf '%s\n' "${routes}" | awk -v desired="${new_metric}" '
    {
      metric = "0"
      for (i = 1; i <= NF; i++) {
        if ($i == "metric") {
          metric = $(i + 1)
        }
      }
      if (metric == desired) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '; then
    return 0
  fi
  gateway="$(printf '%s\n' "${routes}" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1);exit}}')"
  while ip -4 route del default dev "${iface}" >/dev/null 2>&1; do :; done
  if [ -n "${gateway}" ]; then
    ip -4 route add default via "${gateway}" dev "${iface}" metric "${new_metric}" >/dev/null 2>&1 || true
  else
    ip -4 route add default dev "${iface}" metric "${new_metric}" >/dev/null 2>&1 || true
  fi
}

apply_route_preference() {
  local active="$1"
  local wifi_metric cellular_metric
  wifi_metric="$(jq -r '.network.wifi_client.route_metric' "${ACTIVE_SETTINGS}")"
  cellular_metric="$(jq -r '.network.cellular as $c | ((($c.modems // []) | map(select(.id == ($c.active_modem_id // "sim7600"))) | first | .route_metric) // 500)' "${ACTIVE_SETTINGS}" 2>/dev/null)"
  cellular_metric="${cellular_metric:-500}"

  # Give active interface the lowest metric (10 = strongly preferred).
  # Non-active eth0/eth1 keep higher metrics for fallback.
  case "${active}" in
    eth0)
      set_iface_metric eth0  10
      set_iface_metric eth1  200
      set_iface_metric wlan0 $((wifi_metric + 1000))
      set_iface_metric wwan0 "${cellular_metric}"
      ;;
    eth1)
      set_iface_metric eth0  100
      set_iface_metric eth1  10
      set_iface_metric wlan0 $((wifi_metric + 1000))
      set_iface_metric wwan0 "${cellular_metric}"
      ;;
    wifi_client)
      set_iface_metric wlan0 10
      set_iface_metric eth0  100
      set_iface_metric eth1  200
      set_iface_metric wwan0 "${cellular_metric}"
      ;;
    cellular)
      set_iface_metric wwan0 10
      set_iface_metric eth0  100
      set_iface_metric eth1  200
      set_iface_metric wlan0 $((wifi_metric + 1000))
      ;;
    *)
      set_iface_metric eth0  100
      set_iface_metric eth1  200
      set_iface_metric wlan0 "${wifi_metric}"
      set_iface_metric wwan0 "${cellular_metric}"
      ;;
  esac
}

write_state_snapshot() {
  local active="$1" monitor_status="$2" require_check="$3"
  local current_apply_result recovery_count recovery_reason recovery_timestamp
  local eth0_link eth0_up eth0_addr eth0_internet
  local eth1_link eth1_up eth1_addr eth1_internet
  local wifi_present wifi_up wifi_link wifi_addr wifi_internet wifi_ssid ap_clients
  local cellular_state cellular_retry_state cellular_for_state uplink_stats active_interface
  local tailscale_trigger_count tailscale_trigger_reason tailscale_trigger_timestamp

  current_apply_result='{}'; [ -f "${RESULT_FILE}" ] && current_apply_result="$(cat "${RESULT_FILE}")"
  uplink_stats='{}'
  if [ -f "${UPLINK_STATS_FILE}" ] && jq empty "${UPLINK_STATS_FILE}" >/dev/null 2>&1; then
    uplink_stats="$(cat "${UPLINK_STATS_FILE}")"
  fi
  recovery_count="$(recovery_value '.recovery_count // 0')"
  recovery_reason="$(recovery_value '.last_recovery_reason // ""')"
  recovery_timestamp="$(recovery_value '.last_recovery_timestamp // ""')"
  tailscale_trigger_count="$(tailscale_recovery_value '.trigger_count // 0')"
  tailscale_trigger_reason="$(tailscale_recovery_value '.last_reason // ""')"
  tailscale_trigger_timestamp="$(tailscale_recovery_value '.last_trigger_timestamp // ""')"
  case "${active}" in
    eth0) active_interface="eth0" ;;
    eth1) active_interface="eth1" ;;
    wifi_client) active_interface="wlan0" ;;
    cellular) active_interface="wwan0" ;;
    *) active_interface="" ;;
  esac

  eth0_link="$(interface_link eth0)"
  eth0_up="$(interface_up eth0)"
  eth0_addr="$(interface_addr eth0)"
  eth0_internet="$(monitor_value '.uplinks["eth0"].internet_ok // false')"

  eth1_link="$(interface_link eth1)"
  eth1_up="$(interface_up eth1)"
  eth1_addr="$(interface_addr eth1)"
  eth1_internet="$(monitor_value '.uplinks["eth1"].internet_ok // false')"

  if ip link show wlan0 >/dev/null 2>&1; then
    wifi_present="true"
    wifi_up="$(interface_up wlan0)"
    wifi_link="$(interface_link wlan0)"
    wifi_addr="$(interface_addr wlan0)"
    wifi_ssid="$(iw dev wlan0 link 2>/dev/null | awk -F': ' '/SSID:/ {print $2; exit}')"
    ap_clients="$(iw dev wlan0 station dump 2>/dev/null | grep -c '^Station' || true)"
    wifi_internet="$(monitor_value '.uplinks["wifi_client"].internet_ok // false')"
  else
    wifi_present="false"; wifi_up="false"; wifi_link="false"
    wifi_addr=""; wifi_ssid=""; ap_clients=0; wifi_internet="false"
  fi
  cellular_state='{"enabled":false,"present":false,"backend":"qmi","interface":"wwan0","control_device":"/dev/cdc-wdm0","modem_manufacturer":"","modem_model":"","modem_revision":"","sim_status":"unknown","operator":"","signal_dbm":0,"signal_percent":0,"registration_state":"unknown","registered":false,"roaming":false,"access_technology":"","connected":false,"address":"","gateway":"","dns":[],"internet_ok":false,"rx_bytes":0,"tx_bytes":0,"session_rx_bytes":0,"session_tx_bytes":0,"last_connect_timestamp":"","last_disconnect_timestamp":"","last_error":""}'
  [ -f "${CELLULAR_STATE_FILE}" ] && cellular_state="$(cat "${CELLULAR_STATE_FILE}")"
  cellular_retry_state='{"last_attempt_timestamp":"","last_attempt_epoch":0,"next_attempt_epoch":0,"attempt_count":0,"last_result":"","last_reason":""}'
  [ -f "${CELLULAR_RETRY_STATE_FILE}" ] && cellular_retry_state="$(cat "${CELLULAR_RETRY_STATE_FILE}")"
  cellular_for_state="$(printf '%s' "${cellular_state}" | jq -c --argjson retry "${cellular_retry_state}" '{
    enabled: (.enabled // false),
    present: (.present // false),
    backend: (.backend // "qmi"),
    interface: (.interface // "wwan0"),
    control_device: (.control_device // "/dev/cdc-wdm0"),
    modem_manufacturer: (.modem_manufacturer // ""),
    modem_model: (.modem_model // ""),
    modem_revision: (.modem_revision // ""),
    sim_status: (.sim_status // "unknown"),
    operator: (.operator // ""),
    signal_dbm: (.signal_dbm // 0),
    signal_percent: (.signal_percent // 0),
    registration_state: (.registration_state // "unknown"),
    registered: (.registered // false),
    roaming: (.roaming // false),
    access_technology: (.access_technology // ""),
    connected: (.connected // false),
    address: (.address // ""),
    gateway: (.gateway // ""),
    dns: (.dns // []),
    internet_ok: (.internet_ok // false),
    rx_bytes: (.rx_bytes // 0),
    tx_bytes: (.tx_bytes // 0),
    session_rx_bytes: (.session_rx_bytes // 0),
    session_tx_bytes: (.session_tx_bytes // 0),
    last_connect_timestamp: (.last_connect_timestamp // ""),
    last_disconnect_timestamp: (.last_disconnect_timestamp // ""),
    last_error: (.last_error // ""),
    retry: {
      last_attempt_timestamp: ($retry.last_attempt_timestamp // ""),
      last_attempt_epoch: ($retry.last_attempt_epoch // 0),
      next_attempt_epoch: ($retry.next_attempt_epoch // 0),
      attempt_count: ($retry.attempt_count // 0),
      last_result: ($retry.last_result // ""),
      last_reason: ($retry.last_reason // "")
    }
  }')"

  write_json_file "${STATE_FILE}" <<EOF
{
  "active_uplink": "${active}",
  "active_interface": $(json_escape "${active_interface}"),
  "monitor_status": "${monitor_status}",
  "last_apply_status": $(json_escape "$(printf '%s' "${current_apply_result}" | jq -r '.status // "unknown"')"),
  "last_apply_timestamp": $(json_escape "$(printf '%s' "${current_apply_result}" | jq -r '.timestamp // ""')"),
  "last_monitor_timestamp": "$(date --iso-8601=seconds)",
  "uplink_stats": $(printf '%s' "${uplink_stats}" | jq -c '.'),
  "recovery": {
    "count": ${recovery_count},
    "last_reason": $(json_escape "${recovery_reason}"),
    "last_timestamp": $(json_escape "${recovery_timestamp}")
  },
  "tailscale_recovery": {
    "count": ${tailscale_trigger_count},
    "last_reason": $(json_escape "${tailscale_trigger_reason}"),
    "last_timestamp": $(json_escape "${tailscale_trigger_timestamp}")
  },
  "eth0": {
    "link_up": $(bool_json "${eth0_link}"),
    "interface_up": $(bool_json "${eth0_up}"),
    "address": $(json_escape "${eth0_addr}"),
    "internet_ok": $(bool_json "${eth0_internet}")
  },
  "eth1": {
    "link_up": $(bool_json "${eth1_link}"),
    "interface_up": $(bool_json "${eth1_up}"),
    "address": $(json_escape "${eth1_addr}"),
    "internet_ok": $(bool_json "${eth1_internet}")
  },
  "wifi_client": {
    "interface": "wlan0",
    "enabled": $(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}"),
    "present": $(bool_json "${wifi_present}"),
    "link_up": $(bool_json "${wifi_link}"),
    "interface_up": $(bool_json "${wifi_up}"),
    "address": $(json_escape "${wifi_addr}"),
    "connected_ssid": $(json_escape "${wifi_ssid}"),
    "internet_ok": $(bool_json "${wifi_internet}")
  },
  "wifi_ap": {
    "interface": "wlan0",
    "enabled": $(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}"),
    "address": $(json_escape "${wifi_addr}"),
    "clients": ${ap_clients}
  },
  "cellular": ${cellular_for_state}
}
EOF
}

service_active() { systemctl is-active --quiet "$1"; }

attempt_runtime_recovery() {
  local reason="$1" now="$2" last_epoch recovery_count
  last_epoch="$(recovery_value '.last_recovery_epoch // 0')"
  recovery_count="$(recovery_value '.recovery_count // 0')"
  [ $((now - last_epoch)) -lt "${RECOVERY_COOLDOWN}" ] && return 0
  recovery_count=$((recovery_count + 1))
  log "runtime recovery triggered: ${reason}"
  "${NETWORKCTL}" apply >/dev/null 2>&1 || true
  write_recovery_state "${now}" "${recovery_count}" "${reason}"
}

trigger_tailscale_recovery() {
  local reason="$1" now="$2" last_epoch trigger_count
  command -v tailscale >/dev/null 2>&1 || return 0
  systemctl list-unit-files "${TAILSCALE_BOOTSTRAP_SERVICE}" >/dev/null 2>&1 || return 0
  systemctl is-active --quiet "${TAILSCALE_BOOTSTRAP_SERVICE}" && return 0

  last_epoch="$(tailscale_recovery_value '.last_trigger_epoch // 0')"
  trigger_count="$(tailscale_recovery_value '.trigger_count // 0')"
  [ $((now - last_epoch)) -lt "${TAILSCALE_RECOVERY_COOLDOWN}" ] && return 0

  trigger_count=$((trigger_count + 1))
  log "tailscale funnel recovery triggered: ${reason}"
  systemctl restart --no-block "${TAILSCALE_BOOTSTRAP_SERVICE}" >/dev/null 2>&1 || true
  write_tailscale_recovery_state "${now}" "${trigger_count}" "${reason}"
}

tailscale_env_value() {
  local key="$1" fallback="$2" value
  value=""
  if [ -r "${TAILSCALE_ENV_FILE}" ]; then
    value="$(awk -F= -v key="${key}" '
      $1 == key {
        value = $2
        gsub(/^["'\'' ]+|["'\'' ]+$/, "", value)
        print value
        exit
      }
    ' "${TAILSCALE_ENV_FILE}")"
  fi
  printf '%s\n' "${value:-${fallback}}"
}

tailscale_funnel_healthy() {
  local funnel_enabled funnel_port status
  command -v tailscale >/dev/null 2>&1 || return 1
  funnel_enabled="$(tailscale_env_value TS_FUNNEL_ENABLE true)"
  [ "${funnel_enabled}" = "true" ] || return 0
  funnel_port="$(tailscale_env_value TS_FUNNEL_PORT 8000)"
  tailscale status >/dev/null 2>&1 || return 1
  status="$(tailscale funnel status 2>/dev/null || true)"
  printf '%s\n' "${status}" | grep -q 'Funnel on' || return 1
  printf '%s\n' "${status}" | grep -Eq "proxy http://127\\.0\\.0\\.1:${funnel_port}(/|$|[[:space:]])" || return 1
}

maybe_recover_tailscale_funnel() {
  local active="$1" now="$2" last_check_var="$3"
  [ "${active}" != "none" ] || return 0
  [ $((now - last_check_var)) -ge "${TAILSCALE_HEALTH_INTERVAL}" ] || return 0
  if ! tailscale_funnel_healthy; then
    trigger_tailscale_recovery "tailscale funnel unhealthy on active uplink ${active}" "${now}"
  fi
}

cellular_connect_blocker() {
  local cellular_enabled="$1"
  local apn sim_status present connected
  [ "${cellular_enabled}" = "true" ] || { printf 'disabled\n'; return 0; }
  apn="$(jq -r '.network.cellular.apn // ""' "${ACTIVE_SETTINGS}")"
  [ -n "${apn}" ] || { printf 'apn_missing\n'; return 0; }
  present="$(cellular_state_json | jq -r '.present // false')"
  [ "${present}" = "true" ] || { printf 'modem_missing\n'; return 0; }
  sim_status="$(cellular_state_json | jq -r '.sim_status // "unknown"')"
  case "${sim_status}" in
    ready|present) ;;
    locked) printf 'sim_locked\n'; return 0 ;;
    missing) printf 'sim_missing\n'; return 0 ;;
    *) printf "sim_${sim_status}\n"; return 0 ;;
  esac
  connected="$(cellular_state_json | jq -r '.connected // false')"
  [ "${connected}" != "true" ] || { printf 'already_connected\n'; return 0; }
  printf '\n'
}

maybe_connect_cellular() {
  local now="$1" cellular_enabled="$2"
  local blocker last_attempt next_attempt attempt_count interval output

  blocker="$(cellular_connect_blocker "${cellular_enabled}")"
  if [ -n "${blocker}" ]; then
    if [ "${blocker}" = "already_connected" ]; then
      reset_cellular_retry_state
    else
      write_cellular_retry_state 0 0 0 "blocked" "${blocker}"
    fi
    return 1
  fi

  last_attempt="$(cellular_retry_value '.last_attempt_epoch // 0')"
  next_attempt="$(cellular_retry_value '.next_attempt_epoch // 0')"
  attempt_count="$(cellular_retry_value '.attempt_count // 0')"
  if [ "${next_attempt}" -gt "${now}" ]; then
    return 1
  fi

  attempt_count=$((attempt_count + 1))
  output="/tmp/gateway-network-monitor-cellular-connect.log"
  log "cellular connect attempt ${attempt_count}: requesting connect"
  if "${CELLULARCTL}" connect >"${output}" 2>&1; then
    write_cellular_retry_state "${now}" 0 0 "connected" ""
    log "cellular connect succeeded"
    return 0
  fi

  interval=$((CELLULAR_RETRY_MIN_INTERVAL * attempt_count))
  [ "${interval}" -gt "${CELLULAR_RETRY_MAX_INTERVAL}" ] && interval="${CELLULAR_RETRY_MAX_INTERVAL}"
  write_cellular_retry_state "${now}" $((now + interval)) "${attempt_count}" "failed" "$(tr '\r\n' '  ' < "${output}" | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-180)"
  log "cellular connect failed; next attempt in ${interval}s"
  return 1
}

main_loop() {
  local current_hash require_check stable_seconds failback_enabled
  local fail_threshold recover_threshold wifi_enabled cellular_enabled
  local active pending pending_since now previous_active last_switch_timestamp switch_started_for_stats
  local candidate candidate_since
  local eth0_ready eth0_fail eth0_eligible eth0_last eth0_internet
  local eth1_ready eth1_fail eth1_eligible eth1_last eth1_internet
  local wifi_ready wifi_fail wifi_eligible wifi_last wifi_internet
  local cellular_ready cellular_fail cellular_eligible cellular_last cellular_internet
  local previous_pending recovery_reason last_apply_at last_summary_epoch
  local previous_cellular_key cellular_key cellular_summary
  local last_tailscale_health_epoch

  last_summary_epoch=0
  last_tailscale_health_epoch=0
  previous_cellular_key=""

  while true; do
    ensure_runtime_files

    if [ ! -f "${ACTIVE_SETTINGS}" ]; then
      run_apply "active settings missing"
      sleep "${MONITOR_INTERVAL}"
      continue
    fi

    current_hash="$(sha256sum "${ACTIVE_SETTINGS}" | awk '{print $1}')"
    LAST_HASH="$(monitor_value '.last_config_hash // ""')"
    if [ "${current_hash}" != "${LAST_HASH}" ]; then
      [ -n "${LAST_HASH}" ] && run_apply "settings changed"
      LAST_HASH="${current_hash}"
    fi

    load_connectivity_targets

    require_check="$(jq -r '.network.uplink.require_connectivity_check' "${ACTIVE_SETTINGS}")"
    stable_seconds="$(jq -r '.network.uplink.stable_seconds_before_switch' "${ACTIVE_SETTINGS}")"
    failback_enabled="$(jq -r '.network.uplink.failback_enabled' "${ACTIVE_SETTINGS}")"
    fail_threshold="$(jq -r '.network.uplink.fail_count_threshold // 1' "${ACTIVE_SETTINGS}")"
    recover_threshold="$(jq -r '.network.uplink.recover_count_threshold // 1' "${ACTIVE_SETTINGS}")"
    wifi_enabled="$(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}")"
    cellular_enabled="$(jq -r '.network.cellular.enabled // false' "${ACTIVE_SETTINGS}")"
    now="$(date +%s)"

    if [ -x "${CELLULARCTL}" ]; then
      "${CELLULARCTL}" refresh-state >/dev/null 2>&1 || true
      cellular_key="$(cellular_state_key)"
      log_cellular_state_if_changed "${cellular_key}" "${previous_cellular_key}"
      previous_cellular_key="${cellular_key}"
      if [ "${cellular_enabled}" != "true" ] || [ "$(cellular_state_json | jq -r '.connected // false')" = "true" ]; then
        reset_cellular_retry_state
      else
        maybe_connect_cellular "${now}" "${cellular_enabled}" || true
        "${CELLULARCTL}" refresh-state >/dev/null 2>&1 || true
        cellular_key="$(cellular_state_key)"
        log_cellular_state_if_changed "${cellular_key}" "${previous_cellular_key}"
        previous_cellular_key="${cellular_key}"
      fi
    fi

    # eth0 and eth1 are always enabled (permanent interfaces)
    read -r eth0_ready eth0_fail eth0_eligible eth0_last eth0_internet <<<"$(sample_uplink "eth0" "eth0" "true" "${require_check}" "${fail_threshold}" "${recover_threshold}")"
    read -r eth1_ready eth1_fail eth1_eligible eth1_last eth1_internet <<<"$(sample_uplink "eth1" "eth1" "true" "${require_check}" "${fail_threshold}" "${recover_threshold}")"
    read -r wifi_ready wifi_fail wifi_eligible wifi_last wifi_internet  <<<"$(sample_uplink "wifi_client" "wlan0" "${wifi_enabled}" "${require_check}" "${fail_threshold}" "${recover_threshold}")"
    read -r cellular_ready cellular_fail cellular_eligible cellular_last cellular_internet <<<"$(sample_uplink "cellular" "wwan0" "${cellular_enabled}" "${require_check}" "${fail_threshold}" "${recover_threshold}")"

    previous_active="$(monitor_value '.active_uplink // "none"')"
    active="${previous_active}"
    pending="$(monitor_value '.pending_candidate // ""')"
    previous_pending="${pending}"
    pending_since="$(monitor_value '.pending_since_epoch // 0')"
    switch_started_for_stats="${pending_since}"
    last_switch_timestamp="$(monitor_value '.last_switch_timestamp // ""')"

    # Find best candidate from priority list
    candidate="none"
    while read -r uplink; do
      case "${uplink}" in
        eth0)        [ "${eth0_eligible}" = "true" ] && { candidate="eth0"; break; } ;;
        eth1)        [ "${eth1_eligible}" = "true" ] && { candidate="eth1"; break; } ;;
        wifi_client) [ "${wifi_eligible}" = "true" ] && { candidate="wifi_client"; break; } ;;
        cellular)    [ "${cellular_eligible}" = "true" ] && { candidate="cellular"; break; } ;;
      esac
    done < <(jq -r '.network.uplink.uplink_priority[]' "${ACTIVE_SETTINGS}")

    # Drop active uplink if it failed
    case "${active}" in
      eth0)        [ "${eth0_fail}" -ge "${fail_threshold}" ] && { log "eth0 lost eligibility after ${eth0_fail} failed checks"; active="none"; } ;;
      eth1)        [ "${eth1_fail}" -ge "${fail_threshold}" ] && { log "eth1 lost eligibility after ${eth1_fail} failed checks"; active="none"; } ;;
      wifi_client) [ "${wifi_fail}" -ge "${fail_threshold}" ] && { log "wifi_client lost eligibility after ${wifi_fail} failed checks"; active="none"; } ;;
      cellular)    [ "${cellular_fail}" -ge "${fail_threshold}" ] && { log "cellular lost eligibility after ${cellular_fail} failed checks"; active="none"; } ;;
    esac

    # Candidate stabilisation / pending logic
    if [ "${candidate}" = "none" ]; then
      pending=""; pending_since=0
    elif [ "${active}" = "none" ]; then
      if [ "${pending}" != "${candidate}" ]; then
        pending="${candidate}"; pending_since="${now}"
        log "pending uplink candidate: ${candidate}"
      fi
      candidate_since=$((now - pending_since))
      if [ "${candidate_since}" -ge "${stable_seconds}" ]; then
        active="${candidate}"; pending=""; pending_since=0
      fi
    elif [ "${candidate}" = "${active}" ]; then
      pending=""; pending_since=0
    else
      if [ "${failback_enabled}" != "true" ] && [ "$(priority_for "${candidate}")" -lt "$(priority_for "${active}")" ]; then
        pending=""; pending_since=0
      else
        if [ "${pending}" != "${candidate}" ]; then
          pending="${candidate}"; pending_since="${now}"
          log "pending uplink switch to ${candidate}"
        fi
        candidate_since=$((now - pending_since))
        if [ "${candidate_since}" -ge "${stable_seconds}" ]; then
          active="${candidate}"; pending=""; pending_since=0
        fi
      fi
    fi

    apply_route_preference "${active}"

    if [ "${active}" != "${previous_active}" ]; then
      last_switch_timestamp="$(date --iso-8601=seconds)"
      log "active uplink switched: ${previous_active} -> ${active}"
      trigger_tailscale_recovery "active uplink switched from ${previous_active} to ${active}" "${now}"
      last_tailscale_health_epoch="${now}"
    fi
    [ "${candidate}" = "none" ] && [ "${previous_pending}" != "" ] && log "cleared pending uplink candidate"

    # Recovery: trigger apply if no uplink and wifi services are broken
    recovery_reason=""
    last_apply_at="$(last_apply_epoch)"
    if [ "${active}" = "none" ] && [ -z "${pending}" ] && [ $((now - last_apply_at)) -ge "${APPLY_GRACE_PERIOD}" ]; then
      if [ "${wifi_enabled}" = "true" ] && ! service_active "wpa_supplicant@wlan0.service"; then
        recovery_reason="wifi enabled but wpa_supplicant@wlan0 is inactive"
      fi
    fi
    if [ -n "${recovery_reason}" ]; then
      attempt_runtime_recovery "${recovery_reason}" "${now}"
    elif [ "$(recovery_value '.recovery_count // 0')" != "0" ]; then
      reset_recovery_state
    fi

    update_uplink_stats \
      "${now}" "${active}" "${previous_active}" "${switch_started_for_stats}" \
      "${eth0_eligible}" "${eth0_last}" "${eth0_internet}" \
      "${eth1_eligible}" "${eth1_last}" "${eth1_internet}" \
      "${wifi_enabled}" "${wifi_eligible}" "${wifi_last}" "${wifi_internet}" \
      "${cellular_enabled}" "${cellular_eligible}" "${cellular_last}" "${cellular_internet}"

    if [ $((now - last_tailscale_health_epoch)) -ge "${TAILSCALE_HEALTH_INTERVAL}" ]; then
      maybe_recover_tailscale_funnel "${active}" "${now}" "${last_tailscale_health_epoch}"
      last_tailscale_health_epoch="${now}"
    fi

    if [ $((now - last_summary_epoch)) -ge "${SUMMARY_INTERVAL}" ]; then
      cellular_summary="$(cellular_status_text | sed 's/^cellular state //')"
      log "summary active=${active} active_duration=$(stats_value '.active_duration_seconds // 0')s network_down=$(stats_value '.network.current_down_seconds // 0')s last_switch_duration=$(stats_value '.last_switch.duration_seconds // 0')s eth0(eligible=${eth0_eligible},internet=${eth0_internet},fail=${eth0_fail},down=$(stats_value '.interfaces.eth0.current_down_seconds // 0')s,addr=$(interface_addr eth0)) eth1(eligible=${eth1_eligible},internet=${eth1_internet},fail=${eth1_fail},down=$(stats_value '.interfaces.eth1.current_down_seconds // 0')s,addr=$(interface_addr eth1)) wifi(eligible=${wifi_eligible},internet=${wifi_internet},fail=${wifi_fail},down=$(stats_value '.interfaces.wifi_client.current_down_seconds // 0')s,addr=$(interface_addr wlan0)) cellular(eligible=${cellular_eligible},internet=${cellular_internet},fail=${cellular_fail},down=$(stats_value '.interfaces.cellular.current_down_seconds // 0')s,${cellular_summary})"
      last_summary_epoch="${now}"
    fi

    write_monitor_state \
      "${current_hash}" "${pending}" "${pending_since}" "${active}" "${last_switch_timestamp}" \
      "${eth0_ready}" "${eth0_fail}" "${eth0_eligible}" "${eth0_last}" "${eth0_internet}" \
      "${eth1_ready}" "${eth1_fail}" "${eth1_eligible}" "${eth1_last}" "${eth1_internet}" \
      "${wifi_ready}" "${wifi_fail}" "${wifi_eligible}" "${wifi_last}" "${wifi_internet}" \
      "${cellular_ready}" "${cellular_fail}" "${cellular_eligible}" "${cellular_last}" "${cellular_internet}"

    write_state_snapshot "${active}" "running" "${require_check}"
    sleep "${MONITOR_INTERVAL}"
  done
}

main_loop
