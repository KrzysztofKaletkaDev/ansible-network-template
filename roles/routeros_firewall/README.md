# routeros_firewall

The LAN firewall. Runs only where `routeros_device_class == 'edge'`. Implements
**ADR-0004** (DNS interception / anti-DoH-DoT), **ADR-0006** (main ↔ servers
segmentation) and **ADR-0008** (the QNAP as two endpoints).

- `ip firewall address-list` — the lists in `routeros_firewall_address_lists`
  (`doh-resolvers`, `doh-exempt`, `dns-nat-exempt`, `qnap-native-access`,
  `wg-trusted`). `handle_absent_entries: remove` is `restrict`ed to exactly
  those list names.
- `ip firewall nat` — `redirect` plaintext `:53` from the LAN to the router's
  own resolver (not `dst-nat` to a host — avoids the hairpin case), plus
  `masquerade` on the PPPoE uplink.
- `ip firewall filter` — the **complete** input + forward table, in order.

## This role owns the whole filter table

`ip firewall filter` and `ip firewall nat` have no primary key. This role uses
`handle_absent_entries: remove` + `ensure_order: true` and **owns the entire
path** — a rule added by hand, or a leftover `defconf` rule, is deleted. This is
the ADR-0009 "role owns the whole path" case, where `remove` is correct (unlike
`ip route` / mangle, which use the comment-tag + cleanup pattern).

Every interface the router has **must** be in the `LAN`, `SERVERS` or `WAN`
interface list (set by `routeros_interfaces`). The input chain ends with
`drop in-interface-list=WAN`, not `drop all`, so an interface in no list falls
through to the default `input` policy (accept) — that is deliberate (it keeps a
CHR management NIC on `ether1` reachable), but a *new* production interface left
out of the lists gets no forward filtering at all.

## Running it (hardware)

1. **Mechanism A** — the dead man's switch is pulled in at the top of the role
   while `routeros_enable_dead_mans_switch` is true. Disarm after a confirmed
   run: `--tags clear-rollback`.
2. **Mechanism B** — keep a Safe Mode session open alongside the run.
3. Apply on the CHR VM first and run the intent tests below.

## Rehearsing on CHR

Set `routeros_device_class: edge` in `group_vars/test/vars.yml`.

```
ansible-playbook -i inventory/hosts.yml site.yml --limit test --check --diff
ansible-playbook -i inventory/hosts.yml site.yml --limit test --diff
ansible-playbook -i inventory/hosts.yml site.yml --limit test --diff   # changed=0
```

Then test **intent**, not rule presence, from a second VM on the CHR LAN:

- `:53` to any address is answered by the router; TCP `:443` to an address in
  `doh-resolvers` is dropped, but from `routeros_alma_ip` it passes;
- `client → routeros_alma_ip:443` passes; `client → routeros_qnap_native_ip:443`
  is dropped unless the client is in `qnap-native-access`;
- a third VM standing in for a server VLAN host: `server → client` passes
  (SERVERS → LAN unrestricted); `client → server` is dropped;
- `/ip firewall filter print` — confirm the **order**, not just the set.
- hairpin: a VM on the server VLAN with a hardcoded external resolver still
  resolves (the `redirect` should make this work without an extra `srcnat`).

CHR cannot test the real PPPoE uplink or hardware fasttrack — see
`docs/bootstrap/README.md`.
