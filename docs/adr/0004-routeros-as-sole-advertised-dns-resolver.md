# 4. RouterOS as the sole advertised DNS resolver

## Status

Accepted

## Context

On the old OpenWrt router, DHCP handed every client the ad-blocking resolver's
address directly (DHCP option 6). Clients talked to it; the router was not in the
DNS path at all. Two things were wrong with that:

- A client with a hardcoded public resolver (or DoH) bypassed ad-blocking
  entirely, and the router had no way to see or stop it.
- The resolver runs as a VM on the NAS. When the NAS is down — a reboot, a
  firmware update — DHCP is still advertising a dead resolver, and the whole LAN
  loses name resolution until it comes back.

The RB5009 runs its own caching DNS (`/ip dns`) and can both forward and
intercept, so the DNS path can be restructured around it.

## Decision

DHCP advertises **only the router's VLAN gateway** as the resolver (see
`routeros_dhcp`). The router's `/ip dns`:

- forwards to the ad-blocking resolver on the server VLAN
  (`routeros_dns_primary_upstream`);
- is the target of a firewall `dst-nat` rule that redirects any client's
  hardcoded `:53` back to it (see `routeros_firewall`, ADR-0006), so a hardcoded
  plain-DNS resolver cannot bypass ad-blocking;
- has a `tool netwatch` entry watching the ad-blocking resolver. When it goes
  down, a script swings `/ip dns servers` to public resolvers
  (`routeros_dns_fallback_upstream`); when it recovers, another script swings it
  back.

## Consequences

- **There is no second local DNS node.** While the ad-blocking resolver is down,
  Netwatch points the router at public resolvers: the internet keeps working,
  but **without ad-blocking**, until the resolver recovers. This is a deliberate
  trade — a standby resolver was not worth the extra moving part for a home
  network — not an oversight.
- If the resolver is down at the moment `routeros_dns` runs, the `/ip dns` task
  (which sets `servers` to the primary) and the Netwatch down-script fight over
  the value on every pass. That is the exceptional case; document it and don't
  run config pushes during a resolver outage.
- DoT (`:853`) and DoH (`:443` to known resolvers) still need blocking at the
  firewall — `dst-nat` on `:53` only covers plain DNS. That is ADR-0006's job.
- Clients see one resolver IP that never changes (the gateway), even as the
  upstream behind it moves between the ad-blocker and public resolvers.
