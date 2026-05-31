# noctalia-iwd

Drop-in iwd backend for [Noctalia Shell](https://github.com/noctalia-dev/noctalia-shell) v4. Replaces the NetworkManager/nmcli dependency with [iwd](https://iwd.wiki.kernel.org/) — Intel's wireless daemon.

Everything works: wifi toggle, network scanning, connect/disconnect, forget, signal strength, connection details, connectivity checks, real-time state monitoring. The existing Noctalia UI (bar widget, control center, network panel) stays untouched.

## Why

NetworkManager is bloated, slow, and wraps wpa_supplicant which is also bloated and slow. iwd replaces both with a single daemon that connects faster and uses less memory. If you've already ditched NetworkManager, Noctalia's network widgets break because they shell out to `nmcli`. This fixes that.

## Requirements

- [Noctalia Shell](https://github.com/noctalia-dev/noctalia-shell) v4.x
- [iwd](https://wiki.archlinux.org/title/Iwd) (running, configured)
- `busctl` (systemd — you already have this)
- `python3` (stdlib only, no pip packages)
- `iw` (optional, for signal strength / link rate / band info)
- `curl` (optional, for connectivity checks)

## Install

```bash
git clone https://github.com/youruser/noctalia-iwd
cd noctalia-iwd
./install.sh
```

The installer:
1. Drops `iwd-helper` into `/usr/local/bin/`
2. Backs up the original `NetworkService.qml` to `NetworkService.qml.nmcli.bak`
3. Replaces it with the iwd version

Restart Noctalia after installing.

## Uninstall

```bash
./uninstall.sh
```

Restores the original NetworkManager backend from backup.

## iwd standalone setup

If you're running iwd without NetworkManager (recommended), configure `/etc/iwd/main.conf`:

```ini
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=systemd
```

Then:

```bash
sudo systemctl enable --now iwd
sudo systemctl enable --now systemd-resolved
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
```

## How it works

Two files:

**`iwd-helper`** — Python3 script (no dependencies beyond stdlib) that talks to iwd's D-Bus API via `busctl` and returns JSON. Subcommands: `status`, `scan`, `profiles`, `connect`, `disconnect`, `forget`, `connectivity`, `set-powered`. You can test each one directly from a terminal.

**`NetworkService.qml`** — Same public API as Noctalia's original. Every property and function signature is identical so the bar widget, control center widget, and network panel work without modification. Internally, all `nmcli` Process elements are replaced with `iwd-helper` calls, stdout parsing uses `JSON.parse()` instead of regex on nmcli's terse output, and `wifiEnabled` is sourced from iwd's `Device.Powered` property instead of `Quickshell.Networking` (which depends on NetworkManager).

The `import Quickshell.Networking` is removed entirely — it requires NetworkManager to function.

State changes are detected via `dbus-monitor` watching iwd's `PropertiesChanged` signals, with a 5-second poller as fallback.

## Testing the helper standalone

```bash
# Full device status
iwd-helper status

# Scan for networks
iwd-helper scan

# List saved profiles
iwd-helper profiles

# Check internet connectivity
iwd-helper connectivity

# Connect to a network
iwd-helper connect "MyNetwork" --password "hunter2"

# Disconnect
iwd-helper disconnect

# Forget a saved network
iwd-helper forget "MyNetwork"

# Toggle wifi
iwd-helper set-powered true
iwd-helper set-powered false
```

## Known limitations

- **Enterprise auth (802.1x)**: iwd handles this via provisioning files in `/var/lib/iwd/`, not CLI arguments. You need to create the `.8021x` file manually before connecting. The connect flow works for PSK/open networks.
- **Signal/rate/band**: Requires `iw` package. Without it, these fields are empty (cosmetic only).
- **Connectivity check**: Uses `curl` to hit Google's connectivity endpoint. Without `curl`, reports "unknown".
- **Noctalia v5**: This targets v4 only. v5 is a full C++ rewrite with its own networking stack.

## License

MIT
