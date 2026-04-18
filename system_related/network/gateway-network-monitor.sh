#!/bin/bash
set -euo pipefail

LOG_TAG="gateway-network-monitor"
BASE_DIR="/opt/gateway"
STORAGE_DIR="${BASE_DIR}/software_storage/AES"
SYSTEM_RELATED_DIR="${BASE_DIR}/system_related"
NETWORK_DIR="${SYSTEM_RELATED_DIR}/network"
STATE_DIR="${NETWORK_DIR}/state"
ACTIVE_SETTINGS="${STORAGE_DIR}/network_settings.json"
STATE_FILE="${STATE_DIR}/network_state.json"
RESULT_FILE="${STATE_DIR}/network_apply_result.json"
MONITOR_STATE_FILE="${STATE_DIR}/network_monitor_state.json"
NETWORKCTL="${BASE_DIR}/scripts/gateway-networkctl"

MONITOR_INTERVAL=5
SUMMARY_INTERVAL=60

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
  install -d -m 0755 "${SYSTEM_RELATED_DIR}" "${NETWORK_DIR}" "${STATE_DIR}" "${STORAGE_DIR}"
  if [ ! -f "${MONITOR_STATE_FILE}" ]; then
    write_json_file "${MONITOR_STATE_FILE}" <<'EOF'
{
  "last_config_hash": "",
  "pending_candidate": "",
  "pending_since_epoch": 0,
  "active_uplink": "none",
  "last_switch_timestamp": "",
  "uplinks": {
    "eth0": {
      "ready_count": 0,
      "fail_count": 0,
      "eligible": false,
      "last_ready": false,
      "internet_ok": false
    },
    "wifi_client": {
      "ready_count": 0,
      "fail_count": 0,
      "eligible": false,
      "last_ready": false,
      "internet_ok": false
    }
  }
}
EOF
  fi
}

bool_json() {
  [ "$1" = "true" ] && printf true || printf false
}

interface_up() {
  local iface="$1"
  ip -j link show "${iface}" 2>/dev/null | jq -r 'if length == 0 then false else (.[0].flags | index("UP") != null) end'
}

interface_link() {
  local iface="$1"
  ip -j link show "${iface}" 2>/dev/null | jq -r 'if length == 0 then false else .[0].operstate == "UP" end'
}

interface_addr() {
  local iface="$1"
  ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | head -n1
}

load_connectivity_targets() {
  mapfile -t CONNECTIVITY_TARGETS < <(jq -r '.network.policy.connectivity_targets[]? // empty' "${ACTIVE_SETTINGS}")
  if [ "${#CONNECTIVITY_TARGETS[@]}" -eq 0 ]; then
    CONNECTIVITY_TARGETS=("1.1.1.1" "8.8.8.8")
  fi
}

internet_ok() {
  local iface="$1"
  local target

  for target in "${CONNECTIVITY_TARGETS[@]}"; do
    if ping -I "${iface}" -c 1 -W 2 "${target}" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

priority_for() {
  local target="$1"
  jq -r --arg target "${target}" '
    .network.policy.uplink_priority
    | to_entries
    | map(select(.value == $target))
    | if length == 0 then 999 else (.[0].key + 1) end
  ' "${ACTIVE_SETTINGS}"
}

effective_ready() {
  local iface="$1"
  local require_check="$2"
  local link address

  link="$(interface_link "${iface}")"
  address="$(interface_addr "${iface}")"
  [ "${link}" = "true" ] || return 1
  [ -n "${address}" ] || return 1

  if [ "${require_check}" = "true" ]; then
    internet_ok "${iface}"
  else
    return 0
  fi
}

monitor_value() {
  local expr="$1"
  jq -r "${expr}" "${MONITOR_STATE_FILE}"
}

write_monitor_state() {
  local current_hash="$1"
  local pending_candidate="$2"
  local pending_since="$3"
  local active_uplink="$4"
  local last_switch_timestamp="$5"
  local eth_ready_count="$6"
  local eth_fail_count="$7"
  local eth_eligible="$8"
  local eth_last_ready="$9"
  local eth_internet_ok="${10}"
  local wifi_ready_count="${11}"
  local wifi_fail_count="${12}"
  local wifi_eligible="${13}"
  local wifi_last_ready="${14}"
  local wifi_internet_ok="${15}"

  write_json_file "${MONITOR_STATE_FILE}" <<EOF
{
  "last_config_hash": "${current_hash}",
  "pending_candidate": "${pending_candidate}",
  "pending_since_epoch": ${pending_since},
  "active_uplink": "${active_uplink}",
  "last_switch_timestamp": "${last_switch_timestamp}",
  "uplinks": {
    "eth0": {
      "ready_count": ${eth_ready_count},
      "fail_count": ${eth_fail_count},
      "eligible": $(bool_json "${eth_eligible}"),
      "last_ready": $(bool_json "${eth_last_ready}"),
      "internet_ok": $(bool_json "${eth_internet_ok}")
    },
    "wifi_client": {
      "ready_count": ${wifi_ready_count},
      "fail_count": ${wifi_fail_count},
      "eligible": $(bool_json "${wifi_eligible}"),
      "last_ready": $(bool_json "${wifi_last_ready}"),
      "internet_ok": $(bool_json "${wifi_internet_ok}")
    }
  }
}
EOF
}

sample_uplink() {
  local key="$1"
  local iface="$2"
  local enabled="$3"
  local require_check="$4"
  local fail_threshold="$5"
  local recover_threshold="$6"

  local ready_count fail_count current_ready eligible internet_state

  ready_count="$(monitor_value ".uplinks[\"${key}\"].ready_count // 0")"
  fail_count="$(monitor_value ".uplinks[\"${key}\"].fail_count // 0")"

  current_ready="false"
  internet_state="false"

  if [ "${enabled}" = "true" ] && effective_ready "${iface}" "${require_check}"; then
    current_ready="true"
    ready_count=$((ready_count + 1))
    fail_count=0
    if [ "${require_check}" = "true" ]; then
      internet_state="true"
    fi
  else
    fail_count=$((fail_count + 1))
    ready_count=0
  fi

  if [ "${ready_count}" -ge "${recover_threshold}" ]; then
    eligible="true"
  else
    eligible="false"
  fi

  printf '%s %s %s %s %s\n' "${ready_count}" "${fail_count}" "${eligible}" "${current_ready}" "${internet_state}"
}

apply_route_preference() {
  local active="$1"
  local eth_metric wifi_metric

  eth_metric="$(jq -r '.network.ethernet.route_metric' "${ACTIVE_SETTINGS}")"
  wifi_metric="$(jq -r '.network.wifi_client.route_metric' "${ACTIVE_SETTINGS}")"

  case "${active}" in
    eth0)
      set_iface_metric "eth0" 10
      set_iface_metric "wlan0" $((wifi_metric + 1000))
      ;;
    wifi_client)
      set_iface_metric "wlan0" 10
      set_iface_metric "eth0" $((eth_metric + 1000))
      ;;
    *)
      set_iface_metric "eth0" "${eth_metric}"
      set_iface_metric "wlan0" "${wifi_metric}"
      ;;
  esac
}

set_iface_metric() {
  local iface="$1"
  local new_metric="$2"
  local routes gateway

  routes="$(ip -4 route show default dev "${iface}" || true)"
  [ -n "${routes}" ] || return 0

  gateway="$(printf '%s\n' "${routes}" | awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}')"

  while ip -4 route del default dev "${iface}" >/dev/null 2>&1; do
    :
  done

  if [ -n "${gateway}" ]; then
    ip -4 route add default via "${gateway}" dev "${iface}" metric "${new_metric}" >/dev/null 2>&1 || true
  else
    ip -4 route add default dev "${iface}" metric "${new_metric}" >/dev/null 2>&1 || true
  fi
}

write_state_snapshot() {
  local active="$1"
  local monitor_status="$2"
  local require_check="$3"
  local current_apply_result
  local eth_link eth_up eth_addr eth_internet
  local wifi_present wifi_up wifi_link wifi_addr wifi_internet wifi_ssid ap_clients

  current_apply_result='{}'
  [ -f "${RESULT_FILE}" ] && current_apply_result="$(cat "${RESULT_FILE}")"

  eth_link="$(interface_link "eth0")"
  eth_up="$(interface_up "eth0")"
  eth_addr="$(interface_addr "eth0")"
  eth_internet="$(monitor_value '.uplinks["eth0"].internet_ok // false')"

  if ip link show wlan0 >/dev/null 2>&1; then
    wifi_present="true"
    wifi_up="$(interface_up "wlan0")"
    wifi_link="$(interface_link "wlan0")"
    wifi_addr="$(interface_addr "wlan0")"
    wifi_ssid="$(iw dev wlan0 link 2>/dev/null | awk -F': ' '/SSID:/ {print $2; exit}')"
    ap_clients="$(iw dev wlan0 station dump 2>/dev/null | grep -c '^Station' || true)"
    wifi_internet="$(monitor_value '.uplinks["wifi_client"].internet_ok // false')"
  else
    wifi_present="false"
    wifi_up="false"
    wifi_link="false"
    wifi_addr=""
    wifi_ssid=""
    ap_clients=0
    wifi_internet="false"
  fi

  write_json_file "${STATE_FILE}" <<EOF
{
  "active_uplink": "${active}",
  "monitor_status": "${monitor_status}",
  "last_apply_status": $(json_escape "$(printf '%s' "${current_apply_result}" | jq -r '.status // "unknown"')"),
  "last_apply_timestamp": $(json_escape "$(printf '%s' "${current_apply_result}" | jq -r '.timestamp // ""')"),
  "last_monitor_timestamp": "$(date --iso-8601=seconds)",
  "ethernet": {
    "interface": "eth0",
    "enabled": $(jq -r '.network.ethernet.enabled' "${ACTIVE_SETTINGS}"),
    "link_up": $(bool_json "${eth_link}"),
    "interface_up": $(bool_json "${eth_up}"),
    "address": $(json_escape "${eth_addr}"),
    "internet_ok": $(bool_json "${eth_internet}")
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

main_loop() {
  local current_hash require_check stable_seconds failback_enabled
  local fail_threshold recover_threshold
  local ethernet_enabled wifi_enabled
  local active pending pending_since now previous_active last_switch_timestamp
  local candidate candidate_since
  local eth_ready_count eth_fail_count eth_eligible eth_last_ready eth_internet
  local wifi_ready_count wifi_fail_count wifi_eligible wifi_last_ready wifi_internet
  local previous_pending previous_candidate last_summary_epoch

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
      if [ -n "${LAST_HASH}" ]; then
        log "settings changed, triggering network apply"
        "${NETWORKCTL}" apply >/dev/null 2>&1 || true
      fi
      LAST_HASH="${current_hash}"
    fi

    load_connectivity_targets

    require_check="$(jq -r '.network.policy.require_connectivity_check' "${ACTIVE_SETTINGS}")"
    stable_seconds="$(jq -r '.network.policy.stable_seconds_before_switch' "${ACTIVE_SETTINGS}")"
    failback_enabled="$(jq -r '.network.policy.failback_enabled' "${ACTIVE_SETTINGS}")"
    fail_threshold="$(jq -r '.network.policy.fail_count_threshold // 1' "${ACTIVE_SETTINGS}")"
    recover_threshold="$(jq -r '.network.policy.recover_count_threshold // 1' "${ACTIVE_SETTINGS}")"
    ethernet_enabled="$(jq -r '.network.ethernet.enabled' "${ACTIVE_SETTINGS}")"
    wifi_enabled="$(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}")"

    read -r eth_ready_count eth_fail_count eth_eligible eth_last_ready eth_internet <<<"$(sample_uplink "eth0" "eth0" "${ethernet_enabled}" "${require_check}" "${fail_threshold}" "${recover_threshold}")"
    read -r wifi_ready_count wifi_fail_count wifi_eligible wifi_last_ready wifi_internet <<<"$(sample_uplink "wifi_client" "wlan0" "${wifi_enabled}" "${require_check}" "${fail_threshold}" "${recover_threshold}")"

    previous_active="$(monitor_value '.active_uplink // "none"')"
    active="${previous_active}"
    pending="$(monitor_value '.pending_candidate // ""')"
    previous_pending="${pending}"
    pending_since="$(monitor_value '.pending_since_epoch // 0')"
    last_switch_timestamp="$(monitor_value '.last_switch_timestamp // ""')"
    now="$(date +%s)"

    candidate="none"
    while read -r uplink; do
      case "${uplink}" in
        eth0)
          if [ "${eth_eligible}" = "true" ]; then
            candidate="eth0"
            break
          fi
          ;;
        wifi_client)
          if [ "${wifi_eligible}" = "true" ]; then
            candidate="wifi_client"
            break
          fi
          ;;
      esac
    done < <(jq -r '.network.policy.uplink_priority[]' "${ACTIVE_SETTINGS}")

    case "${active}" in
      eth0)
        if [ "${eth_fail_count}" -ge "${fail_threshold}" ]; then
          log "eth0 lost eligibility after ${eth_fail_count} failed checks"
          active="none"
        fi
        ;;
      wifi_client)
        if [ "${wifi_fail_count}" -ge "${fail_threshold}" ]; then
          log "wifi_client lost eligibility after ${wifi_fail_count} failed checks"
          active="none"
        fi
        ;;
    esac

    if [ "${candidate}" = "none" ]; then
      pending=""
      pending_since=0
    elif [ "${active}" = "none" ]; then
      if [ "${pending}" != "${candidate}" ]; then
        pending="${candidate}"
        pending_since="${now}"
        log "pending uplink candidate ${candidate}"
      fi
      candidate_since=$((now - pending_since))
      if [ "${candidate_since}" -ge "${stable_seconds}" ]; then
        active="${candidate}"
        pending=""
        pending_since=0
      fi
    elif [ "${candidate}" = "${active}" ]; then
      pending=""
      pending_since=0
    else
      if [ "${failback_enabled}" != "true" ] && [ "$(priority_for "${candidate}")" -lt "$(priority_for "${active}")" ]; then
        pending=""
        pending_since=0
      else
        if [ "${pending}" != "${candidate}" ]; then
          pending="${candidate}"
          pending_since="${now}"
          log "pending uplink switch to ${candidate}"
        fi
        candidate_since=$((now - pending_since))
        if [ "${candidate_since}" -ge "${stable_seconds}" ]; then
          active="${candidate}"
          pending=""
          pending_since=0
        fi
      fi
    fi

    apply_route_preference "${active}"

    if [ "${active}" != "${previous_active}" ]; then
      last_switch_timestamp="$(date --iso-8601=seconds)"
      log "active uplink switched to ${active}"
    fi

    if [ "${candidate}" = "none" ] && [ "${previous_pending}" != "" ]; then
      log "cleared pending uplink candidate"
    fi

    if [ $((now - last_summary_epoch)) -ge "${SUMMARY_INTERVAL}" ]; then
      log "summary active=${active} eth0(eligible=${eth_eligible},internet=${eth_internet},fail=${eth_fail_count}) wifi_client(eligible=${wifi_eligible},internet=${wifi_internet},fail=${wifi_fail_count})"
      last_summary_epoch="${now}"
    fi

    write_monitor_state \
      "${current_hash}" \
      "${pending}" \
      "${pending_since}" \
      "${active}" \
      "${last_switch_timestamp}" \
      "${eth_ready_count}" \
      "${eth_fail_count}" \
      "${eth_eligible}" \
      "${eth_last_ready}" \
      "${eth_internet}" \
      "${wifi_ready_count}" \
      "${wifi_fail_count}" \
      "${wifi_eligible}" \
      "${wifi_last_ready}" \
      "${wifi_internet}"

    write_state_snapshot "${active}" "running" "${require_check}"
    sleep "${MONITOR_INTERVAL}"
  done
}

main_loop
