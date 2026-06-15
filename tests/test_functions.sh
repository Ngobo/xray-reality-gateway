#!/usr/bin/env bash
# Unit tests for pure functions in install.sh. Run: bash tests/test_functions.sh
set -uo pipefail
cd "$(dirname "$0")/.."

# Source install.sh without executing main (strip the main-guard).
# shellcheck disable=SC1090
source <(sed '/^if \[\[ "${BASH_SOURCE/,/^fi$/d' install.sh)

fail=0
check() {  # check <desc> <actual> <expected>
    if [[ "$2" == "$3" ]]; then
        echo "  ok: $1"
    else
        echo "  FAIL: $1 — got '$2', want '$3'"; fail=1
    fi
}

# --- urldecode ---
check "urldecode percent" "$(urldecode 'a%2Fb')" "a/b"
check "urldecode plus"    "$(urldecode 'a+b')"   "a b"

# --- parse_vless ---
parse_vless 'vless://uuid-1@203.0.113.7:443?security=reality&pbk=KEY&fp=chrome&sni=www.microsoft.com&sid=ab12&flow=xtls-rprx-vision#vps'
check "parse uuid"  "$P_UUID"   "uuid-1"
check "parse host"  "$P_HOST"   "203.0.113.7"
check "parse port"  "$P_PORT"   "443"
check "parse pbk"   "$P_PBK"    "KEY"
check "parse sid"   "$P_SID"    "ab12"
check "parse sni"   "$P_SNI"    "www.microsoft.com"
check "parse flow"  "$P_FLOW"   "xtls-rprx-vision"
check "parse fp"    "$P_FP"     "chrome"

# sni falls back to host= param; flow/fp default
parse_vless 'vless://u2@example.com:8443?pbk=K2&sid=cd34&host=cloudflare.com'
check "sni fallback"   "$P_SNI"  "cloudflare.com"
check "flow default"   "$P_FLOW" "xtls-rprx-vision"
check "fp default"     "$P_FP"   "chrome"

# --- detect_lan_ifaces (with stubbed _list_candidate_ifaces) ---
_list_candidate_ifaces() { printf '%s\n' "br0" "amn0"; }
check "detect joins ifaces" "$(detect_lan_ifaces)" "br0, amn0"

exit $fail
