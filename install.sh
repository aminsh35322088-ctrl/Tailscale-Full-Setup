#!/usr/bin/env bash
set -Eeuo pipefail

# Tailscale Full Setup - interactive quick tools
# Auth keys are requested interactively and never stored here.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info(){ echo -e "${CYAN}$*${NC}"; }
ok(){ echo -e "${GREEN}✓ $*${NC}"; }
warn(){ echo -e "${YELLOW}! $*${NC}"; }
die(){ echo -e "${RED}✗ $*${NC}"; return 1; }
require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash install.sh"; return 1; }; }

installed(){ command -v tailscale >/dev/null 2>&1; }
connected(){ installed && tailscale status >/dev/null 2>&1 && [[ -n "$(tailscale ip -4 2>/dev/null || true)$(tailscale ip -6 2>/dev/null || true)" ]]; }

install_ts(){
  require_root || return 1
  if installed; then
    ok "Tailscale already installed: $(tailscale version | head -n1)"
    systemctl enable --now tailscaled >/dev/null 2>&1 || true
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install -y curl; }
  info "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable --now tailscaled
  ok "Tailscale installed: $(tailscale version | head -n1)"
}

ensure_ts(){
  if ! installed; then
    warn "Tailscale is not installed. Installing it now..."
    install_ts || return 1
  else
    systemctl enable --now tailscaled >/dev/null 2>&1 || true
  fi
}

join_if_needed(){
  ensure_ts || return 1
  if connected; then return 0; fi
  echo
  read -r -s -p "Tailscale Auth Key: " key
  echo
  [[ -n "$key" ]] || { warn "Auth key is empty."; return 1; }
  tailscale up --auth-key="$key" --accept-dns=false
  unset key
  connected || { warn "Join completed but no Tailscale IP was detected."; return 1; }
  ok "Joined Tailnet"
}

setup_forwarding(){
  require_root || return 1
  cat >/etc/sysctl.d/99-tailscale-exit.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
  sysctl --system >/dev/null
  ok "IPv4 + IPv6 forwarding enabled"
}

setup_exit(){
  require_root || return 1
  ensure_ts || return 1
  setup_forwarding || return 1
  join_if_needed || return 1
  tailscale set --advertise-exit-node
  tailscale set --advertise-tags=tag:exit
  ok "Exit Node configured with tag:exit"
  tailscale status || true
}

setup_ssh(){
  require_root || return 1
  join_if_needed || return 1
  tailscale set --ssh
  ok "Tailscale SSH enabled"
}

get_peers(){
  tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); me=d.get("Self",{}).get("TailscaleIPs",[]); [print(p.get("TailscaleIPs",[""])[0], p.get("HostName",p.get("DNSName","peer"))) for p in d.get("Peer",{}).values() if p.get("TailscaleIPs") and p.get("TailscaleIPs",[""])[0] not in me]' 2>/dev/null || true
}

ping_test(){
  join_if_needed || return 1
  local count=0 direct=0 derp=0
  info "Testing Tailnet peers..."
  while read -r ip name; do
    [[ -n "$ip" ]] || continue
    count=$((count+1))
    echo
    echo "--- $name ($ip) ---"
    local out
    out="$(tailscale ping --c=3 "$ip" 2>&1 || true)"
    echo "$out"
    if grep -q 'via .*:' <<<"$out" && ! grep -q 'via DERP' <<<"$out"; then direct=$((direct+1)); fi
    if grep -q 'via DERP' <<<"$out"; then derp=$((derp+1)); fi
  done < <(get_peers)
  echo
  [[ $count -gt 0 ]] || warn "No other Tailnet peers found."
  info "Summary: $direct Direct / $derp DERP / $count peers"
}

netcheck(){ join_if_needed || return 1; tailscale netcheck; }

public_ip(){
  local v4 v6
  v4="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  v6="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  echo "Public IPv4 : ${v4:-Unavailable}"
  echo "Public IPv6 : ${v6:-Unavailable}"
}

exit_ip_test(){
  ensure_ts || return 1
  info "Current machine public IPs (use this while traffic is routed through an Exit Node):"
  public_ip
}

health(){
  join_if_needed || return 1
  echo
  info "=== Exit Node Health ==="
  systemctl is-active --quiet tailscaled && ok "Tailscale service: active" || warn "Tailscale service: not active"
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && ok "IPv4 forwarding: enabled" || warn "IPv4 forwarding: disabled"
  [[ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" == "1" ]] && ok "IPv6 forwarding: enabled" || warn "IPv6 forwarding: disabled"
  tailscale set --advertise-exit-node >/dev/null 2>&1 || true
  info "Advertised capabilities:"
  tailscale status >/dev/null 2>&1 && ok "Tailnet connection: active" || warn "Tailnet connection: unavailable"
  echo
  public_ip
}

mtu_test(){
  ensure_ts || return 1
  local target
  read -r -p "Peer Tailscale IP (e.g. 100.x.x.x): " target
  [[ "$target" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "Invalid Tailscale IPv4."; return 1; }
  info "Testing path MTU with ping payloads..."
  local size
  for size in 1472 1400 1300 1200; do
    if ping -c 2 -W 2 -M do -s "$size" "$target" >/dev/null 2>&1; then
      ok "Payload $size bytes: OK"
    else
      warn "Payload $size bytes: failed"
    fi
  done
}

dns_test(){
  info "=== DNS Test ==="
  if command -v resolvectl >/dev/null 2>&1; then resolvectl status 2>/dev/null | head -n 35; else cat /etc/resolv.conf; fi
  echo
  for host in controlplane.tailscale.com tailscale.com; do
    if getent ahosts "$host" >/dev/null 2>&1; then ok "$host resolves"; else warn "$host does not resolve"; fi
  done
}

status(){
  join_if_needed || return 1
  echo; info "=== Tailscale Status ==="; tailscale status || true
  echo; info "=== Tailscale IPs ==="; tailscale ip -4 2>/dev/null || true; tailscale ip -6 2>/dev/null || true
  echo; info "=== Netcheck ==="; tailscale netcheck 2>/dev/null || true
  echo; info "=== Public IP ==="; public_ip
}

benchmark(){
  join_if_needed || return 1
  echo; info "=== VPS Quick Benchmark ==="
  echo "Hostname    : $(hostname)"
  public_ip
  echo "Tailscale IPv4: $(tailscale ip -4 2>/dev/null || echo Unavailable)"
  echo "Tailscale IPv6: $(tailscale ip -6 2>/dev/null || echo Unavailable)"
  echo
  info "Network"
  tailscale netcheck 2>/dev/null || true
  echo
  info "Peer connectivity"
  ping_test || true
  echo
  info "Exit Node health"
  health || true
}

remove_node(){
  require_root || return 1
  ensure_ts || return 1
  echo; warn "This logs the device out of the Tailnet."
  read -r -p "Type YES to confirm: " confirm
  [[ "$confirm" == "YES" ]] || { echo "Cancelled."; return 0; }
  tailscale logout || true
  ok "Device logged out"
}

uninstall_ts(){
  require_root || return 1
  echo; warn "This removes Tailscale packages and local configuration."
  read -r -p "Type UNINSTALL to confirm: " confirm
  [[ "$confirm" == "UNINSTALL" ]] || { echo "Cancelled."; return 0; }
  tailscale logout >/dev/null 2>&1 || true
  if command -v apt-get >/dev/null 2>&1; then apt-get remove -y tailscale || true; apt-get autoremove -y || true; fi
  rm -f /etc/sysctl.d/99-tailscale-exit.conf
  sysctl --system >/dev/null 2>&1 || true
  ok "Tailscale removed"
}

menu(){
  clear 2>/dev/null || true
  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║          Tailscale Full Setup            ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo
  echo "  1) Install Tailscale"
  echo "  2) Setup Exit Node (IPv4 + IPv6)"
  echo "  3) Enable Tailscale SSH"
  echo "  4) Ping / Direct-DERP Test"
  echo "  5) Network Benchmark (netcheck)"
  echo "  6) Show Status + Public IP"
  echo "  7) Logout / Remove This Device"
  echo "  8) Exit IP Test"
  echo "  9) Exit Node Health Check"
  echo " 10) MTU Test"
  echo " 11) DNS Test"
  echo " 12) Full VPS Benchmark"
  echo " 13) Uninstall Tailscale"
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
    8) exit_ip_test ;;
    9) health ;;
    10) mtu_test ;;
    11) dns_test ;;
    12) benchmark ;;
    13) uninstall_ts ;;
    0) exit 0 ;;
    *) warn "Invalid option" ;;
  esac
  echo
  read -r -p "Press Enter to return to menu..." _
  menu
}

require_root || exit 1
menu
