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
NETWORKCTL="${BASE_DIR}/scripts/gateway-networkctl"

MONITOR_INTERVAL=5
SUMMARY_INTERVAL=60
RECOVERY_COOLDOWN=30
APPLY_GRACE_PERIOD=20

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
    "wifi_client": { "ready_count": 0, "fail_count": 0, "eligible": false, "last_ready": false, "internet_ok": false }
  }
}
EOF
  fi
  if [ ! -f "${RECOVERY_STATE_FILE}" ]; then
    write_json_file "${RECOVERY_STATE_FILE}" <<'EOF'
{ "last_recovery_timestamp": "", "last_recovery_epoch": 0, "recovery_count": 0, "last_recovery_reason": "" }
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

write_monitor_state() {
  # args: hash pending pending_since active last_switch
  #       eth0: ready fail eligible last_ready internet
  #       eth1: ready fail eligible last_ready internet
  #       wifi: ready fail eligible last_ready internet
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
    "wifi_client": { "ready_count": ${16}, "fail_count": ${17}, "eligible": $(bool_json "${18}"), "last_ready": $(bool_json "${19}"), "internet_ok": $(bool_json "${20}") }
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
  local wifi_metric
  wifi_metric="$(jq -r '.network.wifi_client.route_metric' "${ACTIVE_SETTINGS}")"

  # Give active interface the lowest metric (10 = strongly preferred).
  # Non-active eth0/eth1 keep higher metrics for fallback.
  case "${active}" in
    eth0)
      set_iface_metric eth0  10
      set_iface_metric eth1  200
      set_iface_metric wlan0 $((wifi_metric + 1000))
      ;;
    eth1)
      set_iface_metric eth0  100
      set_iface_metric eth1  10
      set_iface_metric wlan0 $((wifi_metric + 1000))
      ;;
    wifi_client)
      set_iface_metric wlan0 10
      set_iface_metric eth0  100
      set_iface_metric eth1  200
      ;;
    *)
      set_iface_metric eth0  100
      set_iface_metric eth1  200
      set_iface_metric wlan0 "${wifi_metric}"
      ;;
  esac
}

write_state_snapshot() {
  local active="$1" monitor_status="$2" require_check="$3"
  local current_apply_result recovery_count recovery_reason recovery_timestamp
  local eth0_link eth0_up eth0_addr eth0_internet
  local eth1_link eth1_up eth1_addr eth1_internet
  local wifi_present wifi_up wifi_link wifi_addr wifi_internet wifi_ssid ap_clients

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
  }
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

main_loop() {
  local current_hash require_check stable_seconds failback_enabled
  local fail_threshold recover_threshold wifi_enabled
  local active pending pending_since now previous_active last_switch_timestamp
  local candidate candidate_since
  local eth0_ready eth0_fail eth0_eligible eth0_last eth0_internet
  local eth1_ready eth1_fail eth1_eligible eth1_last eth1_internet
  local wifi_ready wifi_fail wifi_eligible wifi_last wifi_internet
  local previous_pending recovery_reason last_apply_at last_summary_epoch

  last_summary_epoch=0

  while true; do
    ensure_runtime_files

    if [ ! -f "${ACTIVE_SETTINGS}" ]; then
      "${NETWORKCTL}" apply >/dev/null 2>&1 || true
      sleep "${MONITOR_INTERVAL}"
      continue
    fi

    current_hash="$(sha256sum "${ACTIVE_SETTINGS}" | awk '{print $1}')"
    LAST_HASH="$(monitor_value '.last_config_hash // ""')"
    if [ "${current_hash}" != "${LAST_HASH}" ]; then
      [ -n "${LAST_HASH}" ] && { log "settings changed, triggering apply"; "${NETWORKCTL}" apply >/dev/null 2>&1 || true; }
      LAST_HASH="${current_hash}"
    fi

    load_connectivity_targets

    require_check="$(jq -r '.network.uplink.require_connectivity_check' "${ACTIVE_SETTINGS}")"
    stable_seconds="$(jq -r '.network.uplink.stable_seconds_before_switch' "${ACTIVE_SETTINGS}")"
    failback_enabled="$(jq -r '.network.uplink.failback_enabled' "${ACTIVE_SETTINGS}")"
    fail_threshold="$(jq -r '.network.uplink.fail_count_threshold // 1' "${ACTIVE_SETTINGS}")"
    recover_threshold="$(jq -r '.network.uplink.recover_count_threshold // 1' "${ACTIVE_SETTINGS}")"
    wifi_enabled="$(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}")"

    # eth0 and eth1 are always enabled (permanent interfaces)
    read -r eth0_ready eth0_fail eth0_eligible eth0_last eth0_internet <<<"$(sample_uplink "eth0" "eth0" "true" "${require_check}" "${fail_threshold}" "${recover_threshold}")"
    read -r eth1_ready eth1_fail eth1_eligible eth1_last eth1_internet <<<"$(sample_uplink "eth1" "eth1" "true" "${require_check}" "${fail_threshold}" "${recover_threshold}")"
    read -r wifi_ready wifi_fail wifi_eligible wifi_last wifi_internet  <<<"$(sample_uplink "wifi_client" "wlan0" "${wifi_enabled}" "${require_check}" "${fail_threshold}" "${recover_threshold}")"

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
      esac
    done < <(jq -r '.network.uplink.uplink_priority[]' "${ACTIVE_SETTINGS}")

    # Drop active uplink if it failed
    case "${active}" in
      eth0)        [ "${eth0_fail}" -ge "${fail_threshold}" ] && { log "eth0 lost eligibility after ${eth0_fail} failed checks"; active="none"; } ;;
      eth1)        [ "${eth1_fail}" -ge "${fail_threshold}" ] && { log "eth1 lost eligibility after ${eth1_fail} failed checks"; active="none"; } ;;
      wifi_client) [ "${wifi_fail}" -ge "${fail_threshold}" ] && { log "wifi_client lost eligibility after ${wifi_fail} failed checks"; active="none"; } ;;
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
      log "summary active=${active} eth0(eligible=${eth0_eligible},internet=${eth0_internet},fail=${eth0_fail}) eth1(eligible=${eth1_eligible},internet=${eth1_internet},fail=${eth1_fail}) wifi(eligible=${wifi_eligible},internet=${wifi_internet},fail=${wifi_fail})"
      last_summary_epoch="${now}"
    fi

    write_monitor_state \
      "${current_hash}" "${pending}" "${pending_since}" "${active}" "${last_switch_timestamp}" \
      "${eth0_ready}" "${eth0_fail}" "${eth0_eligible}" "${eth0_last}" "${eth0_internet}" \
      "${eth1_ready}" "${eth1_fail}" "${eth1_eligible}" "${eth1_last}" "${eth1_internet}" \
      "${wifi_ready}" "${wifi_fail}" "${wifi_eligible}" "${wifi_last}" "${wifi_internet}"

    write_state_snapshot "${active}" "running" "${require_check}"
    sleep "${MONITOR_INTERVAL}"
  done
}

main_loop
