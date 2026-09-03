# routeros_dns

The router's DNS layer. Runs only where `routeros_device_class == 'edge'`.
Implements **ADR-0004** (RouterOS as the sole advertised resolver).

- `/ip dns` — `allow-remote-requests`, cache, `servers` forwarding to
  `routeros_dns_primary_upstream` (the ad-blocking resolver, derived from
  `routeros_alma_ip`)
- two `system script`s (`ansible-dns-fallback-down` / `-up`) that set
  `/ip dns servers` to `routeros_dns_fallback_upstream` / back to the primary
- a `tool netwatch` entry watching the primary; `down-script` / `up-script` run
  the two scripts

## PK-less paths (ADR-0009)

`ip dns static` and `tool netwatch` have no primary key in `api_modify`, so a
changed field would add a duplicate. Each managed entry carries an
`ansible:dns-static` / `ansible:dns-netwatch` comment and a cleanup task removes
tagged entries that no longer match (static: `name` not in the list; netwatch:
`host` not the current primary). Manual, un-tagged entries are never touched.

The Netwatch cleanup is keyed on `host` only — changing just the interval or a
script name would leave a duplicate. Those effectively never change; renumbering
the resolver (which changes `host`) is the real case.

## Fallback behaviour

While the primary resolver is down, Netwatch points `/ip dns` at public
resolvers — the internet works, ad-blocking does not, until the primary is back.
If the primary is down *at apply time*, the `/ip dns` task and the Netwatch
down-script fight over `servers` every run; don't push config during an outage.

## Rehearsing on CHR

Set `routeros_device_class: edge` in `group_vars/test/vars.yml`.

```
ansible-playbook -i inventory/hosts.yml site.yml --limit test --check --diff
ansible-playbook -i inventory/hosts.yml site.yml --limit test --diff
ansible-playbook -i inventory/hosts.yml site.yml --limit test --diff   # changed=0
```

Functional test: block traffic to `routeros_dns_primary_upstream` on the CHR
firewall, confirm Netwatch runs the down-script and `/ip dns servers` flips to
the fallback; unblock and confirm it flips back.
