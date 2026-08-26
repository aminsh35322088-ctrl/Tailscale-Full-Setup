#!/usr/bin/env bash
set -Eeuo pipefail

# Tailscale Full Setup - interactive quick tools
# No auth key is stored in this repository.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info(){ echo -e "${CYAN}$*${NC}"; }
ok(){ echo -e "${GREEN}✓ $*${NC}"; }
warn(){ echo -e "${YELLOW}! $*${NC}"; }
die(){ echo -e "${RED}✗ $*${NC}"; exit 1; }

require_root(){ [[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"; }

install_ts(){
  require_root
  if command -v tailscale >/dev/null 2>&1; then
    ok "Tailscale is already installed: $(tailscale version | head -n1)"
    systemctl enable --now tailscaled >/dev/null 2>&1 || true
    return
  fi
  info "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable --now tailscaled
  ok "Tailscale installed: $(tailscale version | head -n1)"
}

ensure_ts(){ command -v tailscale >/dev/null 2>&1 || { warn "Tailscale is not installed."; install_ts; }; }

setup_forwarding(){
  require_root
  cat >/etc/sysctl.d/99-tailscale-exit.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
  sysctl --system >/dev/null
  ok "IPv4 + IPv6 forwarding enabled"
}

setup_exit(){
  require_root; ensure_ts; systemctl enable --now tailscaled >/dev/null 2>&1 || true
  setup_forwarding

  local key
  if tailscale status >/dev/null 2>&1; then
    info "Tailscale is already connected."
    tailscale set --advertise-exit-node
    tailscale set --advertise-tags=tag:exit || true
  else
    read -r -s -p "Tailscale Auth Key: " key
    echo
    [[ -n "$key" ]] || die "Auth key is empty"
    tailscale up --auth-key="$key" --advertise-exit-node --advertise-tags=tag:exit --accept-dns=false
    unset key
  fi
  ok "Exit Node configured (tag:exit)"
  tailscale status || true
}

setup_ssh(){
  require_root; ensure_ts
  tailscale set --ssh
  ok "Tailscale SSH enabled"
}

ping_test(){
  ensure_ts
  tailscale status >/tmp/ts-status.$$ 2>&1 || die "Tailscale is not connected."
  info "Testing Tailnet peers..."
  awk '/100\.[0-9]+\.[0-9]+\.[0-9]+/ {print $1}' /tmp/ts-status.$$ | while read -r ip; do
    [[ -n "$ip" ]] || continue
    echo "--- $ip ---"
    tailscale ping --c=3 "$ip" 2>&1 || true
  done
  rm -f /tmp/ts-status.$$
}

netcheck(){ ensure_ts; tailscale netcheck; }

status(){
  ensure_ts
  echo
  info "=== Tailscale Status ==="
  tailscale status || true
  echo
  info "=== Tailscale IPs ==="
  tailscale ip -4 2>/dev/null || true
  tailscale ip -6 2>/dev/null || true
  echo
  info "=== Netcheck ==="
  tailscale netcheck 2>/dev/null || true
}

remove_node(){
  ensure_ts
  echo
  warn "This will disconnect this machine from the Tailnet."
  read -r -p "Type YES to confirm: " confirm
  [[ "$confirm" == "YES" ]] || { echo "Cancelled."; return; }
  tailscale logout || true
  ok "Device logged out from Tailscale"
}

menu(){
  clear 2>/dev/null || true
  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║          Tailscale Full Setup            ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo
  echo "  1) Install / Update Tailscale"
  echo "  2) Setup Exit Node (tag:exit)"
  echo "  3) Enable Tailscale SSH"
  echo "  4) Ping / Direct-DERP Test"
  echo "  5) Network Benchmark (netcheck)"
  echo "  6) Show Tailscale Status"
  echo "  7) Logout / Remove This Device"
  echo "  0) Exit"
  echo
  read -r -p "Select an option: " choice
  case "$choice" in
    1) install_ts ;;
    2) setup_exit ;;
    3) setup_ssh ;;
    4) ping_test ;;
    5) netcheck ;;
    6) status ;;
    7) remove_node ;;
    0) exit 0 ;;
    *) warn "Invalid option" ;;
  esac
  echo
  read -r -p "Press Enter to return to menu..." _
  menu
}

require_root
menu
