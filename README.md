# ⚡ Tailscale Full Setup

Interactive **quick-install + setup + diagnostics toolkit** for Linux VPS and Windows Server machines using Tailscale.

## 🚀 Quick Install

### 🐧 Linux

Download the installer to a temporary file first, then run it. This avoids piping a live download directly into Bash, gives the download a timeout/retry policy, and keeps the interactive menu attached to your SSH terminal.

```bash
(
  set -eu
  installer="$(mktemp)"
  trap 'rm -f "$installer"' EXIT

  curl -fL --show-error --progress-bar \
    --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 120 \
    -o "$installer" \
    "https://raw.githubusercontent.com/aminsh35322088-ctrl/Tailscale-Full-Setup/main/install.sh"

  sudo bash "$installer"
)
```

### 🪟 Windows Server

Run **PowerShell as Administrator**:

```powershell
irm https://raw.githubusercontent.com/aminsh35322088-ctrl/Tailscale-Full-Setup/main/setup.ps1 | iex
```

## 🏷️ Clean Tailscale Hostnames

The toolkit does **not** use the VPS provider's hostname as the Tailscale device name. On first Tailnet join, it asks for a clean Tailscale hostname and defaults to:

```text
exit-node
```

You can choose a custom name such as `exit-node-finland`, `vps-germany`, or `exit-node-01`. The name is sanitized automatically for Tailscale compatibility, so provider names such as `nex1802392273-8610453` are not used as the Tailscale hostname.

Both Linux and Windows expose **Change Tailscale Hostname** as menu option `14`.

## 📋 Features / Menu

```text
  1) Install Tailscale
  2) Setup Exit Node (IPv4 + IPv6)
  3) Enable Tailscale SSH
  4) Ping / Direct-DERP Test
  5) Network Benchmark (netcheck)
  6) Show Status + Public IP + Location
  7) Logout / Remove This Device
  8) Exit IP Test
  9) Exit Node Health Check
 10) MTU Test
 11) DNS Test
 12) Full VPS Benchmark
 13) Uninstall Tailscale
 14) Change Tailscale Hostname
  0) Exit
```

## 🔐 Security

Never commit a reusable Tailscale Auth Key to this repository. The scripts request keys interactively and do not write them to the repository.

## 📁 Repository structure

```text
Tailscale-Full-Setup/
├── install.sh
├── setup.ps1
└── README.md
```

## 🔗 Links

- Repository: https://github.com/aminsh35322088-ctrl/Tailscale-Full-Setup
- Linux: https://raw.githubusercontent.com/aminsh35322088-ctrl/Tailscale-Full-Setup/main/install.sh
- Windows Server: https://raw.githubusercontent.com/aminsh35322088-ctrl/Tailscale-Full-Setup/main/setup.ps1
