# 2. RouterOS API modules instead of network_cli

## Status

Accepted

## Context

Ansible can drive a RouterOS device two ways:

- **`ansible.netcommon.network_cli`** with `ansible_network_os:
  community.routeros.routeros` — Ansible opens an SSH session and the collection's
  `command` module (plus a `routeros` cliconf/terminal plugin) screen-scrapes the
  CLI. Configuration is expressed as CLI command strings.
- **The `community.routeros.api*` modules** (`api`, `api_modify`, `api_info`,
  `api_find_and_modify`) — these talk to the RouterOS API service directly via
  the `librouteros` library. There is **no connection plugin**: the modules run
  on the control node (`connection: local`) and open their own API connection
  from the parameters given to them.

`api_modify` in particular takes a `path` (`ip firewall filter`, `interface
bridge port`, `system ntp client servers`, …) and a declarative `data` list, and
reconciles the device to it — including entry ordering and, opt-in, removal of
unmanaged entries. That is a much better fit for "the repo is the source of
truth" than assembling and diffing CLI strings.

The API service must be reachable from the control node. It is enabled during
the one-time bootstrap and, once the managed account is proven, pinned to the
control node's address (`roles/routeros_common/tasks/restrict_api_access.yml`).

## Decision

Use the `community.routeros.api*` modules, `api_modify` wherever a path is
supported. The play runs with `connection: local`, `gather_facts: false`, and a
`module_defaults` block for the `group/community.routeros.api` action group that
carries `hostname` / `username` / `password` / `tls` once for every task.
`librouteros` is a control-node dependency (`requirements-dev.txt`).

`network_cli` / the `command` module is kept only as an escape hatch for
imperative actions that have no API path (e.g. `/system/routerboard/upgrade`).

## Consequences

- Router configuration is declarative and diffable: each role states the desired
  content of a `path` and `api_modify` reconciles it, rather than the repo
  carrying a pile of `/…/add` command strings whose effect depends on current
  state.
- No SSH transport for configuration means no `ansible_user` / `become` and no
  host-key management for config runs; the connection surface is the API service
  alone, locked to one source address.
- The connection runs over the **plain API** (`tls: false`, port 8728), not
  api-ssl. api-ssl (8729) needs a certificate assigned to the service; with none,
  `librouteros` fails the handshake outright (`SSLV3_ALERT_HANDSHAKE_FAILURE`) —
  confirmed on the CHR VM. Provisioning a certificate just to wrap a
  control-node-to-router hop on the LAN is not worth it here: the API service is
  already pinned to the control node's address (`restrict-api`), and the LAN is
  the trust boundary — the same call `ansible-homelab-template` ADR-0007 makes
  for exposing Blocky's DNS and metrics ports to the LAN unencrypted. If this
  template is ever run across an untrusted segment, assign a certificate and flip
  `tls` back on before that happens.
- `api_modify`'s `handle_absent_entries: remove` / `handle_entries_content:
  remove` genuinely delete entries not present in `data`. On a shared path like
  `ip firewall filter` that will silently drop a rule someone added by hand — the
  roles use it deliberately and narrowly, and `CLAUDE.md` calls it out.
- A dependency on `librouteros` and on the API service being up; if the API
  service is misconfigured or the account locked, there is no CLI fallback path
  configured, only Winbox and the physical console equivalent (this router has
  none — see the Safe Mode / dead man's switch discussion in `CLAUDE.md`).
  `routeros_common` can also turn off MAC-Telnet / MAC-Winbox — the recovery
  path that does not need a working IP — but only as a deferred, explicitly
  tagged step (`disable-mac-recovery`), never by default, precisely because it
  narrows this fallback further.
- Safe Mode is a CLI/WinBox-session feature, but it is **not** scoped to changes
  made from its own session. Tested on the CHR VM: with a Safe Mode session held
  open in a terminal, an `api_modify` run over a *separate* API connection had
  its changes tracked by that Safe Mode session and rolled back when the session
  dropped. So Safe Mode is a real second safety net for API-driven runs, not
  just the dead man's switch (mechanism A).
  Recommendation for hardware runs of `routeros_interfaces` and
  `routeros_firewall`: open a Safe Mode session (`/system/safe-mode` or Ctrl+X in
  a terminal) in parallel with the Ansible run and keep it open until
  connectivity is confirmed — belt-and-braces with the dead man's switch.
