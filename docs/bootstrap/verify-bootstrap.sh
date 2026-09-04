#!/usr/bin/env bash
# =============================================================================
# Rehearse the WHOLE bootstrap procedure on a fresh CHR, end to end:
#
#   vm       recreate the CHR VM from the image        (calls chr-test-vm.sh)
#   preflight  version / connectivity / inventory wiring checks
#   defconf  synthesise an RB5009-like defconf, then run the teardown sequence
#   run      site.yml --limit test: --check, apply, apply again (changed=0)
#
# Usage:
#   ./verify-bootstrap.sh                 # all stages, in order
#   ./verify-bootstrap.sh defconf run     # only these stages
#
# Env:
#   CHR_IP        management address of the CHR (default: from virsh leases)
#   CHR_USER      RouterOS account to use over SSH (default: netadmin)
#   ROS_VERSION   expected RouterOS version (default: 7.23.4)
#
# It stops at every point where connectivity has to be confirmed by hand and
# prints what to look at. Nothing here targets real hardware: every play is
# pinned to --limit test and the inventory is checked to make sure that group
# resolves to exactly one host.
#
# ----------------------------------------------------------------------------
# WHAT THIS SCRIPT CANNOT VERIFY - read before trusting a green run
#
#   * device-mode. CHR has no 'home' mode, so the scheduler is never blocked and
#     the dead man's switch always arms. On a factory RB5009 it does not, until
#     '/system device-mode update scheduler=yes' plus a physical button press.
#     Mechanism A is UNTESTED here by construction.
#   * The hardware switch chip. CHR forwards in software; VLAN tagging, offload
#     and the reprogramming pause when vlan-filtering flips are all absent.
#   * Mechanism C in its hardware form. CHR's management address (ether1, on the
#     libvirt network) is in a different subnet from the bridge, so RouterOS just
#     migrates the address and L2 never drops. On the RB5009 both are in one
#     subnet and the bridge-port loop times out on the first item. A clean run
#     here is not evidence.
#   * The defconf itself. CHR does not ship one - stage 'defconf' BUILDS an
#     RB5009-like config and then tears it down, so it exercises the command
#     sequence and the resulting state, NOT the real factory config.
#   * PPPoE over VLAN 35, PoE, and real throughput. See README.md.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHR_USER="${CHR_USER:-netadmin}"
ROS_VERSION="${ROS_VERSION:-7.23.4}"
MGMT_NET="${MGMT_NET:-default}"
VM_NAME="chr-test"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
say()  { printf '%s\n' "$*"; }
head2() { printf '\n%s== %s ==%s\n' "$BLD" "$*" "$RST"; }
ok()   { printf '%s  ok%s   %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s  warn%s %s\n' "$YEL" "$RST" "$*"; }
die()  { printf '%s  FAIL%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

pause() {
  printf '\n%s-- CHECK BY HAND ------------------------------------------%s\n' "$YEL" "$RST"
  printf '%s\n' "$@"
  printf '%s-----------------------------------------------------------%s\n' "$YEL" "$RST"
  read -r -p "Enter to continue, Ctrl-C to stop: " _
}

# Run a RouterOS command over SSH. Quoting is deliberate: RouterOS parses the
# whole remote string itself.
ros() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
          "${CHR_USER}@${CHR_IP}" "$*"; }

discover_ip() {
  [[ -n "${CHR_IP:-}" ]] && return 0
  local mac
  mac="$(virsh domiflist "$VM_NAME" 2>/dev/null | awk -v n="$MGMT_NET" '$3 == n {print $5}')"
  [[ -z "$mac" ]] && die "cannot find the $VM_NAME management NIC - is the VM defined?"
  CHR_IP="$(virsh net-dhcp-leases "$MGMT_NET" 2>/dev/null \
    | awk -v m="$mac" 'tolower($0) ~ tolower(m) {print $5}' | cut -d/ -f1)"
  [[ -z "$CHR_IP" ]] && die "no DHCP lease for $VM_NAME yet - virsh net-dhcp-leases $MGMT_NET"
  ok "CHR management address: $CHR_IP"
}

# --- stage: vm ---------------------------------------------------------------
stage_vm() {
  head2 "stage: vm - recreate the CHR from a clean image"
  if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    read -r -p "domain '$VM_NAME' exists. Destroy and recreate it? [y/N] " a
    [[ "$a" == "y" || "$a" == "Y" ]] || die "aborted - a stale VM is not a clean rehearsal"
    virsh destroy "$VM_NAME" >/dev/null 2>&1
    virsh undefine "$VM_NAME" --remove-all-storage >/dev/null
    ok "old domain removed"
  fi
  "${SCRIPT_DIR}/chr-test-vm.sh" "$ROS_VERSION" || die "chr-test-vm.sh failed"
  pause \
    "The CHR is up but has NO account and NO API service yet." \
    "Do the one-time bootstrap now (README.md, 'One-time RouterOS bootstrap'):" \
    "  - open the console:  virsh console $VM_NAME   (login admin, empty password)" \
    "  - /user add name=${CHR_USER} group=full password=<the test vault password>" \
    "  - import the SSH public key for ${CHR_USER}" \
    "  - /ip service enable api" \
    "  - point the [test] group in inventory/hosts.yml at the address above"
}

# --- stage: preflight --------------------------------------------------------
stage_preflight() {
  head2 "stage: preflight"
  discover_ip

  ros "/system resource print" >/dev/null 2>&1 || die "SSH to ${CHR_USER}@${CHR_IP} failed"
  ok "SSH works"

  local actual
  actual="$(ros '/system resource print' | awk -F': *' '/version/ {print $2}' | tr -d '\r' | awk '{print $1}')"
  if [[ "$actual" == "$ROS_VERSION" ]]; then
    ok "RouterOS $actual matches the expected version"
  else
    warn "CHR runs $actual, expected $ROS_VERSION"
    warn "The API schema is version-dependent - a gate on the wrong version proves nothing."
    pause "Rebuild with:  ./chr-test-vm.sh $ROS_VERSION   (or set ROS_VERSION to match)"
  fi

  # Guard: the 'test' group must resolve to exactly one host, and no other.
  cd "$REPO_ROOT" || die "cannot cd to $REPO_ROOT"
  local hosts n
  hosts="$(ansible --list-hosts test -i inventory/hosts.yml 2>/dev/null | tail -n +2 | tr -d ' ')"
  n="$(printf '%s\n' "$hosts" | grep -c .)"
  [[ "$n" -eq 1 ]] || die "group 'test' resolves to $n hosts ($hosts) - refusing to run"
  ok "group 'test' resolves to a single host: $hosts"

  # The role under test must actually be selected, or the triple is all skips.
  if ansible-playbook -i inventory/hosts.yml site.yml --limit test --list-tasks 2>/dev/null \
       | grep -q 'routeros_interfaces'; then
    ok "routeros_device_class selects the edge roles"
  else
    die "routeros_interfaces is not in the task list - set routeros_device_class: edge in group_vars/test/vars.yml"
  fi
}

# --- stage: defconf ----------------------------------------------------------
# CHR ships without a defconf, so build one that looks like the RB5009's, then
# run the teardown from README.md against it. This checks the command sequence
# and the state it leaves behind. It does NOT check that the session survives -
# see the header.
stage_defconf() {
  head2 "stage: defconf - build an RB5009-like config, then tear it down"
  discover_ip

  say "building the defconf stand-in (bridge 'bridge', ether2-4, 192.168.88.1/24, DHCP, lists)"
  ros '/interface bridge add name=bridge'                                       || die "bridge add failed"
  ros '/interface bridge port add bridge=bridge interface=ether2'               || die "bridge port add failed"
  ros '/interface bridge port add bridge=bridge interface=ether3'               || die "bridge port add failed"
  ros '/interface bridge port add bridge=bridge interface=ether4'               || die "bridge port add failed"
  ros '/ip address add address=192.168.88.1/24 interface=bridge'                || die "address add failed"
  ros '/ip pool add name=default-dhcp ranges=192.168.88.10-192.168.88.254'      || die "pool add failed"
  ros '/ip dhcp-server add name=defconf interface=bridge address-pool=default-dhcp disabled=no' || die "dhcp-server add failed"
  ros '/ip dhcp-server network add address=192.168.88.0/24 gateway=192.168.88.1' || die "dhcp network add failed"
  ros '/interface list add name=LAN; /interface list add name=WAN'              || warn "interface lists may already exist"
  ros '/interface list member add list=LAN interface=bridge'                    || die "list member add failed"
  ros '/interface list member add list=WAN interface=ether2'                    || die "list member add failed"
  ok "defconf stand-in in place"

  say ""
  say "teardown, in the order from README.md - (a) address on the cable port first"
  ros '/ip address add address=192.168.99.1/24 interface=ether3'                || die "(a) failed"
  ok "(a) temporary address on ether3 added"
  ros '/ip address print where interface=ether3' | sed 's/^/      /'

  ros '/ip dhcp-client remove [find]'                                            || warn "(b) no dhcp-client"
  ros '/ip dhcp-server remove [find]'                                            || die "(b) dhcp-server remove failed"
  ros '/ip dhcp-server network remove [find]'                                    || die "(b) dhcp network remove failed"
  ros '/ip pool remove [find]'                                                   || die "(b) pool remove failed"
  ok "(b) DHCP machinery removed"

  ros '/ip address remove [find interface=bridge]'                               || die "(c) failed"
  ok "(c) defconf address removed from the bridge"

  ros '/interface bridge port remove [find bridge=bridge]'                        || die "(d) failed"
  ok "(d) ports removed from the bridge - the ether3 address is now standalone"

  say ""
  say "  ether3 address after the ports left the bridge:"
  ros '/ip address print where interface=ether3' | sed 's/^/      /'

  pause \
    "This is the verification stop from README.md. On HARDWARE you would now" \
    "confirm, from a second terminal, that the management path survived:" \
    "  ping 192.168.99.1" \
    "  ssh ${CHR_USER}@192.168.99.1" \
    "Here, ether3 is on the libvirt network, so try:" \
    "  ping -c2 192.168.99.1        (may need a route; ether1 is still your safety net)" \
    "" \
    "NOTE: a pass here does NOT mean the sequence is safe on the RB5009. On CHR you" \
    "still hold the ether1 session, which is exactly the safety net hardware lacks."

  ros '/interface bridge remove [find name=bridge]'                              || die "(e) failed"
  ok "(e) empty bridge removed"
  ros '/interface list member remove [find]'                                     || die "(f) failed"
  ok "(f) defconf interface-list members cleared"

  say ""
  say "  remaining interface-list members (should be empty):"
  ros '/interface list member print' | sed 's/^/      /'
}

# --- stage: run --------------------------------------------------------------
stage_run() {
  head2 "stage: run - site.yml --limit test, three passes"
  cd "$REPO_ROOT" || die "cannot cd to $REPO_ROOT"

  local vault_args=()
  if head -c 14 group_vars/test/vault.yml 2>/dev/null | grep -q 'ANSIBLE_VAULT'; then
    vault_args=(--ask-vault-pass)
    say "group_vars/test/vault.yml is encrypted - you will be asked for the password"
  fi

  local base=(ansible-playbook -i inventory/hosts.yml site.yml --limit test "${vault_args[@]}")

  say ""
  say "pass 1/3: --check --diff"
  "${base[@]}" --check --diff || die "check run failed"
  pause "Read the diff above. Anything you did not intend? Stop now if so."

  say ""
  say "pass 2/3: apply"
  "${base[@]}" --diff || die "apply run failed"
  pause \
    "The play applied. Confirm the box is still reachable and sane:" \
    "  ssh ${CHR_USER}@${CHR_IP} '/interface bridge vlan print'" \
    "  ssh ${CHR_USER}@${CHR_IP} '/ip firewall filter print'   # confirm ORDER, not just the set" \
    "  ssh ${CHR_USER}@${CHR_IP} '/interface list member print'"

  say ""
  say "pass 3/3: idempotence - this one must report changed=0"
  local out rc
  out="$("${base[@]}" --diff 2>&1)"; rc=$?
  printf '%s\n' "$out"
  [[ $rc -eq 0 ]] || die "third run failed"

  local changed
  changed="$(printf '%s\n' "$out" | awk '/^[^ ]+ +: +ok=/ {for (i=1;i<=NF;i++) if ($i ~ /^changed=/) {sub(/changed=/,"",$i); print $i}}')"
  if [[ "$changed" == "0" ]]; then
    ok "idempotent: changed=0"
  else
    die "third run reported changed=${changed:-?} - not idempotent. Find the churning task in the diff above."
  fi

  warn "changed=0 is blind to drift on paths without a primary key (ADR-0009)."
  warn "For ip route / ip firewall mangle, check the device state directly."
}

# --- main --------------------------------------------------------------------
sed -n '/^# WHAT THIS SCRIPT CANNOT VERIFY/,/^# ====/p' "${BASH_SOURCE[0]}" \
  | sed 's/^# \{0,1\}//; $d'

stages=("$@")
[[ ${#stages[@]} -eq 0 ]] && stages=(vm preflight defconf run)

for s in "${stages[@]}"; do
  case "$s" in
    vm)        stage_vm ;;
    preflight) stage_preflight ;;
    defconf)   stage_defconf ;;
    run)       stage_run ;;
    *)         die "unknown stage '$s' (vm | preflight | defconf | run)" ;;
  esac
done

head2 "done"
say "Verified on CHR ${ROS_VERSION}. Re-read the 'CANNOT VERIFY' block at the top"
say "before treating this as clearance for the RB5009 - device-mode, the switch"
say "chip and mechanism C are all still untested at this point."
