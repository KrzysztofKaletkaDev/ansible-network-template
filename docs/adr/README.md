# Architecture Decision Records

This directory records the significant architectural decisions behind this
network-layer template, in a lightweight MADR-derived format (Status / Context /
Decision / Consequences). Each ADR documents a decision already made and in
force in the code — not a proposal.

| # | Title | Status |
|---|-------|--------|
| [0001](0001-separate-repository-for-network-layer.md) | Separate repository for the network layer | Accepted |
| [0002](0002-routeros-api-modules-over-network-cli.md) | RouterOS API modules instead of network_cli | Accepted |
| [0003](0003-single-admin-account-over-dedicated-ansible-account.md) | One admin account instead of a dedicated Ansible service account | Accepted |
| [0005](0005-chr-test-vm-via-shell-script-over-vagrant.md) | CHR test VM via a shell script instead of Vagrant or an IaC provider | Accepted |
