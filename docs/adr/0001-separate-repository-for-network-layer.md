# 1. Separate repository for the network layer

## Status

Accepted

## Context

The edge router is being replaced — a consumer router running OpenWrt gives way
to a MikroTik device running RouterOS, mainly because WireGuard throughput on the
old hardware capped the VPN at a fraction of the available symmetric line rate.
The new router's configuration — LAN bridge, tagged-VLAN PPPoE uplink, a
WireGuard server, DHCP, DNS forwarding, and the LAN firewall — has to be
automated somewhere.

The obvious place would be the existing `ansible-homelab-template` repository,
which already automates the single AlmaLinux host sitting behind this router. But
the two layers differ in ways that matter:

- **Blast radius.** A bad change to a container role breaks one service. A bad
  change to the router's firewall or bridge cuts every device off the network —
  including the control node — on hardware that has no serial console.
- **Ansible collection and connection model.** The homelab repo is built on
  `community.docker` / `ansible.posix` over SSH with `become`. This layer is
  built on `community.routeros` talking to the RouterOS API, with
  `connection: local` and no privilege escalation. One repo would mean one
  `ansible.cfg`, one `requirements`, and one set of CI assumptions trying to fit
  both.
- **Change cadence and review lens.** Router changes are rare, high-stakes, and
  want a Safe-Mode / dead-man's-switch workflow wrapped around every apply.
  Service changes are frequent and low-stakes. Sharing a repo forces every
  service tweak through the router's review lens, and vice versa.

`ansible-homelab-template`'s own ADR-0004 ("Separate repositories for
infrastructure and site content") applied exactly this reasoning to split
infrastructure code from site content. The same logic applies here, one level
up — between two infrastructure repositories.

## Decision

Keep the network layer in its own repository, `ansible-network-template`, with
its own `ansible.cfg`, `collections/requirements.yml` (`community.routeros`),
inventory, Vault, CI pipeline, and ADR history.

It deliberately shares *conventions* with `ansible-homelab-template` — Ansible
task names in Polish, English commit messages (Conventional Commits) and code
comments, secrets only ever committed as `*.example`, and the same
`.ansible-lint` / `.yamllint` / pre-commit setup — but nothing operational.

## Consequences

- Router changes ship on their own history and review, with a workflow (Safe
  Mode, dead man's switch, staged first runs) that would be noise in the service
  repo.
- The two repositories must be kept coherent by hand. The LAN subnet, the
  ad-blocking DNS resolver's address, and the DNS-interception design all appear
  in both, and a change on one side is not enforced on the other.
- Two repositories, two CI pipelines, and two Vault passwords to manage instead
  of one — a real coordination cost for a single maintainer, accepted in
  exchange for the isolation.
- "How the homelab is deployed" now lives in two places; the README of each repo
  points at the other so the split is discoverable.
