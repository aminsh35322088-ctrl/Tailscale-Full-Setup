#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info(){ echo -e "${CYAN}$*${NC}"; }
ok(){ echo -e "${GREEN}✓ $*${NC}"; }
warn(){ echo -e "${YELLOW}! $*${NC}"; }
fail(){ echo -e "${RED}✗ $*${NC}"; }
require_root(){ [[ $EUID -eq 0 ]] || { fail "Run as root: sudo bash install.sh"; return 1; }; }

tailscale_bin(){
  local p
  p="$(command -v tailscale 2>/dev/null || true)"
  if [[ -n "$p" && -x "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  for p in /usr/bin/tailscale /usr/sbin/tailscale /bin/tailscale /sbin/tailscale; do
    if [[ -x "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
}
installed(){ tailscale_bin >/dev/null 2>&1; }
TS_BIN=''
resolve_ts(){ TS_BIN="$(tailscale_bin)"; }
service_up(){ systemctl enable --now tailscaled >/dev/null 2>&1 || true; }
connected(){
  installed || return 1
  resolve_ts || return 1
  service_up
  [[ -n "$($TS_BIN ip -4 2>/dev/null || true)$($TS_BIN ip -6 2>/dev/null || true)" ]]
}

install_ts(){
  require_root || return 1
  if installed; then
    resolve_ts; service_up
    ok "Tailscale already installed: $($TS_BIN version | head -n1)"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { command -v apt-get >/dev/null 2>&1 || { fail "curl is required and automatic installation is only supported on apt systems."; return 1; }; apt-get update -y && apt-get install -y curl; }
  info "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
  hash -r 2>/dev/null || true
  if ! installed; then fail "Tailscale installer completed but the tailscale binary was not found."; return 1; fi
  resolve_ts; service_up
  if ! "$TS_BIN" version >/dev/null 2>&1; then fail "Tailscale binary was found at $TS_BIN but could not execute."; return 1; fi
  ok "Tailscale installed: $($TS_BIN version | head -n1)"
}

ensure_ts(){ if ! installed; then install_ts || return 1; else resolve_ts; service_up; fi; }

clean_hostname(){
  local raw cleaned
  raw="${1:-}"
  cleaned="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g' | cut -c1-63)"
  [[ -n "$cleaned" ]] || cleaned='exit-node'
  printf '%s\n' "$cleaned"
}

set_hostname(){
  ensure_ts || return 1
  local current default_name requested name
  current="$(hostname 2>/dev/null || true)"
  default_name='exit-node'
  echo
  info "Tailscale device name is separate from the VPS provider hostname."
  echo "Current VPS hostname: ${current:-unknown}"
  read -r -p "Tailscale hostname [${default_name}]: " requested
  requested="${requested:-$default_name}"
  name="$(clean_hostname "$requested")"
  if "$TS_BIN" set --hostname="$name"; then
    ok "Tailscale hostname: $name"
    return 0
  fi
  warn "Could not set Tailscale hostname with 'set'; retrying with 'up'."
  "$TS_BIN" up --hostname="$name" --accept-dns=false >/dev/null && ok "Tailscale hostname: $name" || { fail "Could not set Tailscale hostname."; return 1; }
}

join_if_needed(){
  ensure_ts || return 1
  if connected; then return 0; fi
  echo
  read -r -s -p "Tailscale Auth Key: " key; echo
  [[ -n "$key" ]] || { warn "Auth key is empty."; return 1; }
  if ! "$TS_BIN" up --auth-key="$key" --accept-dns=false; then unset key; fail "Tailscale join failed. Check the auth key and network connectivity."; return 1; fi
  unset key
  connected || { fail "Join command completed but no Tailscale IP was detected."; return 1; }
  ok "Joined Tailnet"
  set_hostname || true
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

has_exit_tag(){ "$TS_BIN" status --json 2>/dev/null | grep -q 'tag:exit'; }
apply_exit_tag(){
  echo
  read -r -s -p "Tailscale Auth Key (required to apply tag:exit): " key; echo
  [[ -n "$key" ]] || { warn "Auth key is empty."; return 1; }
  "$TS_BIN" logout >/dev/null 2>&1 || true
  if ! "$TS_BIN" up --auth-key="$key" --advertise-tags=tag:exit --advertise-exit-node --accept-dns=false; then unset key; fail "Could not authenticate with tag:exit and advertise the Exit Node."; fail "Make sure the auth key is allowed to use tag:exit and tagOwners permits it."; return 1; fi
  unset key
  has_exit_tag || { fail "Tailscale authenticated successfully, but tag:exit is not present in local state."; return 1; }
  ok "tag:exit applied during authentication"
  set_hostname || true
}
setup_exit(){
  require_root || return 1; ensure_ts || return 1; setup_forwarding || return 1; join_if_needed || return 1
  if ! has_exit_tag; then warn "This node is connected but is not tagged tag:exit. Re-authentication is required to apply the tag."; apply_exit_tag || return 1; fi
  "$TS_BIN" set --advertise-exit-node=true || { fail "Could not advertise Exit Node."; return 1; }
  "$TS_BIN" status >/dev/null 2>&1 || { fail "Tailscale status check failed after Exit Node configuration."; return 1; }
  ok "Exit Node configured with tag:exit"; "$TS_BIN" status || true
}
setup_ssh(){ require_root || return 1; join_if_needed || return 1; if "$TS_BIN" set --ssh; then ok "Tailscale SSH enabled"; else fail "Could not enable Tailscale SSH"; return 1; fi; }
get_peers(){ command -v python3 >/dev/null 2>&1 || { warn "python3 is required for peer discovery."; return 0; }; "$TS_BIN" status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); me=set(d.get("Self",{}).get("TailscaleIPs",[]));
for p in d.get("Peer",{}).values():
 ips=p.get("TailscaleIPs",[]); ip=next((x for x in ips if x.startswith("100.")),None)
 if ip and ip not in me: print(ip, p.get("HostName") or p.get("DNSName") or "peer")' 2>/dev/null || true; }
ping_test(){ join_if_needed || return 1; local count=0 direct=0 derp=0 failed=0; info "Testing Tailnet peers..."; while read -r ip name; do [[ -n "$ip" ]] || continue; count=$((count+1)); echo "--- $name ($ip) ---"; local out; out="$("$TS_BIN" ping --c=3 "$ip" 2>&1 || true)"; echo "$out"; if grep -q 'via DERP' <<<"$out"; then derp=$((derp+1)); elif grep -Eq 'via [0-9a-fA-F:]+:[0-9]+' <<<"$out"; then direct=$((direct+1)); else failed=$((failed+1)); fi; done < <(get_peers); echo; [[ $count -gt 0 ]] || warn "No other Tailnet peers found."; info "Summary: $direct Direct / $derp DERP / $failed Failed / $count peers"; }
netcheck(){ join_if_needed || return 1; "$TS_BIN" netcheck; }
public_ip(){ command -v curl >/dev/null 2>&1 || { warn "curl is required for public IP tests."; return 0; }; local v4 v6; v4="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"; v6="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"; echo "Public IPv4 : ${v4:-Unavailable}"; echo "Public IPv6 : ${v6:-Unavailable}"; }
location_info(){ command -v curl >/dev/null 2>&1 || return 0; local json country city region; json="$(curl -4 -fsS --max-time 5 https://ipinfo.io/json 2>/dev/null || true)"; if [[ -n "$json" ]] && command -v python3 >/dev/null 2>&1; then read -r country region city < <(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("country","-"),d.get("region","-"),d.get("city","-"))' 2>/dev/null || true); echo "Location    : ${city:--}, ${region:--}, ${country:--}"; else echo "Location    : Unavailable"; fi; }
exit_ip_test(){ ensure_ts || return 1; public_ip; }
health(){ join_if_needed || return 1; echo; info "=== Exit Node Health ==="; systemctl is-active --quiet tailscaled && ok "Tailscale service: active" || warn "Tailscale service: not active"; [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && ok "IPv4 forwarding: enabled" || warn "IPv4 forwarding: disabled"; [[ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" == "1" ]] && ok "IPv6 forwarding: enabled" || warn "IPv6 forwarding: disabled"; "$TS_BIN" status >/dev/null 2>&1 && ok "Tailnet connection: active" || warn "Tailnet connection: unavailable"; has_exit_tag && ok "tag:exit: present" || warn "tag:exit: not present"; echo; public_ip; }
mtu_test(){ ensure_ts || return 1; command -v ping >/dev/null 2>&1 || { warn "ping is not installed."; return 1; }; local target; read -r -p "Peer Tailscale IPv4 (e.g. 100.x.x.x): " target; [[ "$target" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "Invalid Tailscale IPv4."; return 1; }; for size in 1472 1400 1300 1200; do ping -c 2 -W 2 -M do -s "$size" "$target" >/dev/null 2>&1 && ok "Payload $size bytes: OK" || warn "Payload $size bytes: failed"; done; }
dns_test(){ echo; info "=== DNS Test ==="; if command -v resolvectl >/dev/null 2>&1; then resolvectl status 2>/dev/null | head -n 40; else cat /etc/resolv.conf; fi; echo; for host in controlplane.tailscale.com tailscale.com; do getent ahosts "$host" >/dev/null 2>&1 && ok "$host resolves" || warn "$host does not resolve"; done; }
status(){ join_if_needed || return 1; echo; info "=== Tailscale Status ==="; "$TS_BIN" status || true; echo; info "=== Tailscale IPs ==="; "$TS_BIN" ip -4 2>/dev/null || true; "$TS_BIN" ip -6 2>/dev/null || true; echo; info "=== Netcheck ==="; "$TS_BIN" netcheck 2>/dev/null || true; echo; info "=== Public IP ==="; public_ip; echo; info "=== Location ==="; location_info; }
benchmark(){ join_if_needed || return 1; echo; info "=== VPS Quick Benchmark ==="; echo "Hostname    : $(hostname)"; public_ip; location_info; echo "Tailscale IPv4: $("$TS_BIN" ip -4 2>/dev/null || echo Unavailable)"; echo "Tailscale IPv6: $("$TS_BIN" ip -6 2>/dev/null || echo Unavailable)"; echo; info "Network"; "$TS_BIN" netcheck 2>/dev/null || true; echo; info "Peer connectivity"; ping_test || true; echo; info "Exit Node health"; health || true; }
remove_node(){ require_root || return 1; ensure_ts || return 1; echo; read -r -p "Type YES to confirm: " confirm; [[ "$confirm" == "YES" ]] || { echo "Cancelled."; return 0; }; "$TS_BIN" logout || true; ok "Device logged out"; }
uninstall_ts(){ require_root || return 1; echo; read -r -p "Type UNINSTALL to confirm: " confirm; [[ "$confirm" == "UNINSTALL" ]] || { echo "Cancelled."; return 0; }; "$TS_BIN" logout >/dev/null 2>&1 || true; if command -v apt-get >/dev/null 2>&1; then apt-get remove -y tailscale || true; elif command -v dnf >/dev/null 2>&1; then dnf remove -y tailscale || true; elif command -v yum >/dev/null 2>&1; then yum remove -y tailscale || true; fi; rm -f /etc/sysctl.d/99-tailscale-exit.conf; sysctl --system >/dev/null 2>&1 || true; ok "Tailscale removal completed"; }
menu(){ clear 2>/dev/null || true; echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"; echo -e "${CYAN}║          Tailscale Full Setup            ║${NC}"; echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"; echo; echo "  1) Install Tailscale"; echo "  2) Setup Exit Node (IPv4 + IPv6)"; echo "  3) Enable Tailscale SSH"; echo "  4) Ping / Direct-DERP Test"; echo "  5) Network Benchmark (netcheck)"; echo "  6) Show Status + Public IP + Location"; echo "  7) Logout / Remove This Device"; echo "  8) Exit IP Test"; echo "  9) Exit Node Health Check"; echo " 10) MTU Test"; echo " 11) DNS Test"; echo " 12) Full VPS Benchmark"; echo " 13) Uninstall Tailscale"; echo " 14) Change Tailscale Hostname"; echo "  0) Exit"; echo; read -r -p "Select an option: " choice; case "$choice" in 1) install_ts ;; 2) setup_exit ;; 3) setup_ssh ;; 4) ping_test ;; 5) netcheck ;; 6) status ;; 7) remove_node ;; 8) exit_ip_test ;; 9) health ;; 10) mtu_test ;; 11) dns_test ;; 12) benchmark ;; 13) uninstall_ts ;; 14) set_hostname ;; 0) exit 0 ;; *) warn "Invalid option" ;; esac; echo; read -r -p "Press Enter to return to menu..." _; menu; }
require_root || exit 1
menu
