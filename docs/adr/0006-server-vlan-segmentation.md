# 6. Server VLAN segmentation

## Status

Accepted

## Context

The LAN was one flat broadcast domain: cameras, solar inverters, laptops, the
NAS and the containers it hosts all on `10.0.0.0/24`. A compromise anywhere —
an unpatched camera, a phone on a bad Wi-Fi — had a clear path to the NAS and to
everything it runs (a password manager, reverse proxy, the ad-blocking
resolver).

`routeros_interfaces` splits off a `servers` VLAN (id 20) for the NAS and the
mini-PCs; `routeros_switch` mirrors the VLAN table onto the CRS310. This ADR is
the firewall policy that makes the split mean something.

## Decision

`routeros_firewall` treats `main` -> `servers` as **default-deny**, with three
explicit exceptions, and `servers` -> `main` as **default-allow**.

**`main` (and WireGuard) -> `servers`:**

1. anyone on the LAN may reach the "alma" VM on `:80` / `:443` (the reverse
   proxy in front of the self-hosted services);
2. only the addresses in `qnap-native-access` may reach the native NAS on `:443`
   (Qsync backup, the QVR Pro client) — see ADR-0008 for why the NAS is two
   targets;
3. the WireGuard peers in `wg-trusted` get unrestricted access to the server
   VLAN (the maintainer's own devices);

then everything else `main` -> `servers` is dropped. One more accept sits above
the drop: the control node to the CRS310's management address, so Ansible can
still manage the switch (its management IP is in the server VLAN).

**`servers` -> `main` is accepted with no restriction.** QVR Pro on the NAS
dials *outbound* to the cameras on VLAN `main` (RTSP, ONVIF, firmware). Rather
than enumerate camera IPs and ports that change with every QVR update, the
segment is left open in that direction.

## Consequences

- The asymmetry is real: a compromised host on the server VLAN has a full path
  back to everything on `main`. Accepted — the main driver was protecting the
  server VLAN *from* the noisy flat LAN, not the other way round, and the
  alternative (a brittle allow-list of camera endpoints) would break on every
  NAS software update and get widened "just to make it work".
- Blocking DoH/DoT (ADR-0004) now has to cover the server VLAN too: `vlan-servers`
  is in the `LAN` interface list, so the anti-DoH/DoT and `:53`-redirect rules
  apply to it as well. The ad-blocker is exempt (`doh-exempt`, `dns-nat-exempt`)
  because it legitimately uses DoH upstream.
- `:53` interception uses `action=redirect` (answer on the router's own
  `/ip dns`), not `dst-nat` to the resolver host. A `dst-nat` to a host in the
  same subnet as the client would break — the host replies directly, conntrack
  never sees it, the client rejects the mismatched source. `redirect` keeps the
  translation on the router, so there is no hairpin-NAT special case.
- The firewall role owns the entire `ip firewall filter` table. A missing
  interface-list membership on a new interface silently loses all its forward
  traffic. Every interface must be placed in `LAN`, `SERVERS` or `WAN` by
  `routeros_interfaces`.
