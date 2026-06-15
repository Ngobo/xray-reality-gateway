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
phase_preflight()       { :; }
phase_install_xray()    { :; }
phase_geo_files()       { :; }
phase_config()          { :; }
phase_nftables()        { :; }
phase_systemd_sysctl()  { :; }
phase_helpers_cron()    { :; }
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
