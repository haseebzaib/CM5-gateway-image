#!/bin/bash
# gateway-network-apply.sh
#
# PURPOSE: Uplink connectivity management ONLY.
#   - Manages Wi-Fi client / AP configuration
#   - Manages NAT for AP mode
#   - Reports uplink state
#   - Does NOT manage eth0 or eth1 — those are always up via permanent
#     systemd-networkd units (10-gateway-eth0.network, 11-gateway-eth1.network)
#     installed by the image layer. Only this script touches wlan0.
#
set -euo pipefail

LOG_TAG="gateway-network-apply"
BASE_DIR="/opt/gateway"
NETWORK_DIR="${BASE_DIR}/network"
GENERATED_DIR="${NETWORK_DIR}/generated"
STORAGE_DIR="${BASE_DIR}/software_storage/AES"
DEFAULT_SETTINGS="${NETWORK_DIR}/defaults.json"
ACTIVE_SETTINGS="${STORAGE_DIR}/network_settings.json"
LAST_GOOD_SETTINGS="${STORAGE_DIR}/network_settings.last_good.json"
STATE_FILE="${NETWORK_DIR}/state.json"
RESULT_FILE="${NETWORK_DIR}/apply-result.json"
CELLULAR_STATE_FILE="${NETWORK_DIR}/cellular-state.json"
CELLULARCTL="${BASE_DIR}/scripts/gateway-cellular-qmi"

NETWORKD_DIR="/etc/systemd/network"
WPA_DIR="/etc/wpa_supplicant"
WPA_FILE="${WPA_DIR}/wpa_supplicant-wlan0.conf"
HOSTAPD_DIR="/etc/hostapd"
HOSTAPD_FILE="${HOSTAPD_DIR}/hostapd.conf"
HOSTAPD_DEFAULT="/etc/default/hostapd"
DNSMASQ_DIR="/etc/dnsmasq.d"
DNSMASQ_FILE="${DNSMASQ_DIR}/gateway-ap.conf"
SYSCTL_FILE="/etc/sysctl.d/99-gateway-ip-forward.conf"

CURRENT_SCOPE=""
CURRENT_CODE=""
CURRENT_MESSAGE=""
USED_DEFAULTS="false"
ACTIVE_UPLINK="none"
WARNING_MESSAGE=""

log() {
  logger -t "${LOG_TAG}" "$*"
  printf '%s\n' "$*"
}

ensure_layout() {
  install -d -m 0755 "${BASE_DIR}" "${NETWORK_DIR}" "${GENERATED_DIR}" "${STORAGE_DIR}"
  install -d -m 0755 "${GENERATED_DIR}/systemd-networkd" "${GENERATED_DIR}/wpa_supplicant" "${GENERATED_DIR}/hostapd" "${GENERATED_DIR}/dnsmasq"
  install -d -m 0755 "${NETWORKD_DIR}" "${WPA_DIR}" "${HOSTAPD_DIR}" "${DNSMASQ_DIR}"
}

write_json_file() {
  local target="$1"
  local tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  cat > "${tmp}"
  mv "${tmp}" "${target}"
}

json_escape() {
  printf '%s' "$1" | jq -Rsa .
}

write_result() {
  local ok="$1" status="$2" used_defaults="$3" active_uplink="$4" errors_json="$5" warnings_json="$6"
  write_json_file "${RESULT_FILE}" <<EOF
{
  "ok": ${ok},
  "status": "${status}",
  "timestamp": "$(date --iso-8601=seconds)",
  "used_defaults": ${used_defaults},
  "active_uplink": "${active_uplink}",
  "errors": ${errors_json},
  "warnings": ${warnings_json}
}
EOF
}

on_error() {
  local line="$1"
  trap - ERR
  write_result false "apply_error" "${USED_DEFAULTS}" "${ACTIVE_UPLINK}" \
    "[{\"scope\":$(json_escape "${CURRENT_SCOPE:-network}"),\"code\":$(json_escape "${CURRENT_CODE:-unexpected_error}"),\"message\":$(json_escape "${CURRENT_MESSAGE:-Unexpected failure.}")}]" \
    "$( [ -n "${WARNING_MESSAGE}" ] && printf '[{"scope":"network","code":"warning","message":%s}]' "$(json_escape "${WARNING_MESSAGE}")" || printf '[]' )"
  log "apply_error at line ${line}: ${CURRENT_SCOPE:-network}/${CURRENT_CODE:-unexpected_error}"
  exit 1
}

write_state() {
  local status="$1"
  local eth0_addr eth1_addr eth0_link eth1_link wifi_present wifi_up ap_clients connected_ssid
  local cellular_state

  eth0_addr="$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | head -n1)"
  eth1_addr="$(ip -4 -o addr show dev eth1 2>/dev/null | awk '{print $4}' | head -n1)"
  eth0_link="$(ip -j link show eth0 2>/dev/null | jq -r 'if length == 0 then false else .[0].operstate == "UP" end')"
  eth1_link="$(ip -j link show eth1 2>/dev/null | jq -r 'if length == 0 then false else .[0].operstate == "UP" end')"
  wifi_present="$(ip link show wlan0 >/dev/null 2>&1 && printf true || printf false)"
  wifi_up="$(ip -j link show wlan0 2>/dev/null | jq -r 'if length == 0 then false else (.[0].flags | index("UP") != null) end')"
  ap_clients="$(iw dev wlan0 station dump 2>/dev/null | grep -c '^Station' || true)"
  connected_ssid="$(iw dev wlan0 link 2>/dev/null | awk -F': ' '/SSID:/ {print $2; exit}')"
  connected_ssid="${connected_ssid:-}"
  cellular_state='{"enabled":false,"present":false,"backend":"qmi","interface":"wwan0","control_device":"/dev/cdc-wdm0","modem_manufacturer":"","modem_model":"","modem_revision":"","sim_status":"unknown","operator":"","signal_dbm":0,"signal_percent":0,"registration_state":"unknown","registered":false,"roaming":false,"access_technology":"","connected":false,"address":"","gateway":"","dns":[],"internet_ok":false,"rx_bytes":0,"tx_bytes":0,"session_rx_bytes":0,"session_tx_bytes":0,"last_connect_timestamp":"","last_disconnect_timestamp":"","last_error":""}'
  [ -f "${CELLULAR_STATE_FILE}" ] && cellular_state="$(cat "${CELLULAR_STATE_FILE}")"

  write_json_file "${STATE_FILE}" <<EOF
{
  "active_uplink": "${ACTIVE_UPLINK}",
  "last_apply_status": "${status}",
  "last_apply_timestamp": "$(date --iso-8601=seconds)",
  "eth0": {
    "link_up": ${eth0_link:-false},
    "address": "${eth0_addr:-}"
  },
  "eth1": {
    "link_up": ${eth1_link:-false},
    "address": "${eth1_addr:-}"
  },
  "wifi_client": {
    "interface": "wlan0",
    "present": ${wifi_present:-false},
    "enabled": $(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}"),
    "interface_up": ${wifi_up:-false},
    "connected_ssid": $(json_escape "${connected_ssid}")
  },
  "wifi_ap": {
    "interface": "wlan0",
    "enabled": $(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}"),
    "clients": ${ap_clients:-0}
  },
  "cellular": $(printf '%s' "${cellular_state}" | jq -c '{
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
    last_error: (.last_error // "")
  }')
}
EOF
}

fail() {
  local status="$1" scope="$2" code="$3" message="$4"
  trap - ERR
  write_result false "${status}" "${USED_DEFAULTS}" "${ACTIVE_UPLINK}" \
    "[{\"scope\":$(json_escape "${scope}"),\"code\":$(json_escape "${code}"),\"message\":$(json_escape "${message}")}]" \
    "$( [ -n "${WARNING_MESSAGE}" ] && printf '[{"scope":"network","code":"warning","message":%s}]' "$(json_escape "${WARNING_MESSAGE}")" || printf '[]' )"
  log "${status}: ${scope}/${code}: ${message}"
  exit 1
}

restore_defaults() {
  cp "${DEFAULT_SETTINGS}" "${ACTIVE_SETTINGS}"
}

backup_invalid() {
  local ts
  ts="$(date +%s)"
  cp "${ACTIVE_SETTINGS}" "${STORAGE_DIR}/network_settings.invalid.${ts}.json" || true
}

validate_config() {
  jq -e '
    .version == 2 and
    (.network.wifi_client.interface == "wlan0") and
    (.network.wifi_ap.interface == "wlan0") and
    ((.network.cellular.enabled // false) | type == "boolean") and
    (.network.uplink.uplink_priority | type == "array") and
    (.network.wifi_client.route_metric | type == "number") and
    (.network.wifi_client.enabled | type == "boolean") and
    (.network.wifi_ap.enabled | type == "boolean")
  ' "${ACTIVE_SETTINGS}" >/dev/null || return 1

  if [ "$(jq -r '.network.wifi_client.enabled and .network.wifi_ap.enabled' "${ACTIVE_SETTINGS}")" = "true" ]; then
    CURRENT_SCOPE="wifi"
    CURRENT_CODE="client_ap_conflict"
    CURRENT_MESSAGE="Wi-Fi client and AP mode cannot both be enabled on wlan0."
    return 1
  fi

  if [ "$(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}")" = "true" ]; then
    if [ -z "$(jq -r '.network.wifi_client.ssid' "${ACTIVE_SETTINGS}")" ]; then
      CURRENT_SCOPE="wifi_client"; CURRENT_CODE="ssid_required"
      CURRENT_MESSAGE="Wi-Fi client is enabled but SSID is empty."
      return 1
    fi
    if [ "$(jq -r '.network.wifi_client.security' "${ACTIVE_SETTINGS}")" != "open" ] && \
       [ -z "$(jq -r '.network.wifi_client.passphrase' "${ACTIVE_SETTINGS}")" ]; then
      CURRENT_SCOPE="wifi_client"; CURRENT_CODE="passphrase_required"
      CURRENT_MESSAGE="Wi-Fi client security requires a passphrase."
      return 1
    fi
  fi

  if [ "$(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}")" = "true" ]; then
    if [ -z "$(jq -r '.network.wifi_ap.ssid' "${ACTIVE_SETTINGS}")" ]; then
      CURRENT_SCOPE="wifi_ap"; CURRENT_CODE="ssid_required"
      CURRENT_MESSAGE="Wi-Fi AP is enabled but SSID is empty."
      return 1
    fi
    if [ "$(jq -r '.network.wifi_ap.security' "${ACTIVE_SETTINGS}")" != "open" ] && \
       [ -z "$(jq -r '.network.wifi_ap.passphrase' "${ACTIVE_SETTINGS}")" ]; then
      CURRENT_SCOPE="wifi_ap"; CURRENT_CODE="passphrase_required"
      CURRENT_MESSAGE="Wi-Fi AP security requires a passphrase."
      return 1
    fi
    if [ "$(jq -r '.network.wifi_ap.shared_uplink_mode' "${ACTIVE_SETTINGS}")" = "wifi_client" ]; then
      CURRENT_SCOPE="wifi_ap"; CURRENT_CODE="shared_uplink_unsupported"
      CURRENT_MESSAGE="Wi-Fi AP cannot use Wi-Fi client as shared uplink on the same radio."
      return 1
    fi
  fi

  if [ "$(jq -r '.network.cellular.enabled // false' "${ACTIVE_SETTINGS}")" = "true" ]; then
    if [ -z "$(jq -r '.network.cellular.apn // ""' "${ACTIVE_SETTINGS}")" ]; then
      CURRENT_SCOPE="cellular"; CURRENT_CODE="apn_required"
      CURRENT_MESSAGE="Cellular fallback is enabled but APN is empty."
      return 1
    fi
    if [ -n "$(jq -r '.network.cellular.pin // ""' "${ACTIVE_SETTINGS}")" ] && \
       ! jq -e '(.network.cellular.pin // "") | test("^[0-9]{4,8}$")' "${ACTIVE_SETTINGS}" >/dev/null; then
      CURRENT_SCOPE="cellular"; CURRENT_CODE="invalid_pin"
      CURRENT_MESSAGE="Cellular SIM PIN must be 4 to 8 digits."
      return 1
    fi
  fi
}

write_networkd_dhcp() {
  local iface="$1" metric="$2" mtu="$3" target="$4"
  cat > "${target}" <<EOF
[Match]
Name=${iface}

[Link]
MTUBytes=${mtu}

[Network]
DHCP=yes

[DHCPv4]
RouteMetric=${metric}
UseDNS=yes
EOF
}

write_networkd_static() {
  local iface="$1" metric="$2" mtu="$3" address="$4" gateway="$5" dns_list="$6" configure_without_carrier="$7" target="$8"
  cat > "${target}" <<EOF
[Match]
Name=${iface}

[Link]
MTUBytes=${mtu}

[Network]
Address=${address}
ConfigureWithoutCarrier=${configure_without_carrier}
EOF
  if [ -n "${dns_list}" ]; then
    printf 'DNS=%s\n' "${dns_list}" >> "${target}"
  fi
  if [ -n "${gateway}" ]; then
    cat >> "${target}" <<EOF

[Route]
Gateway=${gateway}
Metric=${metric}
EOF
  fi
}

# Install only wlan0 network files. eth0/eth1 are managed by permanent image units.
install_networkd_wlan_files() {
  rm -f "${NETWORKD_DIR}/20-gateway-wlan0.network" "${NETWORKD_DIR}/21-gateway-wlan0-ap.network"
  [ -f "${GENERATED_DIR}/systemd-networkd/20-gateway-wlan0.network" ] && \
    install -D -m 0644 "${GENERATED_DIR}/systemd-networkd/20-gateway-wlan0.network" "${NETWORKD_DIR}/20-gateway-wlan0.network"
  [ -f "${GENERATED_DIR}/systemd-networkd/21-gateway-wlan0-ap.network" ] && \
    install -D -m 0644 "${GENERATED_DIR}/systemd-networkd/21-gateway-wlan0-ap.network" "${NETWORKD_DIR}/21-gateway-wlan0-ap.network"
  return 0
}

generate_wifi_client_files() {
  local enabled dhcp metric security passphrase ssid hidden country gateway address dns_list

  enabled="$(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}")"
  [ "${enabled}" = "true" ] || return 0

  security="$(jq -r '.network.wifi_client.security' "${ACTIVE_SETTINGS}")"
  passphrase="$(jq -r '.network.wifi_client.passphrase' "${ACTIVE_SETTINGS}")"
  ssid="$(jq -r '.network.wifi_client.ssid' "${ACTIVE_SETTINGS}")"
  hidden="$(jq -r '.network.wifi_client.hidden_ssid' "${ACTIVE_SETTINGS}")"
  country="$(jq -r '.network.wifi_client.country_code' "${ACTIVE_SETTINGS}")"

  cat > "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" <<EOF
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=0
country=${country}

network={
    ssid=$(json_escape "${ssid}")
EOF

  case "${security}" in
    open)      printf '    key_mgmt=NONE\n' >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" ;;
    wpa3-sae)  printf '    key_mgmt=SAE\n    sae_password=%s\n' "$(json_escape "${passphrase}")" >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" ;;
    wpa2-wpa3) printf '    key_mgmt=WPA-PSK SAE\n    psk=%s\n' "$(json_escape "${passphrase}")" >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" ;;
    *)         printf '    key_mgmt=WPA-PSK\n    psk=%s\n' "$(json_escape "${passphrase}")" >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" ;;
  esac

  [ "${hidden}" = "true" ] && printf '    scan_ssid=1\n' >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf"

  printf '}\n' >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf"

  dhcp="$(jq -r '.network.wifi_client.dhcp' "${ACTIVE_SETTINGS}")"
  metric="$(jq -r '.network.wifi_client.route_metric' "${ACTIVE_SETTINGS}")"

  if [ "${dhcp}" = "true" ]; then
    write_networkd_dhcp "wlan0" "${metric}" "1500" "${GENERATED_DIR}/systemd-networkd/20-gateway-wlan0.network"
  else
    address="$(jq -r '.network.wifi_client.static_address' "${ACTIVE_SETTINGS}")"
    gateway="$(jq -r '.network.wifi_client.static_gateway' "${ACTIVE_SETTINGS}")"
    dns_list="$(jq -r '.network.wifi_client.static_dns | join(" ")' "${ACTIVE_SETTINGS}")"
    [ -n "${address}" ] || fail "validation_error" "wifi_client" "static_address_required" "Wi-Fi client static mode requires static_address."
    write_networkd_static "wlan0" "${metric}" "1500" "${address}" "${gateway}" "${dns_list}" "false" "${GENERATED_DIR}/systemd-networkd/20-gateway-wlan0.network"
  fi
}

generate_wifi_ap_files() {
  local enabled ssid security passphrase country band channel subnet range_start range_end
  local hw_mode hostapd_channel client_isolation dhcp_server_enabled

  enabled="$(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}")"
  [ "${enabled}" = "true" ] || return 0

  ssid="$(jq -r '.network.wifi_ap.ssid' "${ACTIVE_SETTINGS}")"
  security="$(jq -r '.network.wifi_ap.security' "${ACTIVE_SETTINGS}")"
  passphrase="$(jq -r '.network.wifi_ap.passphrase' "${ACTIVE_SETTINGS}")"
  country="$(jq -r '.network.wifi_ap.country_code' "${ACTIVE_SETTINGS}")"
  band="$(jq -r '.network.wifi_ap.band' "${ACTIVE_SETTINGS}")"
  channel="$(jq -r '.network.wifi_ap.channel' "${ACTIVE_SETTINGS}")"
  subnet="$(jq -r '.network.wifi_ap.subnet_cidr' "${ACTIVE_SETTINGS}")"
  range_start="$(jq -r '.network.wifi_ap.dhcp_range_start' "${ACTIVE_SETTINGS}")"
  range_end="$(jq -r '.network.wifi_ap.dhcp_range_end' "${ACTIVE_SETTINGS}")"
  client_isolation="$(jq -r '.network.wifi_ap.client_isolation' "${ACTIVE_SETTINGS}")"
  dhcp_server_enabled="$(jq -r '.network.wifi_ap.dhcp_server_enabled' "${ACTIVE_SETTINGS}")"

  case "${band}" in
    5ghz) hw_mode="a" ;;
    *)    hw_mode="g" ;;
  esac

  [ "${channel}" = "auto" ] && hostapd_channel="0" || hostapd_channel="${channel}"

  cat > "${GENERATED_DIR}/hostapd/hostapd.conf" <<EOF
interface=wlan0
driver=nl80211
ssid=${ssid}
country_code=${country}
hw_mode=${hw_mode}
channel=${hostapd_channel}
ieee80211d=1
ieee80211n=1
auth_algs=1
ignore_broadcast_ssid=0
EOF

  [ "${hostapd_channel}" = "0" ] && printf 'acs_num_scans=5\n' >> "${GENERATED_DIR}/hostapd/hostapd.conf"
  [ "${client_isolation}" = "true" ] && printf 'ap_isolate=1\n' >> "${GENERATED_DIR}/hostapd/hostapd.conf"

  if [ "${security}" != "open" ]; then
    cat >> "${GENERATED_DIR}/hostapd/hostapd.conf" <<EOF
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${passphrase}
EOF
  fi

  if [ "${dhcp_server_enabled}" = "true" ]; then
    cat > "${GENERATED_DIR}/dnsmasq/gateway-ap.conf" <<EOF
interface=wlan0
bind-interfaces
dhcp-range=${range_start},${range_end},255.255.255.0,12h
dhcp-option=option:router,$(printf '%s' "${subnet}" | cut -d/ -f1)
domain-needed
bogus-priv
EOF
  fi

  write_networkd_static "wlan0" "900" "1500" "${subnet}" "" "" "true" "${GENERATED_DIR}/systemd-networkd/21-gateway-wlan0-ap.network"
}

clear_wifi_runtime() {
  for svc in hostapd dnsmasq wpa_supplicant@wlan0.service; do
    systemctl is-active --quiet "${svc}" && systemctl stop "${svc}" >/dev/null 2>&1 || true
    systemctl is-enabled --quiet "${svc}" && systemctl disable "${svc}" >/dev/null 2>&1 || true
  done
}

wait_for_wifi_client_ready() {
  local timeout_seconds="$1"
  local deadline ssid address

  deadline=$(( $(date +%s) + timeout_seconds ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    ssid="$(iw dev wlan0 link 2>/dev/null | awk -F': ' '/SSID:/ {print $2; exit}')"
    address="$(ip -4 -o addr show dev wlan0 2>/dev/null | awk '{print $4}' | head -n1)"
    if [ -n "${ssid}" ] && [ -n "${address}" ]; then
      log "wifi client ready on SSID ${ssid} with address ${address}"
      return 0
    fi
    sleep 1
  done

  CURRENT_SCOPE="wifi_client"
  CURRENT_CODE="wifi_client_boot_timeout"
  CURRENT_MESSAGE="Wi-Fi client did not become ready before timeout."
  return 1
}

clear_nat_rules() {
  iptables -D FORWARD -j GATEWAY_FORWARD >/dev/null 2>&1 || true
  iptables -F GATEWAY_FORWARD >/dev/null 2>&1 || true
  iptables -X GATEWAY_FORWARD >/dev/null 2>&1 || true
  iptables -t nat -D POSTROUTING -j GATEWAY_POSTROUTING >/dev/null 2>&1 || true
  iptables -t nat -F GATEWAY_POSTROUTING >/dev/null 2>&1 || true
  iptables -t nat -X GATEWAY_POSTROUTING >/dev/null 2>&1 || true
}

uplink_iface() {
  case "$1" in
    eth0|eth1) printf '%s\n' "$1" ;;
    wifi_client) printf 'wlan0\n' ;;
    cellular) printf 'wwan0\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

configure_nat() {
  local ap_enabled nat_enabled uplink uplink_dev

  ap_enabled="$(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}")"
  nat_enabled="$(jq -r '.network.wifi_ap.nat_enabled' "${ACTIVE_SETTINGS}")"

  if [ "${ap_enabled}" != "true" ] || [ "${nat_enabled}" != "true" ]; then
    printf 'net.ipv4.ip_forward=0\n' > "${SYSCTL_FILE}"
    sysctl -q -p "${SYSCTL_FILE}" >/dev/null || true
    clear_nat_rules
    return 0
  fi

  # Use the active uplink when available. If AP mode is being applied before an
  # uplink is active, fall back to the first usable non-Wi-Fi-client priority.
  uplink="$(jq -r '.network.wifi_ap.shared_uplink_mode' "${ACTIVE_SETTINGS}")"
  if [ "${uplink}" = "auto" ]; then
    if [ "${ACTIVE_UPLINK}" != "none" ] && [ "${ACTIVE_UPLINK}" != "wifi_client" ]; then
      uplink="${ACTIVE_UPLINK}"
    else
      uplink="$(jq -r '(.network.uplink.uplink_priority // ["eth0","eth1","cellular"]) | map(select(. != "wifi_client")) | first // "eth0"' "${ACTIVE_SETTINGS}")"
    fi
  fi
  uplink_dev="$(uplink_iface "${uplink}")"

  [ -n "${uplink_dev}" ] || fail "apply_error" "wifi_ap" "no_uplink_for_nat" "Wi-Fi AP NAT is enabled but no uplink found in priority list."

  printf 'net.ipv4.ip_forward=1\n' > "${SYSCTL_FILE}"
  sysctl -q -p "${SYSCTL_FILE}" >/dev/null

  clear_nat_rules
  iptables -N GATEWAY_FORWARD
  iptables -A FORWARD -j GATEWAY_FORWARD
  iptables -A GATEWAY_FORWARD -i wlan0 -o "${uplink_dev}" -j ACCEPT
  iptables -A GATEWAY_FORWARD -i "${uplink_dev}" -o wlan0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -t nat -N GATEWAY_POSTROUTING
  iptables -t nat -A POSTROUTING -j GATEWAY_POSTROUTING
  iptables -t nat -A GATEWAY_POSTROUTING -o "${uplink_dev}" -j MASQUERADE
}

configure_services() {
  local wifi_client_enabled wifi_ap_enabled ap_dhcp_enabled wifi_dhcp

  wifi_client_enabled="$(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}")"
  wifi_ap_enabled="$(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}")"
  ap_dhcp_enabled="$(jq -r '.network.wifi_ap.dhcp_server_enabled' "${ACTIVE_SETTINGS}")"
  wifi_dhcp="$(jq -r '.network.wifi_client.dhcp' "${ACTIVE_SETTINGS}")"

  clear_wifi_runtime
  install_networkd_wlan_files
  # Reload only networkd (eth0/eth1 permanent units unaffected; only wlan0 units change)
  systemctl reload-or-restart systemd-networkd
  systemctl restart systemd-resolved || true

  if [ "${wifi_client_enabled}" != "true" ] && [ "${wifi_ap_enabled}" != "true" ]; then
    ip link set dev wlan0 up >/dev/null 2>&1 || true
  fi

  if [ "${wifi_client_enabled}" = "true" ]; then
    install -D -m 0600 "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" "${WPA_FILE}"
    systemctl is-enabled --quiet wpa_supplicant@wlan0.service || systemctl enable wpa_supplicant@wlan0.service >/dev/null 2>&1 || true
    systemctl restart wpa_supplicant@wlan0.service >/dev/null 2>&1 || systemctl start wpa_supplicant@wlan0.service >/dev/null 2>&1 || true
    if [ "${wifi_dhcp}" != "true" ]; then
      log "wifi client static mode, skipping boot wait"
    fi
  fi

  if [ "${wifi_ap_enabled}" = "true" ]; then
    install -D -m 0644 "${GENERATED_DIR}/hostapd/hostapd.conf" "${HOSTAPD_FILE}"
    printf 'DAEMON_CONF="%s"\n' "${HOSTAPD_FILE}" > "${HOSTAPD_DEFAULT}"
    systemctl unmask hostapd >/dev/null 2>&1 || true
    systemctl is-enabled --quiet hostapd || systemctl enable hostapd >/dev/null 2>&1 || true
    systemctl restart hostapd >/dev/null 2>&1 || systemctl start hostapd >/dev/null 2>&1 || true
    if [ "${ap_dhcp_enabled}" = "true" ]; then
      install -D -m 0644 "${GENERATED_DIR}/dnsmasq/gateway-ap.conf" "${DNSMASQ_FILE}"
      systemctl is-enabled --quiet dnsmasq || systemctl enable dnsmasq >/dev/null 2>&1 || true
      systemctl restart dnsmasq >/dev/null 2>&1 || systemctl start dnsmasq >/dev/null 2>&1 || true
    else
      rm -f "${DNSMASQ_FILE}"
    fi
  fi
}

configure_cellular() {
  local cellular_enabled
  cellular_enabled="$(jq -r '.network.cellular.enabled // false' "${ACTIVE_SETTINGS}")"

  if [ ! -x "${CELLULARCTL}" ]; then
    WARNING_MESSAGE="Cellular helper is missing; cellular uplink is unavailable."
    log "cellular apply skipped: helper missing at ${CELLULARCTL}"
    return 0
  fi

  if [ "${cellular_enabled}" = "true" ]; then
    log "cellular apply: enabled, requesting modem connect"
    if ! "${CELLULARCTL}" connect >/dev/null 2>&1; then
      WARNING_MESSAGE="Cellular fallback is enabled but the modem did not connect. Check SIM, APN, and antenna."
      log "cellular apply warning: modem did not connect"
    else
      log "cellular apply: connect command completed"
    fi
  else
    log "cellular apply: disabled, ensuring data session is stopped"
    "${CELLULARCTL}" disconnect >/dev/null 2>&1 || true
  fi
}

determine_active_uplink() {
  # eth0 and eth1 are always up — eligible if they have an IP.
  # wifi_client and cellular are eligible only when enabled.
  local entry
  while read -r entry; do
    case "${entry}" in
      eth0|eth1)
        if [ -n "$(ip -4 -o addr show dev "${entry}" 2>/dev/null | awk '{print $4}' | head -n1)" ]; then
          ACTIVE_UPLINK="${entry}"
          return
        fi
        ;;
      wifi_client)
        if [ "$(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}")" = "true" ]; then
          ACTIVE_UPLINK="wifi_client"
          return
        fi
        ;;
      cellular)
        if [ "$(jq -r '.network.cellular.enabled // false' "${ACTIVE_SETTINGS}")" = "true" ] && \
           [ -n "$(ip -4 -o addr show dev wwan0 2>/dev/null | awk '{print $4}' | head -n1)" ]; then
          ACTIVE_UPLINK="cellular"
          return
        fi
        ;;
    esac
  done < <(jq -r '.network.uplink.uplink_priority[]' "${ACTIVE_SETTINGS}")
  ACTIVE_UPLINK="none"
}

capture_generated_plan() {
  jq '{
    wifi_client: .network.wifi_client,
    wifi_ap: .network.wifi_ap,
    cellular: .network.cellular,
    uplink: .network.uplink
  }' "${ACTIVE_SETTINGS}" > "${GENERATED_DIR}/network-plan.json"
}

main() {
  trap 'on_error $LINENO' ERR
  ensure_layout

  [ -f "${DEFAULT_SETTINGS}" ] || fail "apply_error" "defaults" "default_config_missing" "Default network settings file is missing."

  if [ ! -f "${ACTIVE_SETTINGS}" ]; then
    restore_defaults
    USED_DEFAULTS="true"
    log "active settings missing, restored defaults"
  fi

  if ! jq empty "${ACTIVE_SETTINGS}" >/dev/null 2>&1; then
    backup_invalid; restore_defaults; USED_DEFAULTS="true"
    log "active settings invalid JSON, restored defaults"
  fi

  CURRENT_SCOPE="settings"
  CURRENT_CODE="invalid_schema"
  CURRENT_MESSAGE="Settings file does not match required schema (version 2)."
  if ! validate_config; then
    backup_invalid; restore_defaults; USED_DEFAULTS="true"
    if ! validate_config; then
      fail "validation_error" "${CURRENT_SCOPE}" "${CURRENT_CODE}" "${CURRENT_MESSAGE}"
    fi
  fi

  cp "${ACTIVE_SETTINGS}" "${LAST_GOOD_SETTINGS}"
  rm -f "${GENERATED_DIR}/systemd-networkd/"*.network "${GENERATED_DIR}/wpa_supplicant/"* \
        "${GENERATED_DIR}/hostapd/"* "${GENERATED_DIR}/dnsmasq/"* 2>/dev/null || true

  generate_wifi_client_files
  generate_wifi_ap_files
  capture_generated_plan
  configure_cellular
  determine_active_uplink

  CURRENT_SCOPE="nat"; CURRENT_CODE="nat_apply_failed"
  CURRENT_MESSAGE="Failed to apply NAT/IP forwarding settings."
  configure_nat

  CURRENT_SCOPE="services"; CURRENT_CODE="service_apply_failed"
  CURRENT_MESSAGE="Failed to apply network service configuration."
  configure_services

  if [ "$(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}")" = "true" ] && [ "${ACTIVE_UPLINK}" = "none" ]; then
    WARNING_MESSAGE="Wi-Fi AP is enabled but no uplink is active. Local AP access still works."
  fi

  write_state "$( [ "${USED_DEFAULTS}" = "true" ] && printf 'fallback_to_defaults' || printf 'ok' )"
  write_result true "$( [ "${USED_DEFAULTS}" = "true" ] && printf 'fallback_to_defaults' || printf 'ok' )" \
    "${USED_DEFAULTS}" "${ACTIVE_UPLINK}" "[]" \
    "$( [ -n "${WARNING_MESSAGE}" ] && printf '[{"scope":"network","code":"warning","message":%s}]' "$(json_escape "${WARNING_MESSAGE}")" || printf '[]' )"
  log "uplink apply complete — active_uplink=${ACTIVE_UPLINK}"
}

main "$@"
