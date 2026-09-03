# 8. The QNAP is two firewall endpoints

## Status

Accepted

## Context

One physical box — a QNAP NAS — carries two very different network services:

- **Native QTS**: Qsync (versioned file backup), QVR Pro (the camera NVR), File
  Station. First-party QNAP software, closed, with its own account model.
- **The "alma" VM**: an AlmaLinux guest under Virtualization Station running the
  self-hosted stack in Docker — a reverse proxy, the ad-blocking DNS resolver, a
  password manager.

The firewall rules for the two have nothing in common. QVR Pro is reached by a
handful of trusted clients on `:443`. The reverse proxy is reached by the whole
LAN on `:80` / `:443`. The ad-blocker must be exempt from the `:53` redirect and
the DoH block. Treating "the QNAP" as one firewall object would mean either
opening the union of all that to everyone, or writing port-and-source rules so
tangled that the next change gets made by widening them.

## Decision

Give the two a **separate IP address each** on the server VLAN —
`routeros_qnap_native_ip` for native QTS, `routeros_alma_ip` for the VM (the VM
already has its own virtual NIC, so this costs nothing) — and write firewall
rules per address:

- `dst-address = routeros_alma_ip`, `:80,443`, source = anyone on the LAN;
- `dst-address = routeros_qnap_native_ip`, `:443`, source = `qnap-native-access`
  only;
- `routeros_alma_ip` in `doh-exempt` and `dns-nat-exempt`.

Both listen on `:443` — no collision, because the rules match on destination
address, not just port.

## Consequences

- `routeros_servers_vlan_hosts` must contain entries named exactly `qnap-native`
  and `alma`; `routeros_qnap_native_ip` / `routeros_alma_ip` resolve them with
  `selectattr | first`. `routeros_dhcp` asserts both names are present so a
  drifted local `group_vars` fails early, not deep in this role.
- A DNS record or a bookmark that points at "the NAS" has to say *which* — the
  native admin UI and the proxied services are now different hosts.
- If the VM is ever moved off the QNAP (onto one of the mini-PCs), only
  `routeros_alma_ip`'s host entry changes; the native-QTS rules are untouched.
