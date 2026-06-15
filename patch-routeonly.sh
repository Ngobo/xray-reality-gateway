#!/usr/bin/env bash
#
# patch-routeonly.sh — patch an ALREADY-DEPLOYED gateway so LAN VLESS/Reality clients
# can tunnel through it. Adds "routeOnly": true to the TCP transparent inbound's sniffing
# block in the live xray config and reloads xray. Does NOT touch your VLESS URI / outbound.
#
# Idempotent: safe to run repeatedly. Backs up the config to <config>.bak before editing.
#
# Run on the gateway:
#   sudo bash <(curl -sL https://raw.githubusercontent.com/Ngobo/xray-reality-gateway/main/patch-routeonly.sh)
# Or with a non-default config path:
#   sudo ./patch-routeonly.sh /path/to/config.json
#
set -euo pipefail

CONFIG="${1:-/usr/local/etc/xray/config.json}"

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 1; }

result="$(python3 - "$CONFIG" <<'PY'
import json, sys, shutil

path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

changed = False
for ib in cfg.get("inbounds", []):
    sn = ib.get("sniffing")
    # The TCP transparent inbound is the one with sniffing + destOverride.
    if isinstance(sn, dict) and sn.get("enabled") and "destOverride" in sn:
        if sn.get("routeOnly") is not True:
            sn["routeOnly"] = True
            changed = True

if changed:
    shutil.copy2(path, path + ".bak")
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print("PATCHED")
else:
    print("ALREADY_SET")
PY
)"

case "$result" in
    PATCHED)
        echo "Patched $CONFIG (backup: ${CONFIG}.bak)"
        # Validate the result before reloading.
        python3 -m json.tool "$CONFIG" >/dev/null || { echo "Patched config is invalid JSON — restoring backup." >&2; mv -f "${CONFIG}.bak" "$CONFIG"; exit 1; }
        if systemctl reload xray 2>/dev/null || systemctl restart xray; then
            echo "xray reloaded. routeOnly is now active."
        else
            echo "Config patched but xray reload/restart failed — check 'journalctl -u xray'." >&2
            exit 1
        fi
        ;;
    ALREADY_SET)
        echo "routeOnly already set — nothing to do."
        ;;
    *)
        echo "Unexpected result: $result" >&2
        exit 1
        ;;
esac

echo "xray service: $(systemctl is-active xray)"
