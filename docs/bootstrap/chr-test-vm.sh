#!/usr/bin/env bash
# =============================================================================
# Provision a RouterOS CHR test VM on the local libvirt/KVM host.
#
# Rehearses role changes before they touch real hardware. What it does NOT
# cover: PPPoE over VLAN 35 (needs a real ISP session), PoE, the hardware
# switch chip / fasttrack, and real throughput (the CHR Free licence caps
# every interface at 1 Mbit/s). See README.md.
#
# The default version MUST track the version the hardware runs. The RouterOS
# API schema is version-dependent (hw-offload on fasttrack-connection was
# required on 7.19.4 and is rejected on 7.23.4), so a CHR on a different
# version is not a gate - it is a second, unrelated device.
#
# Usage:  ./chr-test-vm.sh [ROUTEROS_VERSION]        (default: 7.23.4)
# Teardown:  virsh destroy chr-test && virsh undefine chr-test --remove-all-storage
# =============================================================================
set -euo pipefail

ROS_VERSION="${1:-7.23.4}"
VM_NAME="chr-test"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBVIRT_IMAGES="${LIBVIRT_IMAGES:-/var/lib/libvirt/images}"
MGMT_NET="${MGMT_NET:-default}"   # libvirt NAT network for the API / management NIC
WAN_NET="${WAN_NET:-chr-wan}"     # isolated network standing in for the WAN
LAN1_NET="${LAN1_NET:-chr-lan1}"  # isolated network standing in for ether3
LAN2_NET="${LAN2_NET:-chr-lan2}"  # isolated network standing in for ether4

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }
need qemu-img
need virsh
need virt-install
need unzip
command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || {
  echo "missing dependency: wget or curl" >&2; exit 1; }

zip_file="${SCRIPT_DIR}/chr-${ROS_VERSION}.img.zip"
raw_img="${SCRIPT_DIR}/chr-${ROS_VERSION}.img"
qcow_img="${SCRIPT_DIR}/chr-${ROS_VERSION}.qcow2"
url="https://download.mikrotik.com/routeros/${ROS_VERSION}/chr-${ROS_VERSION}.img.zip"

# --- image: download + convert (idempotent) ----------------------------------
if [[ ! -f "$qcow_img" ]]; then
  if [[ ! -f "$zip_file" ]]; then
    echo "downloading ${url}"
    if command -v wget >/dev/null 2>&1; then
      wget -O "$zip_file" "$url"
    else
      curl -fL -o "$zip_file" "$url"
    fi
  fi
  unzip -o "$zip_file" -d "$SCRIPT_DIR"
  qemu-img convert -f raw -O qcow2 "$raw_img" "$qcow_img"
  qemu-img resize "$qcow_img" 256M
fi

# --- isolated stand-in networks (idempotent) ---------------------------------
# Each of ether2/ether3/ether4 gets its OWN isolated network. Two of this VM's
# NICs sharing one libvirt network, then bridged together inside the guest
# (as ether3+ether4 used to be, both on MGMT_NET), closes an L2 loop through
# the host bridge for that network - it does not stay contained in the guest.
ensure_isolated_net() {
  local net="$1" bridge="$2"
  virsh net-info "$net" >/dev/null 2>&1 && return 0
  local net_xml
  net_xml="$(mktemp)"
  cat >"$net_xml" <<EOF
<network>
  <name>${net}</name>
  <bridge name='${bridge}'/>
</network>
EOF
  virsh net-define "$net_xml"
  virsh net-start "$net"
  virsh net-autostart "$net"
  rm -f "$net_xml"
}
ensure_isolated_net "$WAN_NET" virbr-chrwan
ensure_isolated_net "$LAN1_NET" virbr-chrlan1
ensure_isolated_net "$LAN2_NET" virbr-chrlan2

# --- domain ---------------------------------------------------------------
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "domain '${VM_NAME}' already exists — tear it down first:" >&2
  echo "  virsh destroy ${VM_NAME} && virsh undefine ${VM_NAME} --remove-all-storage" >&2
  exit 1
fi

install -m 0644 "$qcow_img" "${LIBVIRT_IMAGES}/${VM_NAME}.qcow2"

virt-install \
  --name "$VM_NAME" \
  --memory 256 --vcpus 1 \
  --disk "path=${LIBVIRT_IMAGES}/${VM_NAME}.qcow2,bus=virtio,format=qcow2" \
  --network "network=${MGMT_NET},model=virtio" \
  --network "network=${WAN_NET},model=virtio" \
  --network "network=${LAN1_NET},model=virtio" \
  --network "network=${LAN2_NET},model=virtio" \
  --import --os-variant generic --graphics none --noautoconsole
# ether3 / ether4 are LAN stand-ins so the `interface bridge port` loop and the
# CN2b bridge VLAN table can be rehearsed without overriding
# routeros_lan_bridge_ports in group_vars/test. Each is on its own isolated
# network (LAN1_NET / LAN2_NET) rather than sharing one with each other or with
# MGMT_NET - see the isolated-networks comment above for why.

# --- report the management lease ------------------------------------------
mgmt_mac="$(virsh domiflist "$VM_NAME" | awk -v n="$MGMT_NET" '$3 == n {print $5}')"
mgmt_ip=""
for _ in $(seq 1 45); do   # ~90s — a cold CHR boot has overrun 60s
  mgmt_ip="$(virsh net-dhcp-leases "$MGMT_NET" 2>/dev/null \
    | awk -v m="$mgmt_mac" 'tolower($0) ~ tolower(m) {print $5}' | cut -d/ -f1)"
  [[ -n "$mgmt_ip" ]] && break
  sleep 2
done

echo
echo "CHR '${VM_NAME}' is up (RouterOS ${ROS_VERSION})."
echo "  management address : ${mgmt_ip:-<not leased yet — virsh net-dhcp-leases ${MGMT_NET}>}"
echo "  ether1 -> ${MGMT_NET}   (API / management)"
echo "  ether2 -> ${WAN_NET}    (stand-in WAN)"
echo "  ether3 -> ${LAN1_NET}   (LAN stand-in for bridge / VLAN tests)"
echo "  ether4 -> ${LAN2_NET}   (LAN stand-in for bridge / VLAN tests)"
echo
echo "Next: run the one-time RouterOS bootstrap (see README.md) — create the"
echo "netadmin account, enable /ip service api — then point the [test] group in"
echo "inventory/hosts.yml at ${mgmt_ip:-that address}."
