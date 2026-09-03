# routeros_dhcp

DHCP for both VLANs. Runs only where `routeros_device_class == 'edge'` (see
`site.yml`); depends on `routeros_interfaces` having created `bridge-lan` and the
`vlan-servers` sub-interface.

Per entry in `routeros_dhcp_networks` (one for each key in `routeros_vlans`):

- `ip pool` `dhcp-<vlan>` with `routeros_dhcp_pool_ranges[<vlan>]`
- `ip dhcp-server` `dhcp-<vlan>` on that interface, `authoritative`,
  `lease-time = routeros_dhcp_lease_time`
- `ip dhcp-server network` for the VLAN subnet, `gateway` and `dns-server` both
  set to the VLAN gateway — the router is the sole advertised resolver
  (**ADR-0004**, lands with `routeros_dns`; until then `/ip dns` does not answer)

Static reservations are one declarative table:

- VLAN main — from `routeros_dhcp_leases` (`name` / `mac` / `ip`); the real
  ~14-entry table lives in the local `group_vars/all/vars.yml`
- VLAN servers — derived from `routeros_servers_vlan_hosts`
  (`name` / `mac` / `host_octet` → `routeros_servers_vlan_prefix.<octet>`)

The final `api_modify` uses `handle_absent_entries: remove`: a **static** lease
not in either table is deleted. Dynamic leases (live clients) are filtered out by
the module and never touched.

A start-of-role `assert` fails if `routeros_servers_vlan_hosts` is empty or is
missing `qnap-native` / `alma` — those names are load-bearing for
`routeros_firewall`'s `routeros_qnap_native_ip` / `routeros_alma_ip`.

## Bootstrap / hardware note

Remove the factory `defconf` DHCP server, pool and network during bootstrap —
`routeros_interfaces` builds `bridge-lan`, not the factory `bridge`, so `defconf`
would be left orphaned on an interface with no clients.

## Rehearsing on CHR

Set `routeros_device_class: edge` in `group_vars/test/vars.yml`.

```
ansible-playbook -i inventory/hosts.yml site.yml --limit test --check --diff
ansible-playbook -i inventory/hosts.yml site.yml --limit test --diff
ansible-playbook -i inventory/hosts.yml site.yml --limit test --diff   # changed=0
```

Confirm `handle_absent_entries: remove` on `ip dhcp-server lease` does not delete
the CHR network's dynamic leases (it should not — the module drops `dynamic`
entries before comparing).
