# 3. One admin account instead of a dedicated Ansible service account

## Status

Accepted

## Context

Automation against a device usually argues for a dedicated service account,
separate from the human login: narrower rights, its own credential to rotate,
clean attribution in logs.

On this router that separation buys little. RouterOS's `full` group is
all-or-nothing for the changes these roles make (interfaces, firewall, DHCP,
DNS, scheduler) — a "read-only Ansible" account could not apply anything. The
API credential and the interactive-login credential would both be `full`, both
live in the same Vault, and both be single-operator secrets. The second account
is extra surface — another entry that can be left enabled with a weak password,
another thing the `admin`-teardown step has to reason about — for no real
privilege boundary.

`ansible-homelab-template` already made the same call: one `ansible_user` that is
both the SSH login and the `become` account, not a split.

## Decision

Ansible authenticates over the API as the same account used for interactive SSH
login — `routeros_api_user` (`netadmin` in the templates), group `full`.
`routeros_common` ensures the account exists at group `full`; its password is set
once during bootstrap (`docs/bootstrap/`) and stored as
`vault_routeros_api_password`. No separate `ansible` account is created.

The built-in `admin` account is disabled in a deferred, explicitly-tagged step
(`routeros_common_disable_admin`, tags `disable-admin, never`) — only after the
managed account is confirmed working, never as part of a normal pass.

## Consequences

- One credential to manage and rotate, one account in `/user`, one thing the
  hardening steps have to account for.
- Log attribution does not distinguish a human at the keyboard from an Ansible
  run — both appear as the same user. Acceptable for a single-operator network;
  it would not be for a team.
- If that credential leaks, it is both the automation path and the login path.
  Mitigated by pinning the API service to the control node's address
  (`restrict-api`) and by key-based SSH, but the blast radius of the single
  secret is real.
- Should a genuine need for a second account appear later (a monitoring
  read-only user, a team), this decision is revisited and superseded rather than
  worked around.
