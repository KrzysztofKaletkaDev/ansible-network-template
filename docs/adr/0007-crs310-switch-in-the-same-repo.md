# 7. The CRS310 switch lives in this repository, not its own

## Status

Accepted

## Context

Splitting the LAN into a flat `main` VLAN and a segmented `servers` VLAN needs a
second managed device: a MikroTik CRS310, running RouterOS (not SwOS-Lite —
`community.routeros` does not work over SwOS), carrying the server access ports
and trunking both VLANs back to the RB5009.

ADR-0001 argued for keeping the network layer in its own repository, separate
from `ansible-homelab-template`, on the grounds of blast radius, collection /
connection model, and change cadence. That reasoning could be applied again, one
level down, to give the switch its own repository. It does not hold here:

- **Blast radius is shared, not separate.** The switch and the router are one
  L2/L3 fabric. A wrong VLAN table on either one cuts the same set of devices
  off the network. They fail together and are recovered together.
- **Same collection, same connection model, same safety workflow.** Both are
  `community.routeros` over the API with `connection: local`; both are
  console-less and want the dead man's switch / Safe Mode wrapper around every
  apply. A second repo would duplicate all of it.
- **Changes are coupled.** The switch's VLAN table mirrors the router's. A
  change to VLAN ids or the trunk port touches both in the same commit.

## Decision

Manage the CRS310 as a second host in this repository.

- A `switches` inventory group under `routers`, with its own `group_vars`.
- `routeros_common` runs on it unchanged (identity, time, the account, service
  hardening are device-agnostic).
- A new `routeros_switch` role holds only the switch-specific VLAN / bridge
  logic, guarded by `routeros_device_class == 'switch'` in `site.yml`.
- Its own Vault (`group_vars/switches/vault.yml`) with a **different** API
  password from the router's — the same isolation the CHR test VM gets, so
  compromising one device does not hand over the other.

## Consequences

- One `--limit switches` run configures the switch; the router and the switch
  share history, CI, and the ADR log.
- The rollout order is forced: `routeros_interfaces` must be applied on the
  RB5009 first (VLAN 20 routed, the firewall rule that lets the control node
  reach the switch's management address) before the CRS310 is reachable for
  Ansible at all. This is a documented constraint, not something the tooling
  enforces.
- The switch's VLAN table and the router's are kept mirrored by hand. There is
  no cross-check that `routeros_switch_*_vlan_ports` and the RB5009 bridge VLAN
  table agree.
- Two API passwords for two devices instead of one — accepted for the isolation.
