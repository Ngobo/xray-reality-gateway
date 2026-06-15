#!/usr/bin/env bash
#
# install.sh — VLESS+Reality transparent-proxy gateway installer for Ubuntu 22.04.
#
# One-line install:
#   bash <(curl -sL https://raw.githubusercontent.com/Ngobo/xray-reality-gateway/main/install.sh)
# Uninstall:
#   bash <(curl -sL https://raw.githubusercontent.com/Ngobo/xray-reality-gateway/main/install.sh) --uninstall
#
set -euo pipefail

# --- Constants -------------------------------------------------------------
XRAY_VERSION="26.6.1"
XRAY_BIN="/usr/local/bin/xray"
XRAY_ASSET_DIR="/usr/local/share/xray"
GEOSITE_URL="https://github.com/runetfreedom/russia-blocked-geosite/releases/latest/download/geosite.dat"
GEOIP_URL="https://github.com/runetfreedom/russia-blocked-geoip/releases/latest/download/geoip.dat"
NFT_FILE="/etc/nftables.d/xray-tproxy.nft"
NFT_CONF="/etc/nftables.conf"
SYSTEMD_DROPIN="/etc/systemd/system/xray.service.d/tproxy.conf"
SYSCTL_FILE="/etc/sysctl.d/99-xray-tproxy.conf"
CRON_FILE="/etc/cron.daily/update-runetfreedom-geodata"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# --- Defaults (overridable by prompts) -------------------------------------
DEFAULT_CONFIG_PATH="/usr/local/etc/xray/config.json"
DEFAULT_TCP_PORT="12345"
DEFAULT_UDP_PORT="12346"
DEFAULT_WG_PORTS="44781,36916"

# --- Mode flags ------------------------------------------------------------
MODE="install"      # install | uninstall
KEEP_XRAY="no"      # uninstall modifier
QUIET="no"

# --- Logging ---------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET="$(tput sgr0)"; C_RED="$(tput setaf 1)"; C_GRN="$(tput setaf 2)"
    C_YEL="$(tput setaf 3)"; C_BLU="$(tput setaf 4)"; C_BOLD="$(tput bold)"
else
    C_RESET=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""
fi

PHASE_TOTAL=9
phase() {  # phase <num> <title>
    printf '\n%s==> [%s/%s] %s%s\n' "$C_BOLD$C_BLU" "$1" "$PHASE_TOTAL" "$2" "$C_RESET"
}
log()  { [[ "$QUIET" == "yes" ]] && return 0; printf '  %s•%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
die()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Back up an existing file to <file>.bak before it is overwritten.
backup_file() {
    local f="$1"
    if [[ -e "$f" ]]; then
        cp -a "$f" "${f}.bak"
        warn "$f existed — backed up to ${f}.bak"
    fi
}


# --- VLESS URI parsing -----------------------------------------------------
urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

# Parse a vless:// URI into P_* globals. Dies on malformed input / missing fields.
parse_vless() {
    local uri="$1" body userinfo rest hostport query
    uri="${uri#"${uri%%[![:space:]]*}"}"   # ltrim
    uri="${uri%"${uri##*[![:space:]]}"}"   # rtrim
    [[ "$uri" == vless://* ]] || die "URI must start with 'vless://'"

    body="${uri#vless://}"; body="${body%%#*}"
    userinfo="${body%%@*}"
    rest="${body#*@}"
    hostport="${rest%%\?*}"
    query=""; [[ "$rest" == *\?* ]] && query="${rest#*\?}"

    P_UUID="$userinfo"
    P_HOST="${hostport%:*}"; P_HOST="${P_HOST#[}"; P_HOST="${P_HOST%]}"
    P_PORT="${hostport##*:}"

    local k v pair
    local pbk="" sid="" sni="" host="" flow="" fp=""
    if [[ -n "$query" ]]; then
        local IFS='&'; local -a pairs
        read -r -a pairs <<< "$query"
        for pair in "${pairs[@]}"; do
            [[ -z "$pair" ]] && continue
            k="${pair%%=*}"; v="$(urldecode "${pair#*=}")"
            case "$k" in
                pbk) pbk="$v" ;; sid) sid="$v" ;; sni) sni="$v" ;;
                host) host="$v" ;; flow) flow="$v" ;; fp) fp="$v" ;;
            esac
        done
    fi
    P_PBK="$pbk"; P_SID="$sid"
    P_SNI="${sni:-$host}"
    P_FLOW="${flow:-xtls-rprx-vision}"
    P_FP="${fp:-chrome}"

    local -a missing=()
    [[ -z "$P_UUID" ]] && missing+=("uuid")
    [[ -z "$P_HOST" ]] && missing+=("host")
    [[ -z "$P_PORT" ]] && missing+=("port")
    [[ -z "$P_PBK"  ]] && missing+=("pbk")
    [[ -z "$P_SNI"  ]] && missing+=("sni")
    (( ${#missing[@]} )) && die "URI missing required fields: ${missing[*]}"
    [[ "$P_PORT" =~ ^[0-9]+$ ]] || die "parsed port '$P_PORT' is not numeric"
}

# --- Input collection ------------------------------------------------------
# Candidate LAN interfaces: bridges + AmneziaWG/WireGuard. Overridable in tests.
_list_candidate_ifaces() {
    { ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//'
      ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' \
        | grep -E '^(amn|wg)' ; } | sort -u
}

detect_lan_ifaces() {
    local -a found=()
    while IFS= read -r ifc; do [[ -n "$ifc" ]] && found+=("$ifc"); done < <(_list_candidate_ifaces)
    (( ${#found[@]} == 0 )) && return
    local out="${found[0]}"
    local i; for (( i=1; i<${#found[@]}; i++ )); do out+=", ${found[$i]}"; done
    printf '%s' "$out"
}

# prompt_default <prompt> <default> -> echoes the chosen value
prompt_default() {
    local reply
    read -r -p "  $1 [$2]: " reply
    printf '%s' "${reply:-$2}"
}

# Normalize "br0, amn0" -> nftables set body: "br0", "amn0"
ifaces_to_nft_set() {
    local raw="$1" out="" ifc
    raw="${raw//,/ }"
    for ifc in $raw; do [[ -n "$ifc" ]] && out+="\"$ifc\", "; done
    printf '%s' "${out%, }"
}

collect_inputs() {
    phase 1 "Collect configuration"

    local uri=""
    while :; do
        read -r -p "  Paste your VLESS+Reality URI: " uri
        if parse_vless "$uri"; then break; fi
    done

    local detected; detected="$(detect_lan_ifaces)"
    [[ -z "$detected" ]] && detected="br0"
    LAN_IFACES="$(prompt_default "LAN interfaces (comma-separated)" "$detected")"
    WG_PORTS="$(prompt_default "WireGuard exempt UDP ports (comma-separated, blank to skip)" "$DEFAULT_WG_PORTS")"
    TCP_PORT="$(prompt_default "TCP tproxy port" "$DEFAULT_TCP_PORT")"
    UDP_PORT="$(prompt_default "UDP tproxy port" "$DEFAULT_UDP_PORT")"
    CONFIG_PATH="$(prompt_default "xray config path" "$DEFAULT_CONFIG_PATH")"

    # First WG interface (for the sport-exempt rule), if any WG iface present.
    WG_IFACE="$(printf '%s' "$LAN_IFACES" | tr ',' '\n' | sed 's/ //g' | grep -E '^(amn|wg)' | head -n1)"

    printf '\n%sConfiguration summary:%s\n' "$C_BOLD" "$C_RESET"
    printf '  server      : %s:%s\n' "$P_HOST" "$P_PORT"
    printf '  sni / flow  : %s / %s\n' "$P_SNI" "$P_FLOW"
    printf '  LAN ifaces  : %s\n' "$LAN_IFACES"
    printf '  WG exempt   : %s (iface %s)\n' "${WG_PORTS:-none}" "${WG_IFACE:-none}"
    printf '  tproxy ports: tcp %s / udp %s\n' "$TCP_PORT" "$UDP_PORT"
    printf '  config path : %s\n\n' "$CONFIG_PATH"

    local confirm
    read -r -p "  Proceed and apply these changes? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user — no changes made."
    ok "Inputs collected"
}

usage() {
    cat << 'USAGE'
Xray Reality Gateway installer

Usage:
  install.sh                  Install / configure the gateway (interactive)
  install.sh --uninstall      Full revert (removes xray, config, nftables, etc.)
  install.sh --uninstall --keep-xray
                              Tear down tproxy plumbing only; keep xray binary + config
  install.sh --quiet          Suppress info lines (keep phase banners + warnings/errors)
  install.sh --help           Show this help

One-liner:
  bash <(curl -sL https://raw.githubusercontent.com/Ngobo/xray-reality-gateway/main/install.sh)
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall|-u) MODE="uninstall" ;;
            --keep-xray)    KEEP_XRAY="yes" ;;
            --quiet)        QUIET="yes" ;;
            --help|-h)      usage; exit 0 ;;
            *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
}

# --- Phase stubs (filled in by later tasks) --------------------------------
phase_preflight() {
    phase 0 "Preflight"
    [[ $EUID -eq 0 ]] || die "Must run as root. Re-run with sudo."
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        [[ "${ID:-}" == "ubuntu" ]] || warn "Not Ubuntu (${PRETTY_NAME:-unknown}) — continuing best-effort."
    fi
    local missing=()
    for tool in curl wget nft; do command -v "$tool" >/dev/null 2>&1 || missing+=("$tool"); done
    if (( ${#missing[@]} )); then
        log "Installing missing tools: ${missing[*]}"
        apt-get update -qq && apt-get install -y "${missing[@]}" >/dev/null
    fi
    ok "Preflight complete"
}
phase_install_xray() {
    phase 2 "Install xray"
    if [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version 2>/dev/null | grep -q "Xray $XRAY_VERSION"; then
        ok "xray $XRAY_VERSION already installed — skipping"
        return
    fi
    log "Running official XTLS install script"
    bash -c "$(curl -L "$XRAY_INSTALL_URL")" @ install
    "$XRAY_BIN" version | head -n1 | grep -q "Xray $XRAY_VERSION" \
        || warn "Installed xray version differs from expected $XRAY_VERSION"
    ok "xray installed"
}
phase_geo_files() {
    phase 3 "Geo files (runetfreedom)"
    mkdir -p "$XRAY_ASSET_DIR"
    log "Downloading geosite.dat"
    wget -q -O "$XRAY_ASSET_DIR/geosite.dat" "$GEOSITE_URL" || die "geosite.dat download failed"
    log "Downloading geoip.dat"
    wget -q -O "$XRAY_ASSET_DIR/geoip.dat" "$GEOIP_URL" || die "geoip.dat download failed"
    ok "Geo files updated"
}
phase_config() {
    phase 4 "Generate config.json"
    mkdir -p "$(dirname "$CONFIG_PATH")"
    backup_file "$CONFIG_PATH"
    cat > "$CONFIG_PATH" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "transparent-tcp",
      "listen": "0.0.0.0",
      "port": $TCP_PORT,
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp", "followRedirect": true },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] },
      "streamSettings": { "sockopt": { "tproxy": "redirect" } }
    },
    {
      "tag": "transparent-udp",
      "listen": "0.0.0.0",
      "port": $UDP_PORT,
      "protocol": "dokodemo-door",
      "settings": { "network": "udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$P_HOST",
          "port": $P_PORT,
          "users": [{ "id": "$P_UUID", "flow": "$P_FLOW", "encryption": "none" }]
        }]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "sockopt": { "mark": 255 },
        "realitySettings": {
          "fingerprint": "$P_FP",
          "serverName": "$P_SNI",
          "publicKey": "$P_PBK",
          "shortId": "$P_SID"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom", "streamSettings": { "sockopt": { "mark": 255 } } }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" },
      { "type": "field",
        "domain": ["geosite:ru-blocked","geosite:twitter","geosite:meta","geosite:telegram","geosite:youtube","geosite:netflix"],
        "outboundTag": "proxy" },
      { "type": "field", "ip": ["geoip:telegram","geoip:facebook"], "outboundTag": "proxy" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
    ]
  }
}
EOF
    if command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$CONFIG_PATH" >/dev/null || die "generated config.json is not valid JSON"
    fi
    ok "Wrote $CONFIG_PATH"
}
phase_nftables() {
    phase 5 "nftables rules"
    mkdir -p "$(dirname "$NFT_FILE")"
    backup_file "$NFT_FILE"

    local iface_set; iface_set="$(ifaces_to_nft_set "$LAN_IFACES")"
    # Optional WireGuard sport-exempt line (only if both an iface and ports were given).
    local wg_line=""
    if [[ -n "$WG_PORTS" && -n "$WG_IFACE" ]]; then
        wg_line="        iifname \"$WG_IFACE\" udp sport { $WG_PORTS } return"
    fi

    cat > "$NFT_FILE" << EOF
table inet xray_tproxy {
    set private_ranges {
        type ipv4_addr
        flags interval
        elements = {
            0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10,
            127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12,
            192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15,
            224.0.0.0/4, 240.0.0.0/4
        }
    }

    chain prerouting_nat {
        type nat hook prerouting priority dstnat; policy accept;
        meta mark 0x000000ff return
        fib daddr type local return
        iifname != { $iface_set } return
        ip daddr @private_ranges return
        ip protocol tcp redirect to :$TCP_PORT
    }

    chain prerouting_mangle {
        type filter hook prerouting priority mangle; policy accept;
        meta mark 0x000000ff return
        fib daddr type local return
$wg_line
        iifname != { $iface_set } return
        ip daddr @private_ranges return
        ip protocol udp tproxy ip to :$UDP_PORT meta mark set 0x00000001
    }
}
EOF
    # Drop the blank line left when wg_line is empty, to keep the file tidy.
    sed -i '/^$/{N;/^\n$/D}' "$NFT_FILE"

    backup_file "$NFT_CONF"
    [[ -e "$NFT_CONF" ]] || printf '#!/usr/sbin/nft -f\n' > "$NFT_CONF"
    if ! grep -qF "include \"$NFT_FILE\"" "$NFT_CONF"; then
        printf 'include "%s"\n' "$NFT_FILE" >> "$NFT_CONF"
        log "Added include line to $NFT_CONF"
    else
        log "include line already present in $NFT_CONF"
    fi
    ok "nftables rules written"
}
phase_systemd_sysctl() {
    phase 6 "systemd drop-in + sysctl"
    mkdir -p "$(dirname "$SYSTEMD_DROPIN")"
    backup_file "$SYSTEMD_DROPIN"
    cat > "$SYSTEMD_DROPIN" << 'EOF'
[Service]
# ip policy routing for UDP tproxy: fwmark 1 -> table 100 -> route via loopback
ExecStartPre=/bin/sh -c 'ip rule add fwmark 1 table 100 2>/dev/null || true'
ExecStartPre=/bin/sh -c 'ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true'
ExecStopPost=/bin/sh -c 'ip rule del fwmark 1 table 100 2>/dev/null || true'
ExecStopPost=/bin/sh -c 'ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true'
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=false
EOF
    systemctl daemon-reload
    log "systemd drop-in written"

    backup_file "$SYSCTL_FILE"
    cat > "$SYSCTL_FILE" << 'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.lo.rp_filter = 0
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null
    ok "systemd + sysctl configured"
}
phase_helpers_cron() {
    phase 7 "Helpers + cron"

    cat > /usr/local/bin/xray-on << 'EOF'
#!/bin/bash
set -e
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo xray-on)" >&2; exit 1; }
echo "=== Enabling xray transparent proxy ==="
nft delete table inet xray_tproxy 2>/dev/null || true
nft -f /etc/nftables.d/xray-tproxy.nft
systemctl start xray
echo "--- Status ---"
printf "  xray service:   %s\n" "$(systemctl is-active xray)"
EOF
    chmod +x /usr/local/bin/xray-on

    cat > /usr/local/bin/xray-off << 'EOF'
#!/bin/bash
set -e
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo xray-off)" >&2; exit 1; }
echo "=== Disabling xray transparent proxy (all traffic direct) ==="
systemctl stop xray
nft delete table inet xray_tproxy 2>/dev/null || true
echo "--- Status ---"
printf "  xray service:   %s\n" "$(systemctl is-active xray 2>&1 || true)"
printf "  ip fwmark rule: %s\n" "$(ip rule show | grep 'fwmark 0x1' | xargs || echo 'none — clean')"
EOF
    chmod +x /usr/local/bin/xray-off
    log "Installed xray-on / xray-off helpers"

    cat > "$CRON_FILE" << 'EOF'
#!/bin/bash
set -e
ASSET=/usr/local/share/xray
wget -q -O "${ASSET}/geosite.dat" \
  https://github.com/runetfreedom/russia-blocked-geosite/releases/latest/download/geosite.dat
wget -q -O "${ASSET}/geoip.dat" \
  https://github.com/runetfreedom/russia-blocked-geoip/releases/latest/download/geoip.dat
kill -SIGHUP "$(pgrep -x xray)" 2>/dev/null || true
EOF
    chmod +x "$CRON_FILE"
    ok "Helpers + daily geo cron installed"
}
phase_enable_start()    { :; }
phase_verify()          { :; }
do_uninstall()          { :; }

main() {
    parse_args "$@"
    if [[ "$MODE" == "uninstall" ]]; then
        do_uninstall
        return
    fi
    phase_preflight
    collect_inputs
    phase_install_xray
    phase_geo_files
    phase_config
    phase_nftables
    phase_systemd_sysctl
    phase_helpers_cron
    phase_enable_start
    phase_verify
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
