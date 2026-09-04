# Bootstrap

## RouterOS CHR test VM

`chr-test-vm.sh` provisions a RouterOS CHR instance on the local libvirt/KVM
host to rehearse role changes before they touch real hardware.

```
./docs/bootstrap/chr-test-vm.sh [routeros-version]   # default: 7.19.4
```

It downloads the CHR image, converts it to qcow2, defines an isolated
`chr-wan` network, and starts a `chr-test` domain with four NICs — `ether1` on
the libvirt `default` NAT network (API / management), `ether2` on `chr-wan`
(a stand-in WAN), and `ether3` / `ether4` back on `default` as LAN stand-ins so
the bridge-port loop and the bridge VLAN table can be rehearsed. The management
address is printed at the end.

Tear down with:

```
virsh destroy chr-test && virsh undefine chr-test --remove-all-storage
```

The downloaded `chr-*.img*` / `chr-*.qcow2` files land next to the script and
are git-ignored.

### What CHR does NOT test

- **PPPoE over VLAN 35** — needs a real session with the ISP; it cannot be
  reproduced in a VM.
- **PoE** — the RB5009's powered ports have no CHR equivalent.
- **The hardware switch chip and fasttrack** — CHR forwards purely in software.
- **Real throughput** — the CHR Free licence caps every interface at 1 Mbit/s.
- **`--check` does not validate interface existence.** The `invalid value for
  argument interface` error only surfaces during an actual API call, not in
  check mode. If `routeros_lan_bridge_ports` (or the VLAN table) lists interfaces
  the CHR VM does not have — e.g. `ether3`–`ether8` / `sfp-sfpplus1` on a smaller
  instance — `--check` passes but the real run fails. A typo in a port name is
  the same trap: the RB5009's SFP+ port is `sfp-sfpplus1`, not `sfp-plus1`, and
  the wrong name would sail through check mode. Match the port list to the VM's
  NIC count, or give the VM enough NICs via `chr-test-vm.sh`.
- **The trunk between two physical devices.** `routeros_switch` on a single CHR
  instance exercises the VLAN-table syntax and idempotence, but not the RB5009 ↔
  CRS310 trunk itself or how the hardware switch chip tags frames — those only
  show up on real hardware.
- **Mechanism C (management port inside the bridge).** A deliberate rehearsal
  with `ether1` added to `routeros_lan_bridge_ports` completed cleanly on CHR
  (`ok=25 changed=24 failed=0`). It only worked because CHR's management address
  (libvirt's `192.168.122.0/24`) and the bridge address (`10.0.0.0/24`) are on
  **different subnets**: RouterOS migrated the management address onto the bridge
  without a conflict, leaving the original `ether1` entry flagged `S` (SLAVE),
  and L2 was never actually lost. On the RB5009 both addresses live in **one**
  subnet — the bridge takes over the very network the operator is connected
  through and claims the gateway address at the same time, while the hardware
  switch chip is reprogrammed. That is a materially different operation.
  Mechanism C stands unchanged, and a clean CHR run with the management port
  bridged is **not** evidence that it is safe on hardware.

CHR verifies role logic, idempotence, the API connection, and firewall / DHCP
behaviour. It is not a performance test bed, and "it passed on CHR" is not
"it is safe on hardware" — the first real run still goes through the dead man's
switch (mechanism A) and, once verified, Safe Mode. See `CLAUDE.md`.

## One-time RouterOS bootstrap (outside Ansible)

Whether on CHR or the real router, do this once by hand — Winbox, or the CHR
console — before the first `site.yml` run:

1. Create the account Ansible will use (`routeros_api_user`, `netadmin` in the
   templates):

   ```
   /user add name=netadmin group=full password=<vault_routeros_api_password>
   ```

2. Import the interactive-login SSH public key. This is file-based and cannot be
   done over the API:

   ```
   /user ssh-keys import user=netadmin public-key-file=netadmin.pub
   ```

3. Enable the API service:

   ```
   /ip service enable api
   ```

4. Confirm you can reach the box as `netadmin` (SSH key and API), then point the
   relevant inventory group at it and run `site.yml`.

Pinning the API service to the control node's address and disabling the
built-in `admin` account are deferred steps owned by the `routeros_common`
role — see `roles/routeros_common/README.md`.

## One-time CRS310 bootstrap (cable it straight to a laptop)

The trunk carries VLAN 1 **tagged**, so there is no untagged traffic on the
trunk cable. A factory switch does not know the tags and is unreachable over the
trunk. Bootstrap it before it goes into place:

1. Connect a laptop directly to any access port (or reach it with MAC-Winbox).
2. Do it by hand — Winbox / WebFig only for this step (ADR-0002 still applies):

   ```
   /user add name=netadmin group=full password=<vault_routeros_api_password>
   /user ssh-keys import user=netadmin public-key-file=netadmin.pub
   /interface bridge set bridge vlan-filtering=no
   /interface vlan add name=vlan20-servers interface=bridge vlan-id=20
   /ip address add address=<routeros_switch_mgmt_address> interface=vlan20-servers
   /ip route add dst-address=0.0.0.0/0 gateway=<servers VLAN gateway>
   /ip dhcp-client remove [find interface=bridge]
   /ip service enable api
   ```

3. Confirm you can log in as `netadmin` over that address.
4. **Only now** move the switch into place, cable the trunk, and let Ansible
   (`--limit switches`) take over. `routeros_interfaces` must already be applied
   on the RB5009 or the switch's management address is not routed yet.

Do not try to bootstrap the switch over the trunk.
