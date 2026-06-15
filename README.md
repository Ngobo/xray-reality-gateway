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

## Why two listeners (TCP via REDIRECT, UDP via TPROXY)

The xray config uses **two** transparent (`dokodemo-door`) inbounds — TCP on `:12345` and
UDP on `:12346` — fed by two different nftables mechanisms. This is deliberate, and it is
the fix for the most common failure people hit when setting up a tproxy gateway on a
recent xray.

### The problem: `failed to set IP_TRANSPARENT: operation not supported`

If you try to send **both** TCP and UDP to a single tproxy inbound, xray logs something
like:

```
[Warning] transport/internet: failed to apply socket options ... IP_TRANSPARENT: operation not supported
```

(`IP_TRANSPARENT > operation not supported`, errno `EOPNOTSUPP`). The transparent inbound
never finishes binding, so all intercepted traffic is dropped and nothing works.

### Why it happens

Linux TPROXY requires the receiving socket to have the `IP_TRANSPARENT` socket option set.
On xray 26.x the **TCP** listener is created as an `AF_INET6` dual-stack socket, and setting
the IPv4-level option `IP_TRANSPARENT` (`SOL_IP`) on an `AF_INET6` socket returns
`EOPNOTSUPP` — the kernel refuses the IPv4 option on an IPv6 socket. (Confirmed with
`strace -f -e trace=setsockopt`.) The **UDP** listener, by contrast, is created as
`AF_INET`, where `IP_TRANSPARENT` succeeds normally.

### The workaround (what this installer does)

Split TCP and UDP onto separate inbounds with different interception mechanisms:

| Protocol | Inbound `sockopt` | nftables mechanism | Needs `IP_TRANSPARENT`? |
|---|---|---|---|
| **TCP** | `"tproxy": "redirect"` (port `12345`) | `redirect` (nat / dstnat hook) | **No** — xray recovers the original destination via `SO_ORIGINAL_DST` |
| **UDP** | `"tproxy": "tproxy"` (port `12346`) | `tproxy` (mangle hook) + fwmark→table 100 | Yes — and it works, because xray's UDP socket is `AF_INET` |

Because TCP goes through nftables `REDIRECT` instead of `TPROXY`, the TCP socket never needs
`IP_TRANSPARENT`, sidestepping the `EOPNOTSUPP` entirely; xray still learns the real
destination through `getsockopt(SO_ORIGINAL_DST)`. UDP keeps real `TPROXY` (the only way to
transparently proxy UDP), which works fine on its `AF_INET` socket. This is exactly the
two-inbound layout in the generated `config.json` and the two-chain layout in
`xray-tproxy.nft`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `IP_TRANSPARENT: operation not supported` in `journalctl -u xray` | A single tproxy inbound is handling TCP; xray's TCP socket is `AF_INET6` and rejects the IPv4 `IP_TRANSPARENT` option | Use the two-inbound split above (TCP `redirect` + UDP `tproxy`). This installer already does this. |
| Direct sites load, proxied sites don't, and `journalctl -u xray` shows nothing while browsing | Missing `sniffing` on the TCP inbound — xray only sees the destination IP, so domain/geosite rules never match | The generated config enables `"sniffing": {"enabled": true, "destOverride": ["http","tls"]}`; if you hand-edited it, restore that. |
| LAN clients can't reach anything but the gateway itself still works | nftables loaded but xray isn't listening | `sudo xray-off` to restore direct routing, then check `journalctl -u xray`. (The installer guards against this by only loading nftables after confirming xray is listening.) |
| WireGuard clients: ping works but DNS fails | ISP blocks UDP 53 to external resolvers | Set client `DNS` to the gateway LAN IP (see below). |

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
