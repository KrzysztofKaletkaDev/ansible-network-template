#!/usr/bin/env bash
# =============================================================================
# Provision a RouterOS CHR test VM on the local libvirt/KVM host.
#
# Rehearses role changes before they touch real hardware. What it does NOT
# cover: PPPoE over VLAN 35 (needs a real ISP session), PoE, the hardware
# switch chip / fasttrack, and real throughput (the CHR Free licence caps
# every interface at 1 Mbit/s). See README.md.
#
# Usage:  ./chr-test-vm.sh [ROUTEROS_VERSION]        (default: 7.19.4)
# Teardown:  virsh destroy chr-test && virsh undefine chr-test --remove-all-storage
# =============================================================================
set -euo pipefail

ROS_VERSION="${1:-7.19.4}"
VM_NAME="chr-test"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBVIRT_IMAGES="${LIBVIRT_IMAGES:-/var/lib/libvirt/images}"
MGMT_NET="${MGMT_NET:-default}"   # libvirt NAT network for the API / management NIC
WAN_NET="${WAN_NET:-chr-wan}"     # isolated network standing in for the WAN

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

# --- isolated WAN network (idempotent) --------------------------------------
if ! virsh net-info "$WAN_NET" >/dev/null 2>&1; then
  net_xml="$(mktemp)"
  cat >"$net_xml" <<EOF
<network>
  <name>${WAN_NET}</name>
  <bridge name='virbr-chrwan'/>
</network>
EOF
  virsh net-define "$net_xml"
  virsh net-start "$WAN_NET"
  virsh net-autostart "$WAN_NET"
  rm -f "$net_xml"
fi

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
  --import --os-variant generic --graphics none --noautoconsole

# --- report the management lease ------------------------------------------
mgmt_mac="$(virsh domiflist "$VM_NAME" | awk -v n="$MGMT_NET" '$3 == n {print $5}')"
mgmt_ip=""
for _ in $(seq 1 30); do
  mgmt_ip="$(virsh net-dhcp-leases "$MGMT_NET" 2>/dev/null \
    | awk -v m="$mgmt_mac" 'tolower($0) ~ tolower(m) {print $5}' | cut -d/ -f1)"
  [[ -n "$mgmt_ip" ]] && break
  sleep 2
done

echo
echo "CHR '${VM_NAME}' is up (RouterOS ${ROS_VERSION})."
echo "  management address : ${mgmt_ip:-<not leased yet — virsh net-dhcp-leases ${MGMT_NET}>}"
echo "  ether1 -> ${MGMT_NET}  (API / management)"
echo "  ether2 -> ${WAN_NET}   (stand-in WAN)"
echo
echo "Next: run the one-time RouterOS bootstrap (see README.md) — create the"
echo "netadmin account, enable /ip service api — then point the [test] group in"
echo "inventory/hosts.yml at ${mgmt_ip:-that address}."
