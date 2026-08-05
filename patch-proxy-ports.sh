#!/usr/bin/env bash
#
# patch-proxy-ports.sh — patch an ALREADY-DEPLOYED gateway so only the listed TCP/UDP
# ports are intercepted for proxying. Everything else (WireGuard, games, other services)
# then bypasses the tproxy chains entirely and routes normally — no per-destination
# exemption needed. Adds "tcp dport != {...} return" / "udp dport != {...} return" lines
# to the live nftables ruleset and reloads. Does NOT touch your xray config.json.
#
# Idempotent: safe to run repeatedly. Re-running with different TCP_PORTS/UDP_PORTS
# updates the existing scope lines instead of duplicating them. Backs up the nft file
# to <file>.bak before editing.
#
# Run on the gateway (no interactive prompts, so the plain pipe form is fine —
# "sudo bash <(curl ...)" can fail with "/dev/fd/N: No such file or directory"
# because sudo drops fds above stdin/stdout/stderr):
#   curl -sL https://raw.githubusercontent.com/Ngobo/xray-reality-gateway/main/patch-proxy-ports.sh | sudo bash
# Or with custom ports / a non-default nft file:
#   sudo TCP_PORTS=80,443 UDP_PORTS=443 ./patch-proxy-ports.sh /path/to/xray-tproxy.nft
#
set -euo pipefail

NFT_FILE="${1:-/etc/nftables.d/xray-tproxy.nft}"
TCP_PORTS="${TCP_PORTS:-80,443}"
UDP_PORTS="${UDP_PORTS:-443}"

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
[[ -f "$NFT_FILE" ]] || { echo "nft file not found: $NFT_FILE" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 1; }

result="$(python3 - "$NFT_FILE" "$TCP_PORTS" "$UDP_PORTS" <<'PY'
import sys, shutil

path, tcp_ports, udp_ports = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()

tcp_scope = f"        tcp dport != {{ {tcp_ports} }} return\n"
udp_scope = f"        udp dport != {{ {udp_ports} }} return\n"

out = []
changed = False
tcp_found = False
udp_found = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("tcp dport !="):
        tcp_found = True
        if line != tcp_scope:
            line = tcp_scope
            changed = True
        out.append(line)
        continue
    if stripped.startswith("udp dport !="):
        udp_found = True
        if line != udp_scope:
            line = udp_scope
            changed = True
        out.append(line)
        continue
    if stripped.startswith("ip protocol tcp redirect to") and not tcp_found:
        out.append(tcp_scope)
        changed = True
        tcp_found = True
    if stripped.startswith("ip protocol udp tproxy ip to") and not udp_found:
        out.append(udp_scope)
        changed = True
        udp_found = True
    out.append(line)

if changed:
    shutil.copy2(path, path + ".bak")
    with open(path, "w") as f:
        f.writelines(out)
    print("PATCHED")
else:
    print("ALREADY_SET")
PY
)"

case "$result" in
    PATCHED)
        echo "Patched $NFT_FILE (backup: ${NFT_FILE}.bak) — tcp:{$TCP_PORTS} udp:{$UDP_PORTS}"
        if ! nft -c -f "$NFT_FILE"; then
            echo "Patched file failed nft syntax check — restoring backup." >&2
            mv -f "${NFT_FILE}.bak" "$NFT_FILE"
            exit 1
        fi
        if command -v xray-on >/dev/null 2>&1; then
            xray-on
        else
            nft delete table inet xray_tproxy 2>/dev/null || true
            nft -f "$NFT_FILE"
            echo "nftables reloaded."
        fi
        ;;
    ALREADY_SET)
        echo "Proxy-port scope already set to tcp:{$TCP_PORTS} udp:{$UDP_PORTS} — nothing to do."
        ;;
    *)
        echo "Unexpected result: $result" >&2
        exit 1
        ;;
esac

echo "xray service: $(systemctl is-active xray 2>&1 || true)"
nft list chain inet xray_tproxy prerouting_mangle 2>/dev/null | grep -E 'dport !=' || true
