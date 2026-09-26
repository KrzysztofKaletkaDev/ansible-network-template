# 11. A UDP 8555 exception in the segment boundary for go2rtc WebRTC

## Status

Accepted

## Context

This ADR covers one hole in the `main` -> `servers` boundary: UDP port 8555
from VLAN `main` to the "alma" VM, for WebRTC media from go2rtc — nothing
else about the camera view, and no other port or host.

The camera view (`kamery.*`, ADR-0011 in `ansible-homelab-template`) runs
go2rtc on alma behind Caddy. Five cameras play over MSE, which travels over
HTTPS through Caddy and is already covered by the "web to alma" accept
(ADR-0006). The sixth camera, the Eurolook, sends only H.265 with PCMA
audio; go2rtc transcodes it to H.264/AAC, and that transcoded stream
stuttered over MSE but plays smoothly over WebRTC. WebRTC media does not go
through a reverse proxy: after signalling over HTTPS, the browser sends and
receives RTP directly to and from go2rtc on UDP 8555. With `main` ->
`servers` default-deny (ADR-0006), that traffic is dropped and the tile
fails with `ERR_ADDRESS_UNREACHABLE`.

## Decision

`routeros_firewall` gets a fourth explicit accept in the forward chain,
above the `main` -> `servers` drop: UDP, destination port 8555, destination
`routeros_alma_ip`, source `routeros_vlans.main.subnet`, arriving on the
main bridge (`routeros_lan_bridge`). No TCP, no port range, not the whole
server VLAN, and not the WireGuard peers — `wg0` is in the `LAN` interface
list, so the rule matches the bridge, not the list. Trusted WireGuard peers
already reach the server VLAN through `wg-trusted`.

The rule's place is guaranteed by the role, not by hand: the filter table
is one ordered list applied with `ensure_order: true`, so the rule sits
where it is listed — right after the "web to alma" accept.

## Alternatives considered

- **A second go2rtc VM in VLAN `main`.** Rejected: it would move an
  infrastructure service into the least trusted segment, and go2rtc's API —
  which can rewrite its configuration and run commands — would be reachable
  from `main` without going through Caddy.

## Consequences

- An explicit exception in the segment boundary, limited to one UDP port on
  one host. Anything on VLAN `main` can send UDP to alma:8555; go2rtc is the
  only listener there.
- The Eurolook tile works from VLAN `main`. From outside the house there is
  no WebRTC path — the camera view is LAN-only anyway.
- If go2rtc moves to another host or another port, this rule has to move
  with it; `routeros_alma_ip` follows the `alma` reservation automatically,
  the port does not.
