# Architecture Decision Records

This directory records the significant architectural decisions behind this
network-layer template, in a lightweight MADR-derived format (Status / Context /
Decision / Consequences). Each ADR documents a decision already made and in
force in the code — not a proposal.

A row may be listed as `Planned` (a reserved number, no file yet) when a
decision is known but lands with a role not yet written.

| # | Title | Status |
|---|-------|--------|
| [0001](0001-separate-repository-for-network-layer.md) | Separate repository for the network layer | Accepted |
| [0002](0002-routeros-api-modules-over-network-cli.md) | RouterOS API modules instead of network_cli | Accepted |
| [0003](0003-single-admin-account-over-dedicated-ansible-account.md) | One admin account instead of a dedicated Ansible service account | Accepted |
| [0004](0004-routeros-as-sole-advertised-dns-resolver.md) | RouterOS as the sole advertised DNS resolver | Accepted |
| [0005](0005-chr-test-vm-via-shell-script-over-vagrant.md) | CHR test VM via a shell script instead of Vagrant or an IaC provider | Accepted |
| [0006](0006-server-vlan-segmentation.md) | Server VLAN segmentation | Accepted |
| [0007](0007-crs310-switch-in-the-same-repo.md) | The CRS310 switch lives in this repository, not its own | Accepted |
| [0008](0008-qnap-as-two-firewall-endpoints.md) | The QNAP is two firewall endpoints | Accepted |
| [0009](0009-comment-anchored-entries-on-pk-less-paths.md) | Comment-anchored entries on PK-less paths | Accepted |
