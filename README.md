# xray-reality-gateway

One-line installer that turns a clean **Ubuntu 22.04** box into a transparent-proxy
gateway: traffic to blocked / selected domains is routed through a **VLESS+Reality**
VPN (xray), everything else goes direct. LAN clients need no configuration.

## Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/Ngobo/xray-reality-gateway/main/install.sh)
```

`bash <(...)` is required (not `curl | bash`): the installer is interactive and needs the
terminal as stdin.

The script installs xray v26.6.1, downloads runetfreedom geo data, generates the xray
config from your VLESS URI, sets up nftables tproxy + ip policy routing, installs the
`xray-on`/`xray-off` toggles and a daily geo-update cron, then starts everything and runs
connectivity checks.

## Prompts

| Prompt | Default | Notes |
|---|---|---|
| VLESS+Reality URI | — | `vless://UUID@HOST:PORT?...` from your 3x-ui panel. Required. |
| LAN interfaces | auto-detected | Comma-separated; bridges + `amn*`/`wg*` are detected. |
| WireGuard exempt UDP ports | `44781,36916` | Blank to skip (boxes without AmneziaWG). |
| TCP tproxy port | `12345` | |
| UDP tproxy port | `12346` | |
| config path | `/usr/local/etc/xray/config.json` | |

Nothing is changed until you confirm the summary with `y`.

## What it creates / modifies

- `/usr/local/bin/xray` + `/usr/local/share/xray/{geosite,geoip}.dat`
- `/usr/local/etc/xray/config.json`
- `/etc/nftables.d/xray-tproxy.nft` and an `include` line in `/etc/nftables.conf`
- `/etc/systemd/system/xray.service.d/tproxy.conf`
- `/etc/sysctl.d/99-xray-tproxy.conf`
- `/etc/cron.daily/update-runetfreedom-geodata`
- `/usr/local/bin/xray-on`, `/usr/local/bin/xray-off`

Existing files are backed up to `<file>.bak` before being overwritten. The installer is
idempotent — safe to re-run to swap the URI.

## Toggle the proxy

```bash
sudo xray-off   # all traffic direct (stops xray, flushes nftables)
sudo xray-on    # re-enable
```

## Add custom domains later

Edit the second routing rule's `domain` array in `/usr/local/etc/xray/config.json`, add
`"domain:example.com"`, then `sudo systemctl reload xray`.

## Uninstall

```bash
# Full revert (removes xray, geo files, config, all plumbing):
bash <(curl -sL https://raw.githubusercontent.com/Ngobo/xray-reality-gateway/main/install.sh) --uninstall

# Tear down only the tproxy plumbing, keep xray binary + config:
bash <(curl -sL https://raw.githubusercontent.com/Ngobo/xray-reality-gateway/main/install.sh) --uninstall --keep-xray
```

Uninstall removes the default config path (`/usr/local/etc/xray/config.json`). If you
installed to a custom path, remove it manually. `.bak` backups are reported, not
auto-restored.

## WireGuard clients

Set client `DNS` to your gateway's LAN IP (e.g. `192.168.0.1`), **not** `1.1.1.1`/`8.8.8.8`
— Russian ISPs block UDP 53 to external resolvers.

## Security

Your VLESS URI is entered at runtime and written only to the local config on your gateway.
It is never sent anywhere or committed to this repo, so the repo is safe to be public.

## License

MIT — see [LICENSE](LICENSE).
