#!/bin/bash
set -euo pipefail

LOG_TAG="gateway-network-apply"
BASE_DIR="/opt/gateway"
SYSTEM_RELATED_DIR="${BASE_DIR}/system_related"
NETWORK_DIR="${SYSTEM_RELATED_DIR}/network"
CONFIG_DIR="${NETWORK_DIR}/config"
STATE_DIR="${NETWORK_DIR}/state"
GENERATED_DIR="${NETWORK_DIR}/generated"
STORAGE_DIR="${BASE_DIR}/software_storage/AES"
DEFAULT_SETTINGS="${CONFIG_DIR}/default-network-settings.json"
ACTIVE_SETTINGS="${STORAGE_DIR}/network_settings.json"
LAST_GOOD_SETTINGS="${STORAGE_DIR}/network_settings.last_good.json"
STATE_FILE="${STATE_DIR}/network_state.json"
RESULT_FILE="${STATE_DIR}/network_apply_result.json"

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

ethernet_iface() {
  jq -r '.network.ethernet.interface // "eth1"' "${ACTIVE_SETTINGS}"
}

ensure_layout() {
  install -d -m 0755 "${BASE_DIR}" "${SYSTEM_RELATED_DIR}" "${NETWORK_DIR}" "${CONFIG_DIR}" "${STATE_DIR}" "${GENERATED_DIR}" "${STORAGE_DIR}"
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
  local ok="$1"
  local status="$2"
  local used_defaults="$3"
  local active_uplink="$4"
  local errors_json="$5"
  local warnings_json="$6"

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
  write_result false "apply_error" "${USED_DEFAULTS}" "${ACTIVE_UPLINK}" "[{\"scope\":$(json_escape "${CURRENT_SCOPE:-network}"),\"code\":$(json_escape "${CURRENT_CODE:-unexpected_error}"),\"message\":$(json_escape "${CURRENT_MESSAGE:-Unexpected failure while applying network configuration.}")}]" "$( [ -n "${WARNING_MESSAGE}" ] && printf '[{"scope":"network","code":"warning","message":%s}]' "$(json_escape "${WARNING_MESSAGE}")" || printf '[]' )"
  log "apply_error at line ${line}: ${CURRENT_SCOPE:-network}/${CURRENT_CODE:-unexpected_error}: ${CURRENT_MESSAGE:-Unexpected failure while applying network configuration.}"
  exit 1
}

write_state() {
  local status="$1"
  local ethernet_iface_name
  local ethernet_addr
  local wifi_addr
  local ethernet_link
  local wifi_present
  local wifi_up
  local ap_clients
  local connected_ssid

  ethernet_iface_name="$(ethernet_iface)"
  ethernet_addr="$(ip -4 -o addr show dev "${ethernet_iface_name}" 2>/dev/null | awk '{print $4}' | head -n1)"
  wifi_addr="$(ip -4 -o addr show dev wlan0 2>/dev/null | awk '{print $4}' | head -n1)"
  ethernet_link="$(ip -j link show "${ethernet_iface_name}" 2>/dev/null | jq -r 'if length == 0 then false else .[0].operstate == "UP" end')"
  wifi_present="$(ip link show wlan0 >/dev/null 2>&1 && printf true || printf false)"
  wifi_up="$(ip -j link show wlan0 2>/dev/null | jq -r 'if length == 0 then false else (.[0].flags | index("UP") != null) end')"
  ap_clients="$(iw dev wlan0 station dump 2>/dev/null | grep -c '^Station' || true)"
  connected_ssid="$(iw dev wlan0 link 2>/dev/null | awk -F': ' '/SSID:/ {print $2; exit}')"
  connected_ssid="${connected_ssid:-}"

  write_json_file "${STATE_FILE}" <<EOF
{
  "active_uplink": "${ACTIVE_UPLINK}",
  "last_apply_status": "${status}",
  "last_apply_timestamp": "$(date --iso-8601=seconds)",
  "ethernet": {
    "interface": $(json_escape "${ethernet_iface_name}"),
    "link_up": ${ethernet_link:-false},
    "address": "${ethernet_addr:-}",
    "enabled": $(jq -r '.network.ethernet.enabled' "${ACTIVE_SETTINGS}")
  },
  "wifi_client": {
    "interface": "wlan0",
    "present": ${wifi_present:-false},
    "interface_up": ${wifi_up:-false},
    "enabled": $(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}"),
    "connected_ssid": $(json_escape "${connected_ssid}")
  },
  "wifi_ap": {
    "interface": "wlan0",
    "enabled": $(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}"),
    "address": "${wifi_addr:-}",
    "clients": ${ap_clients:-0}
  }
}
EOF
}

fail() {
  local status="$1"
  local scope="$2"
  local code="$3"
  local message="$4"

  trap - ERR
  write_result false "${status}" "${USED_DEFAULTS}" "${ACTIVE_UPLINK}" "[{\"scope\":$(json_escape "${scope}"),\"code\":$(json_escape "${code}"),\"message\":$(json_escape "${message}")}]" "$( [ -n "${WARNING_MESSAGE}" ] && printf '[{"scope":"network","code":"warning","message":%s}]' "$(json_escape "${WARNING_MESSAGE}")" || printf '[]' )"
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
    .version == 1 and
    (.network.ethernet.interface | type == "string" and length > 0) and
    .network.wifi_client.interface == "wlan0" and
    .network.wifi_ap.interface == "wlan0" and
    (.network.policy.uplink_priority | type == "array") and
    (.network.ethernet.route_metric | type == "number") and
    (.network.wifi_client.route_metric | type == "number") and
    (.network.ethernet.mtu | type == "number") and
    (.network.ethernet.enabled | type == "boolean") and
    (.network.wifi_client.enabled | type == "boolean") and
    (.network.wifi_ap.enabled | type == "boolean")
  ' "${ACTIVE_SETTINGS}" >/dev/null || return 1

  if [ "$(jq -r '.network.wifi_client.enabled and .network.wifi_ap.enabled' "${ACTIVE_SETTINGS}")" = "true" ]; then
    CURRENT_SCOPE="wifi"
    CURRENT_CODE="client_ap_conflict"
    CURRENT_MESSAGE="This first implementation does not support Wi-Fi client and Wi-Fi AP mode at the same time on wlan0."
    return 1
  fi

  if [ "$(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}")" = "true" ]; then
    if [ -z "$(jq -r '.network.wifi_client.ssid' "${ACTIVE_SETTINGS}")" ]; then
      CURRENT_SCOPE="wifi_client"
      CURRENT_CODE="ssid_required"
      CURRENT_MESSAGE="Wi-Fi client is enabled but SSID is empty."
      return 1
    fi
    if [ "$(jq -r '.network.wifi_client.security' "${ACTIVE_SETTINGS}")" != "open" ] && [ -z "$(jq -r '.network.wifi_client.passphrase' "${ACTIVE_SETTINGS}")" ]; then
      CURRENT_SCOPE="wifi_client"
      CURRENT_CODE="passphrase_required"
      CURRENT_MESSAGE="Wi-Fi client security requires a passphrase."
      return 1
    fi
  fi

  if [ "$(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}")" = "true" ]; then
    if [ -z "$(jq -r '.network.wifi_ap.ssid' "${ACTIVE_SETTINGS}")" ]; then
      CURRENT_SCOPE="wifi_ap"
      CURRENT_CODE="ssid_required"
      CURRENT_MESSAGE="Wi-Fi AP is enabled but SSID is empty."
      return 1
    fi
    if [ "$(jq -r '.network.wifi_ap.security' "${ACTIVE_SETTINGS}")" != "open" ] && [ -z "$(jq -r '.network.wifi_ap.passphrase' "${ACTIVE_SETTINGS}")" ]; then
      CURRENT_SCOPE="wifi_ap"
      CURRENT_CODE="passphrase_required"
      CURRENT_MESSAGE="Wi-Fi AP security requires a passphrase."
      return 1
    fi
    if [ "$(jq -r '.network.wifi_ap.shared_uplink_mode' "${ACTIVE_SETTINGS}")" = "wifi_client" ]; then
      CURRENT_SCOPE="wifi_ap"
      CURRENT_CODE="shared_uplink_unsupported"
      CURRENT_MESSAGE="Wi-Fi AP cannot currently use Wi-Fi client as its shared uplink on the same radio."
      return 1
    fi
  fi
}

write_networkd_dhcp() {
  local iface="$1"
  local metric="$2"
  local mtu="$3"
  local target="$4"

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
  local iface="$1"
  local metric="$2"
  local mtu="$3"
  local address="$4"
  local gateway="$5"
  local dns_list="$6"
  local configure_without_carrier="$7"
  local target="$8"

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

install_networkd_files() {
  rm -f "${NETWORKD_DIR}/01-eth0.network" "${NETWORKD_DIR}/01-eth1.network"
  rm -f "${NETWORKD_DIR}/10-gateway-eth0.network" "${NETWORKD_DIR}/10-gateway-ethernet.network" "${NETWORKD_DIR}/20-gateway-wlan0.network" "${NETWORKD_DIR}/21-gateway-wlan0-ap.network"
  [ -f "${GENERATED_DIR}/systemd-networkd/10-gateway-ethernet.network" ] && install -D -m 0644 "${GENERATED_DIR}/systemd-networkd/10-gateway-ethernet.network" "${NETWORKD_DIR}/10-gateway-ethernet.network"
  [ -f "${GENERATED_DIR}/systemd-networkd/20-gateway-wlan0.network" ] && install -D -m 0644 "${GENERATED_DIR}/systemd-networkd/20-gateway-wlan0.network" "${NETWORKD_DIR}/20-gateway-wlan0.network"
  [ -f "${GENERATED_DIR}/systemd-networkd/21-gateway-wlan0-ap.network" ] && install -D -m 0644 "${GENERATED_DIR}/systemd-networkd/21-gateway-wlan0-ap.network" "${NETWORKD_DIR}/21-gateway-wlan0-ap.network"
  return 0
}

generate_ethernet_network() {
  local enabled dhcp metric mtu address gateway dns_list iface

  enabled="$(jq -r '.network.ethernet.enabled' "${ACTIVE_SETTINGS}")"
  [ "${enabled}" = "true" ] || return 0

  iface="$(ethernet_iface)"
  dhcp="$(jq -r '.network.ethernet.dhcp' "${ACTIVE_SETTINGS}")"
  metric="$(jq -r '.network.ethernet.route_metric' "${ACTIVE_SETTINGS}")"
  mtu="$(jq -r '.network.ethernet.mtu' "${ACTIVE_SETTINGS}")"
  dns_list="$(jq -r '.network.ethernet.static_dns | join(" ")' "${ACTIVE_SETTINGS}")"

  if [ "${dhcp}" = "true" ]; then
    write_networkd_dhcp "${iface}" "${metric}" "${mtu}" "${GENERATED_DIR}/systemd-networkd/10-gateway-ethernet.network"
  else
    address="$(jq -r '.network.ethernet.static_address' "${ACTIVE_SETTINGS}")"
    gateway="$(jq -r '.network.ethernet.static_gateway' "${ACTIVE_SETTINGS}")"
    [ -n "${address}" ] || fail "validation_error" "ethernet" "static_address_required" "Ethernet static mode requires static_address."
    write_networkd_static "${iface}" "${metric}" "${mtu}" "${address}" "${gateway}" "${dns_list}" "false" "${GENERATED_DIR}/systemd-networkd/10-gateway-ethernet.network"
  fi
}

generate_wifi_client_files() {
  local enabled dhcp metric security passphrase ssid hidden country band gateway address dns_list

  enabled="$(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}")"
  [ "${enabled}" = "true" ] || return 0

  security="$(jq -r '.network.wifi_client.security' "${ACTIVE_SETTINGS}")"
  passphrase="$(jq -r '.network.wifi_client.passphrase' "${ACTIVE_SETTINGS}")"
  ssid="$(jq -r '.network.wifi_client.ssid' "${ACTIVE_SETTINGS}")"
  hidden="$(jq -r '.network.wifi_client.hidden_ssid' "${ACTIVE_SETTINGS}")"
  country="$(jq -r '.network.wifi_client.country_code' "${ACTIVE_SETTINGS}")"
  band="$(jq -r '.network.wifi_client.band' "${ACTIVE_SETTINGS}")"

  cat > "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" <<EOF
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=0
country=${country}

network={
    ssid=$(json_escape "${ssid}")
EOF

  case "${security}" in
    open)
      cat >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" <<'EOF'
    key_mgmt=NONE
EOF
      ;;
    wpa3-sae)
      cat >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" <<EOF
    key_mgmt=SAE
    sae_password=$(json_escape "${passphrase}")
EOF
      ;;
    wpa2-wpa3)
      cat >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" <<EOF
    key_mgmt=WPA-PSK SAE
    psk=$(json_escape "${passphrase}")
EOF
      ;;
    *)
      cat >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" <<EOF
    key_mgmt=WPA-PSK
    psk=$(json_escape "${passphrase}")
EOF
      ;;
  esac

  [ "${hidden}" = "true" ] && printf '    scan_ssid=1\n' >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf"

  case "${band}" in
    2.4ghz)
      printf '    freq_list=2412 2437 2462\n' >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf"
      ;;
    5ghz)
      printf '    freq_list=5180 5200 5220 5240 5745 5765 5785 5805\n' >> "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf"
      ;;
  esac

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
    5ghz)
      hw_mode="a"
      ;;
    *)
      hw_mode="g"
      ;;
  esac

  if [ "${channel}" = "auto" ]; then
    hostapd_channel="0"
  else
    hostapd_channel="${channel}"
  fi

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

  if [ "${hostapd_channel}" = "0" ]; then
    cat >> "${GENERATED_DIR}/hostapd/hostapd.conf" <<'EOF'
acs_num_scans=5
EOF
  fi

  if [ "${client_isolation}" = "true" ]; then
    cat >> "${GENERATED_DIR}/hostapd/hostapd.conf" <<'EOF'
ap_isolate=1
EOF
  fi

  if [ "${security}" = "open" ]; then
    :
  else
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
  if systemctl is-active --quiet hostapd; then
    systemctl stop hostapd >/dev/null 2>&1 || true
  fi
  if systemctl is-enabled --quiet hostapd; then
    systemctl disable hostapd >/dev/null 2>&1 || true
  fi

  if systemctl is-active --quiet dnsmasq; then
    systemctl stop dnsmasq >/dev/null 2>&1 || true
  fi
  if systemctl is-enabled --quiet dnsmasq; then
    systemctl disable dnsmasq >/dev/null 2>&1 || true
  fi

  if systemctl is-active --quiet wpa_supplicant@wlan0.service; then
    systemctl stop wpa_supplicant@wlan0.service >/dev/null 2>&1 || true
  fi
  if systemctl is-enabled --quiet wpa_supplicant@wlan0.service; then
    systemctl disable wpa_supplicant@wlan0.service >/dev/null 2>&1 || true
  fi
}

disable_interface_runtime() {
  local iface="$1"

  ip -4 route flush dev "${iface}" >/dev/null 2>&1 || true
  ip -6 route flush dev "${iface}" >/dev/null 2>&1 || true
  ip addr flush dev "${iface}" >/dev/null 2>&1 || true
  ip link set dev "${iface}" down >/dev/null 2>&1 || true
}

wait_for_wifi_client_ready() {
  local timeout_seconds="$1"
  local deadline remaining ssid address

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

  remaining="$(iw dev wlan0 link 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  [ -n "${remaining}" ] || remaining="no association details available"
  CURRENT_SCOPE="wifi_client"
  CURRENT_CODE="wifi_client_boot_timeout"
  CURRENT_MESSAGE="Wi-Fi client did not become ready before timeout. ${remaining}"
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

configure_nat() {
  local ap_enabled nat_enabled uplink

  ap_enabled="$(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}")"
  nat_enabled="$(jq -r '.network.wifi_ap.nat_enabled' "${ACTIVE_SETTINGS}")"

  if [ "${ap_enabled}" != "true" ] || [ "${nat_enabled}" != "true" ]; then
    printf 'net.ipv4.ip_forward=0\n' > "${SYSCTL_FILE}"
    sysctl -q -p "${SYSCTL_FILE}" >/dev/null || true
    clear_nat_rules
    return 0
  fi

  uplink="$(jq -r '.network.wifi_ap.shared_uplink_mode' "${ACTIVE_SETTINGS}")"
  if [ "${uplink}" = "auto" ]; then
    if [ "$(jq -r '.network.ethernet.enabled' "${ACTIVE_SETTINGS}")" = "true" ]; then
      uplink="$(ethernet_iface)"
    else
      fail "apply_error" "wifi_ap" "no_shared_uplink" "Wi-Fi AP NAT is enabled but no supported uplink is available."
    fi
  fi

  if [ "${uplink}" = "ethernet" ] || [ "${uplink}" = "eth0" ]; then
    uplink="$(ethernet_iface)"
  fi
  [ -n "${uplink}" ] || fail "apply_error" "wifi_ap" "unsupported_shared_uplink" "This implementation currently supports Wi-Fi AP NAT only through Ethernet uplink."

  printf 'net.ipv4.ip_forward=1\n' > "${SYSCTL_FILE}"
  sysctl -q -p "${SYSCTL_FILE}" >/dev/null

  clear_nat_rules
  iptables -N GATEWAY_FORWARD
  iptables -A FORWARD -j GATEWAY_FORWARD
  iptables -A GATEWAY_FORWARD -i wlan0 -o "${uplink}" -j ACCEPT
  iptables -A GATEWAY_FORWARD -i "${uplink}" -o wlan0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  iptables -t nat -N GATEWAY_POSTROUTING
  iptables -t nat -A POSTROUTING -j GATEWAY_POSTROUTING
  iptables -t nat -A GATEWAY_POSTROUTING -o "${uplink}" -j MASQUERADE
}

configure_services() {
  local wifi_client_enabled wifi_ap_enabled ap_dhcp_enabled
  local ethernet_enabled ethernet_iface_name
  local wifi_dhcp

  ethernet_iface_name="$(ethernet_iface)"
  ethernet_enabled="$(jq -r '.network.ethernet.enabled' "${ACTIVE_SETTINGS}")"
  wifi_client_enabled="$(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}")"
  wifi_ap_enabled="$(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}")"
  ap_dhcp_enabled="$(jq -r '.network.wifi_ap.dhcp_server_enabled' "${ACTIVE_SETTINGS}")"
  wifi_dhcp="$(jq -r '.network.wifi_client.dhcp' "${ACTIVE_SETTINGS}")"

  clear_wifi_runtime
  install_networkd_files
  systemctl restart systemd-networkd
  systemctl restart systemd-resolved || true

  if [ "${ethernet_enabled}" != "true" ]; then
    disable_interface_runtime "${ethernet_iface_name}"
  fi

  if [ "${wifi_client_enabled}" != "true" ] && [ "${wifi_ap_enabled}" != "true" ]; then
    disable_interface_runtime "wlan0"
  else
    ip link set dev wlan0 up >/dev/null 2>&1 || true
  fi

  if [ "${wifi_client_enabled}" = "true" ]; then
    install -D -m 0600 "${GENERATED_DIR}/wpa_supplicant/wpa_supplicant-wlan0.conf" "${WPA_FILE}"
    if ! systemctl is-enabled --quiet wpa_supplicant@wlan0.service; then
      systemctl enable wpa_supplicant@wlan0.service >/dev/null 2>&1 || true
    fi
    systemctl restart wpa_supplicant@wlan0.service >/dev/null 2>&1 || systemctl start wpa_supplicant@wlan0.service >/dev/null 2>&1 || true

    if [ "${ethernet_enabled}" != "true" ]; then
      log "ethernet disabled, waiting for wifi client readiness"
      wait_for_wifi_client_ready 45
    elif [ "${wifi_dhcp}" != "true" ]; then
      log "wifi client static mode configured, skipping boot wait because no DHCP lease is needed"
    fi
  fi

  if [ "${wifi_ap_enabled}" = "true" ]; then
    install -D -m 0644 "${GENERATED_DIR}/hostapd/hostapd.conf" "${HOSTAPD_FILE}"
    cat > "${HOSTAPD_DEFAULT}" <<EOF
DAEMON_CONF="${HOSTAPD_FILE}"
EOF
    systemctl unmask hostapd >/dev/null 2>&1 || true
    if ! systemctl is-enabled --quiet hostapd; then
      systemctl enable hostapd >/dev/null 2>&1 || true
    fi
    systemctl restart hostapd >/dev/null 2>&1 || systemctl start hostapd >/dev/null 2>&1 || true
    if [ "${ap_dhcp_enabled}" = "true" ]; then
      install -D -m 0644 "${GENERATED_DIR}/dnsmasq/gateway-ap.conf" "${DNSMASQ_FILE}"
      if ! systemctl is-enabled --quiet dnsmasq; then
        systemctl enable dnsmasq >/dev/null 2>&1 || true
      fi
      systemctl restart dnsmasq >/dev/null 2>&1 || systemctl start dnsmasq >/dev/null 2>&1 || true
    else
      rm -f "${DNSMASQ_FILE}"
    fi
  fi
}

determine_active_uplink() {
  local priority entry
  while read -r entry; do
    case "${entry}" in
      eth0)
        if [ "$(jq -r '.network.ethernet.enabled' "${ACTIVE_SETTINGS}")" = "true" ]; then
          ACTIVE_UPLINK="eth0"
          return
        fi
        ;;
      wifi_client)
        if [ "$(jq -r '.network.wifi_client.enabled' "${ACTIVE_SETTINGS}")" = "true" ]; then
          ACTIVE_UPLINK="wifi_client"
          return
        fi
        ;;
    esac
  done < <(jq -r '.network.policy.uplink_priority[]' "${ACTIVE_SETTINGS}")
  ACTIVE_UPLINK="none"
}

capture_generated_plan() {
  jq '{
    ethernet: .network.ethernet,
    wifi_client: .network.wifi_client,
    wifi_ap: .network.wifi_ap,
    policy: .network.policy
  }' "${ACTIVE_SETTINGS}" > "${GENERATED_DIR}/network-plan.json"
}

main() {
  trap 'on_error $LINENO' ERR
  ensure_layout

  if [ ! -f "${DEFAULT_SETTINGS}" ]; then
    fail "apply_error" "defaults" "default_config_missing" "Default network settings file is missing."
  fi

  if [ ! -f "${ACTIVE_SETTINGS}" ]; then
    restore_defaults
    USED_DEFAULTS="true"
    log "active settings missing, restored defaults"
  fi

  if ! jq empty "${ACTIVE_SETTINGS}" >/dev/null 2>&1; then
    backup_invalid
    restore_defaults
    USED_DEFAULTS="true"
    log "active settings invalid JSON, restored defaults"
  fi

  CURRENT_SCOPE="settings"
  CURRENT_CODE="invalid_schema"
  CURRENT_MESSAGE="Settings file does not match minimum required schema."
  if ! validate_config; then
    backup_invalid
    restore_defaults
    USED_DEFAULTS="true"
    if ! validate_config; then
      fail "validation_error" "${CURRENT_SCOPE}" "${CURRENT_CODE}" "${CURRENT_MESSAGE}"
    fi
  fi

  cp "${ACTIVE_SETTINGS}" "${LAST_GOOD_SETTINGS}"

  rm -f "${GENERATED_DIR}/systemd-networkd/"*.network "${GENERATED_DIR}/wpa_supplicant/"* "${GENERATED_DIR}/hostapd/"* "${GENERATED_DIR}/dnsmasq/"* 2>/dev/null || true

  generate_ethernet_network
  generate_wifi_client_files
  generate_wifi_ap_files
  capture_generated_plan
  determine_active_uplink
  CURRENT_SCOPE="nat"
  CURRENT_CODE="nat_apply_failed"
  CURRENT_MESSAGE="Failed to apply gateway NAT or IP forwarding settings."
  configure_nat
  CURRENT_SCOPE="services"
  CURRENT_CODE="service_apply_failed"
  CURRENT_MESSAGE="Failed to apply generated network service configuration."
  configure_services

  if [ "$(jq -r '.network.wifi_ap.enabled' "${ACTIVE_SETTINGS}")" = "true" ] && [ "${ACTIVE_UPLINK}" = "none" ]; then
    WARNING_MESSAGE="Wi-Fi AP is enabled but no uplink is available yet. Local AP access will still work."
  fi

  write_state "$( [ "${USED_DEFAULTS}" = "true" ] && printf 'fallback_to_defaults' || printf 'ok' )"
  write_result true "$( [ "${USED_DEFAULTS}" = "true" ] && printf 'fallback_to_defaults' || printf 'ok' )" "${USED_DEFAULTS}" "${ACTIVE_UPLINK}" "[]" "$( [ -n "${WARNING_MESSAGE}" ] && printf '[{"scope":"network","code":"warning","message":%s}]' "$(json_escape "${WARNING_MESSAGE}")" || printf '[]' )"
  log "network apply complete"
}

main "$@"
