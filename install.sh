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
collect_inputs()        { :; }
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
