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
RECOVERY_STATE_FILE="${NETWORK_DIR}/recovery-state.json"
CELLULAR_STATE_FILE="${NETWORK_DIR}/cellular-state.json"
CELLULAR_RETRY_STATE_FILE="${NETWORK_DIR}/cellular-retry-state.json"
NETWORKCTL="${BASE_DIR}/scripts/gateway-networkctl"
CELLULARCTL="${BASE_DIR}/scripts/gateway-cellular-qmi"

MONITOR_INTERVAL=5
SUMMARY_INTERVAL=60
RECOVERY_COOLDOWN=30
APPLY_GRACE_PERIOD=20
CELLULAR_RETRY_MIN_INTERVAL=60
CELLULAR_RETRY_MAX_INTERVAL=300

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
recovery_value()  { jq -r "$1" "${RECOVERY_STATE_FILE}"; }
cellular_retry_value() { jq -r "$1" "${CELLULAR_RETRY_STATE_FILE}"; }

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
  local cellular_state cellular_retry_state cellular_for_state

  current_apply_result='{}'; [ -f "${RESULT_FILE}" ] && current_apply_result="$(cat "${RESULT_FILE}")"
  recovery_count="$(recovery_value '.recovery_count // 0')"
  recovery_reason="$(recovery_value '.last_recovery_reason // ""')"
  recovery_timestamp="$(recovery_value '.last_recovery_timestamp // ""')"

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
  "monitor_status": "${monitor_status}",
  "last_apply_status": $(json_escape "$(printf '%s' "${current_apply_result}" | jq -r '.status // "unknown"')"),
  "last_apply_timestamp": $(json_escape "$(printf '%s' "${current_apply_result}" | jq -r '.timestamp // ""')"),
  "last_monitor_timestamp": "$(date --iso-8601=seconds)",
  "recovery": {
    "count": ${recovery_count},
    "last_reason": $(json_escape "${recovery_reason}"),
    "last_timestamp": $(json_escape "${recovery_timestamp}")
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
  log "cellular retry attempt ${attempt_count}: requesting connect"
  if "${CELLULARCTL}" connect >"${output}" 2>&1; then
    write_cellular_retry_state "${now}" 0 0 "connected" ""
    log "cellular retry succeeded"
    return 0
  fi

  interval=$((CELLULAR_RETRY_MIN_INTERVAL * attempt_count))
  [ "${interval}" -gt "${CELLULAR_RETRY_MAX_INTERVAL}" ] && interval="${CELLULAR_RETRY_MAX_INTERVAL}"
  write_cellular_retry_state "${now}" $((now + interval)) "${attempt_count}" "failed" "$(tr '\r\n' '  ' < "${output}" | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-180)"
  log "cellular retry failed; next attempt in ${interval}s"
  return 1
}

main_loop() {
  local current_hash require_check stable_seconds failback_enabled
  local fail_threshold recover_threshold wifi_enabled cellular_enabled
  local active pending pending_since now previous_active last_switch_timestamp
  local candidate candidate_since
  local eth0_ready eth0_fail eth0_eligible eth0_last eth0_internet
  local eth1_ready eth1_fail eth1_eligible eth1_last eth1_internet
  local wifi_ready wifi_fail wifi_eligible wifi_last wifi_internet
  local cellular_ready cellular_fail cellular_eligible cellular_last cellular_internet
  local previous_pending recovery_reason last_apply_at last_summary_epoch
  local previous_cellular_key cellular_key cellular_summary

  last_summary_epoch=0
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

    if [ -x "${CELLULARCTL}" ]; then
      "${CELLULARCTL}" refresh-state >/dev/null 2>&1 || true
      cellular_key="$(cellular_state_key)"
      log_cellular_state_if_changed "${cellular_key}" "${previous_cellular_key}"
      previous_cellular_key="${cellular_key}"
      if [ "${cellular_enabled}" != "true" ] || [ "$(cellular_state_json | jq -r '.connected // false')" = "true" ]; then
        reset_cellular_retry_state
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
    last_switch_timestamp="$(monitor_value '.last_switch_timestamp // ""')"
    now="$(date +%s)"

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

    if [ "${candidate}" = "none" ] && [ "${cellular_enabled}" = "true" ] && [ -x "${CELLULARCTL}" ]; then
      maybe_connect_cellular "${now}" "${cellular_enabled}" || true
      cellular_key="$(cellular_state_key)"
      log_cellular_state_if_changed "${cellular_key}" "${previous_cellular_key}"
      previous_cellular_key="${cellular_key}"
      read -r cellular_ready cellular_fail cellular_eligible cellular_last cellular_internet <<<"$(sample_uplink "cellular" "wwan0" "${cellular_enabled}" "${require_check}" "${fail_threshold}" "${recover_threshold}")"
      [ "${cellular_eligible}" = "true" ] && candidate="cellular"
    fi

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
      log "active uplink switched: ${previous_active} → ${active}"
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

    if [ $((now - last_summary_epoch)) -ge "${SUMMARY_INTERVAL}" ]; then
      cellular_summary="$(cellular_status_text | sed 's/^cellular state //')"
      log "summary active=${active} eth0(eligible=${eth0_eligible},internet=${eth0_internet},fail=${eth0_fail},addr=$(interface_addr eth0)) eth1(eligible=${eth1_eligible},internet=${eth1_internet},fail=${eth1_fail},addr=$(interface_addr eth1)) wifi(eligible=${wifi_eligible},internet=${wifi_internet},fail=${wifi_fail},addr=$(interface_addr wlan0)) cellular(eligible=${cellular_eligible},internet=${cellular_internet},fail=${cellular_fail},${cellular_summary})"
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
