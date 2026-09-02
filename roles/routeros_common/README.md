# routeros_common

Baseline configuration for every RouterOS device in this repo (the edge router
and the CRS310 switch):

- `system identity`, `system clock` timezone, `system ntp client` + servers
- the admin/Ansible account (`routeros_api_user`), ensured at group `full`
- management-service hardening: `telnet`/`ftp`/`www`/`www-ssl`/`api-ssl` off,
  `api`/`ssh`/`winbox` on; `ip ssh strong-crypto`; RoMON off

## Staged first run (do not skip)

Three changes here can lock Ansible — or you — out of the router. Each sits
behind its own `never` tag and a gating variable, so a normal pass never runs
them. Do them in order, only once the previous step is proven.

1. **Full pass, without the lockout-prone bits:**

   ```
   ansible-playbook -i inventory/hosts.yml site.yml --skip-tags restrict-api
   ```

   Confirm the managed account (`routeros_api_user`) connects reliably on a
   second and third run, and that the third run reports `changed=0`.

2. **Only then**, pin the API service to the control node — set
   `routeros_controller_ip` to the real address Ansible connects from (not the
   `.example` placeholder) and run:

   ```
   ansible-playbook -i inventory/hosts.yml site.yml --tags restrict-api
   ```

   A wrong value makes the router unreachable over the API.

3. **Optionally**, once the managed account is proven, disable the built-in
   `admin` account — set `routeros_common_disable_admin: true` and run:

   ```
   ansible-playbook -i inventory/hosts.yml site.yml --tags disable-admin
   ```

4. **Last, and only with or after step 3**, turn off MAC-Telnet / MAC-Winbox /
   MAC-ping — set `routeros_common_disable_mac_recovery: true` and run:

   ```
   ansible-playbook -i inventory/hosts.yml site.yml --tags disable-mac-recovery
   ```

   This removes the only way onto the router without a working IP, on hardware
   that has no serial console. Never do it before normal IP connectivity and the
   managed account are both confirmed.

The account password itself is set during the one-time bootstrap
(`docs/bootstrap/`), never rewritten by this role.

## Dead man's switch

`tasks/safety_snapshot.yml` and `tasks/clear_rollback.yml` implement mechanism A
(see `CLAUDE.md`), gated by `routeros_enable_dead_mans_switch` (on by default,
off for the `test` group). `routeros_interfaces` and `routeros_firewall` pull in
`safety_snapshot.yml` at the top of their run; after a confirmed change, disarm
it with:

```
ansible-playbook -i inventory/hosts.yml site.yml --tags clear-rollback
```
