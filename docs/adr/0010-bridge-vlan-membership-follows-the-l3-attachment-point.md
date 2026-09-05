# 10. Bridge VLAN membership follows the L3 attachment point

## Status

Accepted

## Context

A VLAN-filtering bridge treats the bridge interface itself as a port — the CPU
port. Every row in `interface bridge vlan` therefore has to say not just which
physical ports carry that VLAN, but how the router's own CPU reaches it:
`tagged`, `untagged`, or not at all.

The first version of `routeros_interfaces` put the bridge in `tagged` for **both**
VLANs, on the reasoning that "the CPU needs both VLANs, so tag it into both".
That reasoning is wrong, and CHR could not show it:

- `routeros_lan_address` (the `main` gateway) sits **directly on `bridge-lan`**.
  Untagged. Nothing strips a VLAN tag on the way to it.
- `bridge-lan` listed as `tagged` for VLAN 1 tells the bridge the CPU port
  expects 802.1Q-tagged frames for that VLAN. Those frames never come.

On the RB5009 the result was immediate and total: the instant
`vlan-filtering: yes` flipped on, every access port kept link and lost all L3.
Moving `bridge-lan` from `tagged` to `untagged` on the VLAN 1 row fixed it on
the spot. The `servers` VLAN was already correct for the opposite reason — it is
reached through the `vlan-servers` sub-interface, which terminates tagged
frames, so there the CPU genuinely does want the tag.

**CHR is structurally blind to this class of bug.** On the test VM the
management session runs over `ether1`, which is deliberately outside the bridge
(`routeros_lan_bridge_ports` is `ether3` alone in `group_vars/test`). The bridge
address is never the management path there, so a dead VLAN 1 CPU path costs the
rehearsal nothing and the run reports clean. The gate passed; the hardware did
not.

`routeros_switch` had the same table with different content, and it was already
right — but for a reason nobody had written down, which made it look like an
unexplained divergence from the rule in `CLAUDE.md` that the two roles' VLAN
tables mirror each other.

## Decision

**A bridge's membership in a VLAN row follows where that VLAN's L3 address is
reached from — not a blanket rule about what the CPU needs.**

Three cases, and they are exhaustive:

1. The address sits **directly on the bridge** → the bridge goes in `untagged`,
   alongside the access ports. The bridge's own `pvid` must equal that VLAN id.
2. The address sits on a **VLAN sub-interface on top of the bridge** → the
   bridge goes in `tagged`.
3. The device has **no address on that VLAN** → the bridge does not appear in
   that row at all. It still switches the VLAN between its ports; only the CPU
   stays out.

Applied to the two roles:

| | VLAN `main` (id 1) | VLAN `servers` (id 20) |
|---|---|---|
| `routeros_interfaces` (RB5009) | `untagged` — `routeros_lan_address` is on `bridge-lan` (case 1) | `tagged` — reached via `vlan-servers` (case 2) |
| `routeros_switch` (CRS310) | absent — the switch has no address on `main` (case 3) | `tagged` — `routeros_switch_mgmt_address` is on `vlan-servers` (case 2) |

The divergence between the two roles in the `main` row is therefore
**sanctioned**: it is the same rule applied to two different L3 layouts, not a
drift between the roles. `CLAUDE.md`'s "if the two roles disagree it is a bug"
still holds for everything else in those tables, task order around
`vlan-filtering` included.

Case 1 carries a dependency that is easy to miss: `pvid` on the bridge itself.
`pvid` is the VLAN the CPU port assigns to untagged frames, so an untagged CPU
path only works when the bridge's `pvid` equals that VLAN's id. RouterOS
defaults a bridge to `pvid=1` and `routeros_vlans.main.id` is `1`, so the two
agreed by luck. `routeros_interfaces` now sets it explicitly on the bridge, so
they agree by construction.

## Consequences

- Adding a VLAN to either role means answering "where does this device hold an
  address on it?" **before** writing the row. The answer picks the case; there
  is nothing else to decide.
- Renumbering `routeros_vlans.main.id` away from `1` is now safe with respect to
  the CPU path — the explicit `pvid` follows it. It was not before: the bridge
  would have kept `pvid=1` while the table said otherwise, and the untagged CPU
  path would have died silently the next time `vlan-filtering` flipped.
- The two roles' VLAN tables will keep differing on the `main` row for as long
  as the RB5009 holds the LAN gateway and the CRS310 does not. A future change
  that gives the switch an address on `main` moves it from case 3 to case 2 or 1
  and the tables converge again — that is the rule working, not a regression.
- **A clean CHR run is not evidence for this class of bug**, and cannot be made
  into one without putting the CHR's management path on the bridge itself, which
  would cost the rehearsal its safety net (`ether1` is what makes a wedged CHR
  recoverable). The rehearsal keeps the safety net; this check moves to hardware
  and to review of the table against the three cases above. Recorded as a
  pitfall in `CLAUDE.md`.
- Nothing here changes the ordering rule: the VLAN table is still built before
  the `vlan-servers` interface and its address, and `vlan-filtering: yes` is
  still the last task in both roles.
