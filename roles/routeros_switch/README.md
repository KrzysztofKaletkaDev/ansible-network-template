# routeros_switch

The CRS310's VLAN / switching configuration. Runs only where
`routeros_device_class == 'switch'` (see `site.yml`). `routeros_common` runs on
this host as well and covers identity, time, the account and service hardening.

- a bridge (`routeros_switch_bridge`) with a VLAN table that **mirrors** the
  RB5009's: `main` (id 1) untagged on `routeros_switch_main_vlan_ports`, `servers`
  (id 20) untagged on `routeros_switch_servers_vlan_ports`, both tagged on the
  trunk; the bridge itself tagged on `servers` (it carries the mgmt address)
- per-port access PVIDs from the two `*_vlan_ports` lists
- the tagged trunk port (`routeros_switch_trunk_port`) back to the RB5009 —
  added on its own, never through the access-port loops
- the switch's management address (`routeros_switch_mgmt_address`) on the
  `servers` VLAN, plus a default route via `routeros_vlans.servers.gateway`
- `vlan-filtering` enabled **after** the table is in place

## First run: cable straight to a laptop, not the trunk

VLAN 1 is tagged on the trunk, so a factory switch (which knows no tags) is
unreachable over the trunk. Bootstrap it directly:

1. Connect a laptop to any access port (or use MAC-Winbox).
2. Create the `netadmin` account (`group=full`), set an address on VLAN 20 and a
   default route, remove the factory DHCP client on the bare bridge, enable
   `/ip service api`.
3. Confirm login, then move the switch into place and cable the trunk.
4. From then on Ansible manages it over the trunk.

See `docs/bootstrap/README.md`.

## Lockout notes

The CRS310 has no serial console. `Włącz filtrowanie VLAN` is the step that can
cut management: the switch chip enforces the table the instant it flips on.

- Mechanism A (dead man's switch) is pulled in at the top of the role while
  `routeros_enable_dead_mans_switch` is true. Disarm after a confirmed run:
  `ansible-playbook -i inventory/hosts.yml site.yml --limit switches --tags clear-rollback`.
- On hardware, keep a Safe Mode session open alongside the run (mechanism B).
- The rollout order is forced: `routeros_interfaces` must already be applied on
  the RB5009 (VLAN 20 routed, the firewall rule that lets the control node reach
  the switch) before the CRS310 at `routeros_switch_mgmt_address` is reachable
  for Ansible at all.

## Rehearsing on CHR

Set `routeros_device_class: switch` in `group_vars/test/vars.yml` and override
`routeros_switch_*_vlan_ports` / `routeros_switch_trunk_port` to match the CHR
VM's NIC count.

```
ansible-playbook -i inventory/hosts.yml site.yml --limit test --check --diff
ansible-playbook -i inventory/hosts.yml site.yml --limit test --diff
ansible-playbook -i inventory/hosts.yml site.yml --limit test --diff   # changed=0
```

CHR shares one RouterOS instance, so it checks the role logic, the VLAN-table
syntax and idempotence — **not** the trunk between two physical devices or the
hardware switch chip's behaviour on tagging. If the CHR VM's management path is
untagged on a port that this role turns into a VLAN access port, enabling
`vlan-filtering` will cut the API session mid-run — give the VM a separate
always-up management NIC, or expect to re-run after reconnecting.
