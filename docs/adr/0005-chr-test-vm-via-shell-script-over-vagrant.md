# 5. CHR test VM via a shell script instead of Vagrant or an IaC provider

## Status

Accepted

## Context

Role changes in this repo need somewhere to be rehearsed before they touch the
real router — the equivalent role in `ansible-homelab-template` has a disposable
AlmaLinux VM (`Vagrantfile`) for exactly that. RouterOS has an equivalent, CHR
(Cloud Hosted Router), which runs as a VM.

The obvious-looking ways to stand it up don't fit:

- **Vagrant.** CHR ships as a raw appliance disk image, not a Vagrant box and
  not a cloud image. Wrapping it in a `config.vm.box` means building and
  maintaining a custom box per RouterOS version.
- **An IaC provider (OpenTofu/Terraform + libvirt).** The sibling Kubernetes
  repo already went down this path for cloud-init VMs and backed out — the
  libvirt provider was unreliable enough that a plain, documented shell script
  in `docs/bootstrap/` replaced it. The same reasoning applies here, more so:
  CHR needs less orchestration than a cloud-init node, not more.

## Decision

Provision the CHR test VM with a shell script, `docs/bootstrap/chr-test-vm.sh`:
download the image, `qemu-img convert` to qcow2, define an isolated WAN network,
`virt-install --import` a four-NIC domain (`ether1` management/API, `ether2` a
stand-in WAN, `ether3`/`ether4` LAN stand-ins so the bridge-port loop and the
bridge VLAN table have real interfaces to act on), print the management address.
Teardown is two `virsh` commands. `docs/bootstrap/README.md` documents it and
lists what CHR cannot cover.

## Consequences

- No new tool or provider to install or keep working — `qemu-img`, `virsh` and
  `virt-install` are already present on any libvirt host.
- The script is not declarative state: re-running it against an existing
  `chr-test` domain refuses rather than reconciling, and teardown is manual. For
  one throwaway VM that is acceptable; a fleet would need more.
- CHR has hard gaps a VM cannot close — PPPoE over VLAN 35, PoE, the hardware
  switch chip, real throughput (Free licence: 1 Mbit/s per interface). These are
  spelled out in the bootstrap README so "it passed on CHR" is not mistaken for
  "it is safe on hardware"; the first hardware run still uses the dead man's
  switch and Safe Mode.
- CI runs no Molecule / VM job — GitHub-hosted runners have no KVM — so CHR
  rehearsal is a local, manual gate, not an automated one.
