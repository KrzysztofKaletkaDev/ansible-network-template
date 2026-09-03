# routeros_interfaces

The edge router's data plane. Runs only where `routeros_device_class == 'edge'`
(see `site.yml`).

- LAN bridge (`routeros_lan_bridge`) with the untagged access ports from
  `routeros_lan_bridge_ports`, and the gateway address `routeros_lan_address`
- WAN: a tagged VLAN sub-interface (`routeros_wan_vlan_id`) on
  `routeros_wan_interface`, then a PPPoE client (`routeros_pppoe_interface`)
  on top of it
- WireGuard road-warrior server (`routeros_wg_interface`, `routeros_wg_address`)
  with one peer per entry in `routeros_wg_peers`
- TCP MSS clamping (`clamp-to-pmtu`) on the PPPoE and WireGuard interfaces
- bridge VLAN filtering with a two-VLAN table (`main` id 1, `servers` id 20),
  the tagged RB5009 → CRS310 trunk port (`routeros_interfaces_trunk_port`), the
  `servers` VLAN sub-interface and its gateway address
- the `LAN` / `WAN` / `SERVERS` interface lists used by the dhcp, dns and
  firewall roles (`vlan-servers` is in both `LAN` and `SERVERS`)

The firewall rules that enforce segmentation between `main` and `servers` live
in the `routeros_firewall` role.

## Secrets

`group_vars/routers/vault.yml` must provide `vault_routeros_pppoe_user`,
`vault_routeros_pppoe_password`, `vault_routeros_wg_private_key`, and
`vault_routeros_wg_peers` (a map keyed by the `name` of each entry in
`routeros_wg_peers`, each with `public_key` and `preshared_key`). The WireGuard
server private key is generated on the router; peer keypairs are generated per
device.

## First run on hardware (do not skip)

This role can cut the L2/L3 path to the router mid-run. On the RB5009, which has
no serial console, a lockout means a factory reset. Three layers apply:

1. **Mechanism A — dead man's switch.** Pulled in automatically at the top of
   the role while `routeros_enable_dead_mans_switch` is true (default). After a
   run with confirmed connectivity, disarm it:

   ```
   ansible-playbook -i inventory/hosts.yml site.yml --limit edge --tags clear-rollback
   ```

2. **Mechanism B — Safe Mode.** Keep a Safe Mode session (`Ctrl+X` in a
   terminal / WinBox) open alongside the Ansible run. Verified on CHR to cover
   changes made by the parallel API session and roll them back if the session
   drops (see ADR-0002).

3. **Mechanism C — management port out of the bridge.** In your local
   `group_vars/all/vars.yml`, drop the port you are connected through from
   `routeros_lan_bridge_ports`. Adding a port to the bridge tears down L2 on it
   before the bridge address is reachable. Add that port back in a separate run
   once connectivity via `routeros_lan_address` is confirmed.
   Rehearsing this on CHR does **not** reproduce the failure — the CHR
   management subnet differs from the bridge subnet, so RouterOS just migrates
   the address onto the bridge. See `docs/bootstrap/README.md`.

Test every change on the CHR VM first (`routeros_device_class: edge` in
`group_vars/test/vars.yml`).

## Testing on CHR

```
ansible-playbook -i inventory/hosts.yml site.yml --limit test --check --diff
ansible-playbook -i inventory/hosts.yml site.yml --limit test --diff
ansible-playbook -i inventory/hosts.yml site.yml --limit test --diff   # must report changed=0
```

Override `routeros_lan_bridge_ports` in `group_vars/test/vars.yml` to match the
CHR VM's actual interface count. A two-NIC CHR has only `ether1` (mgmt) and
`ether2` (stand-in WAN); `ether3`–`ether8` and `sfp-plus1` do not exist and
raise `invalid value for argument interface` on the real run — `--check` does
not catch this. A four-NIC CHR (`docs/bootstrap/chr-test-vm.sh`) adds `ether3`
and `ether4` as LAN stand-ins. Remove the override before running against
hardware.

Override nested variables such as `routeros_vlans` as a **whole dict**, not by
key. Ansible's default `hash_behaviour` is `replace`, so
`routeros_vlans.servers.gateway: "10.0.20.254"` in `group_vars/test/vars.yml`
just creates a variable whose literal name contains dots and does nothing — the
role keeps reading the `group_vars/all` value. Copy the full `routeros_vlans`
mapping into the override.

CHR does not test the real PPPoE session (tagged-VLAN uplink to the ISP) or the
hardware switch chip — see `docs/bootstrap/README.md`.
