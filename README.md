# Tailscale Full Setup

Interactive quick-install and diagnostics toolkit for Linux VPS instances using Tailscale.

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/aminsh35322088-ctrl/Tailscale-Full-Setup/main/install.sh | sudo bash
```

The script does **not** contain or store a Tailscale auth key. The key is requested interactively only when an unauthenticated machine is configured as an Exit Node.

## Menu

1. **Install / Update Tailscale** — installs Tailscale only when it is missing and enables `tailscaled`.
2. **Setup Exit Node** — enables IPv4/IPv6 forwarding, joins the Tailnet when needed, advertises `tag:exit`, and advertises the Exit Node.
3. **Enable Tailscale SSH** — enables Tailscale SSH on the machine.
4. **Ping / Direct-DERP Test** — tests Tailnet peers with `tailscale ping`.
5. **Network Benchmark** — runs `tailscale netcheck`.
6. **Show Status** — shows peers, Tailscale IPv4/IPv6 addresses and network information.
7. **Logout / Remove This Device** — disconnects the local machine after an explicit `YES` confirmation.

## Exit Node requirements

The Tailnet policy should permit the `tag:exit` tag and automatically approve Exit Nodes/routes. A typical policy uses:

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

The Linux host also needs IPv4 and IPv6 forwarding enabled; option 2 configures these automatically.

## Security

Never commit a reusable Tailscale auth key to this repository. If a key is exposed, revoke/rotate it from the Tailscale admin console immediately.
