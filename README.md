# ⚡ Tailscale Full Setup

Interactive **quick-install + setup + diagnostics toolkit** for Linux VPS and Windows Server machines using Tailscale.

## 🚀 Quick Install

### 🐧 Linux

**Recommended one-line installer:**

```bash
curl -fsSL https://raw.githubusercontent.com/aminsh35322088-ctrl/Tailscale-Full-Setup/main/install.sh | sudo bash
```

> The installer is interactive and requires root privileges. The command above always downloads the current `main` version of `install.sh`, so you do not need to clone the repository first.

### 🪟 Windows Server

Run **PowerShell as Administrator**:

```powershell
irm https://raw.githubusercontent.com/aminsh35322088-ctrl/Tailscale-Full-Setup/main/setup.ps1 | iex
```

The Windows script now refreshes its Tailscale executable path after installation and verifies the installed binary before continuing. It also handles Exit Node tagging through re-authentication instead of trying to use the unsupported `tailscale set --advertise-tags` command.

If PowerShell execution policy blocks the script:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

Then run the Quick Install command again.

> For `tag:exit`, the Auth Key used by the Windows Exit Node setup must be permitted to use that tag in your Tailnet policy. Tailscale tags are part of device identity and cannot be added to an auth-key-authenticated device using `tailscale set`. citeturn0search1turn0search0

---

## 📋 Features / Menu

Both Linux and Windows versions provide the same overall toolkit:

```text
  1) Install Tailscale
  2) Setup Exit Node (IPv4 + IPv6)
  3) Tailscale SSH
  4) Direct / DERP Ping
  5) Network Benchmark (Netcheck)
  6) Status + Public IP
  7) Logout / Remove Device
  8) Exit IP Test
  9) Exit Node Health Check
 10) MTU Test
 11) DNS Test
 12) Full VPS Benchmark
 13) Uninstall Tailscale
  0) Exit
```

### ✅ Detailed checklist

- [x] Install Tailscale
- [x] Verify Tailscale installation and executable path
- [x] Avoid unnecessary reinstall when Tailscale is already installed
- [x] Enable/start the Tailscale service
- [x] Interactive Auth Key input
- [x] Auth Key is not stored in the repository
- [x] Automatically join the Tailnet when required
- [x] Exit Node setup
- [x] `tag:exit` advertisement
- [x] Correct tag-based re-authentication flow for auth-key nodes
- [x] IPv4 forwarding
- [x] IPv6 forwarding on Linux
- [x] Windows IP routing configuration
- [x] Tailscale SSH
- [x] Tailnet peer discovery
- [x] Direct connection detection
- [x] DERP relay detection
- [x] Direct/DERP summary
- [x] `tailscale netcheck`
- [x] Public IPv4 detection
- [x] Public IPv6 detection
- [x] Exit IP test
- [x] Exit Node health check
- [x] MTU test
- [x] DNS test
- [x] Hostname detection
- [x] Tailscale IPv4/IPv6 display
- [x] Full VPS benchmark
- [x] Logout with confirmation
- [x] Uninstall with confirmation
- [x] Linux + Windows Server support

---

## 🧪 What the tests do

### 4 — Direct / DERP Ping

Tests the other Tailnet peers and reports whether the connection is **Direct** or going through a **DERP relay**.

### 5 — Network Benchmark

Runs Tailscale's `netcheck` to inspect UDP availability, IPv4/IPv6 connectivity, NAT behavior, port mapping and nearest DERP region.

### 6 — Status + Public IP

Shows Tailscale peers, Tailscale IPv4/IPv6 addresses, network information and public IP information.

### 8 — Exit IP Test

Shows the current public IPv4/IPv6 addresses. For an actual Exit Node test, run this on a client while the client is using this machine as its Exit Node.

### 9 — Exit Node Health

Checks the Tailscale service, routing configuration, Tailnet connection and public IP information.

### 10 — MTU Test

Tests packet sizes against a selected Tailscale IPv4 peer using DF/fragmentation checks.

### 11 — DNS Test

Shows configured DNS servers and checks resolution of Tailscale-related domains.

### 12 — Full VPS Benchmark

Runs the major diagnostics together:

```text
Public IP
Hostname
Tailscale IPv4 / IPv6
Netcheck
Peer Direct / DERP test
Exit Node health
```

---

## 🏷️ Exit Node / ACL setup

For automatic approval of tagged Exit Nodes, the Tailnet policy can use:

```json
"tagOwners": {
  "tag:exit": ["group:admin"]
},
"autoApprovers": {
  "exitNode": ["tag:exit"],
  "routes": {
    "0.0.0.0/0": ["tag:exit"],
    "::/0": ["tag:exit"]
  }
}
```

The Linux script enables IPv4 and IPv6 forwarding when option **2** is selected. Windows Server uses the Windows `IPEnableRouter` setting for routing. Tailscale recommends using `tailscale up --advertise-tags=...`/re-authentication for tag identity; tags require appropriate tag ownership or an auth key that is authorized for the tag. citeturn0search1turn0search0

For Windows Server deployments that must keep Tailscale available when no interactive user is logged in, enable Tailscale **Run Unattended** mode with:

```powershell
tailscale up --unattended=true
```

This is specifically supported for Windows Server scenarios. citeturn0search6

---

## 🔐 Security

**Never commit a reusable Tailscale Auth Key to this repository.**

The scripts request the key interactively when a machine needs to join the Tailnet. The key is not written to the repository.

If an Auth Key is ever exposed, revoke/rotate it from the Tailscale admin console immediately.

---

## 📁 Repository structure

```text
Tailscale-Full-Setup/
├── install.sh      # Linux
├── setup.ps1       # Windows Server
└── README.md       # Documentation
```

---

## 🔗 Links

- **Repository:** https://github.com/aminsh35322088-ctrl/Tailscale-Full-Setup
- **Linux Quick Install:**
  ```bash
  curl -fsSL https://raw.githubusercontent.com/aminsh35322088-ctrl/Tailscale-Full-Setup/main/install.sh | sudo bash
  ```
- **Windows Server Quick Install:**
  ```powershell
  irm https://raw.githubusercontent.com/aminsh35322088-ctrl/Tailscale-Full-Setup/main/setup.ps1 | iex
  ```
- **Linux script:** https://raw.githubusercontent.com/aminsh35322088-ctrl/Tailscale-Full-Setup/main/install.sh
- **Windows script:** https://raw.githubusercontent.com/aminsh35322088-ctrl/Tailscale-Full-Setup/main/setup.ps1
