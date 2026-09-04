# Bootstrap

## RouterOS CHR test VM

`chr-test-vm.sh` provisions a RouterOS CHR instance on the local libvirt/KVM
host to rehearse role changes before they touch real hardware.

```
./docs/bootstrap/chr-test-vm.sh [routeros-version]   # default: 7.19.4
```

It downloads the CHR image, converts it to qcow2, defines an isolated
`chr-wan` network, and starts a `chr-test` domain with four NICs — `ether1` on
the libvirt `default` NAT network (API / management), `ether2` on `chr-wan`
(a stand-in WAN), and `ether3` / `ether4` back on `default` as LAN stand-ins so
the bridge-port loop and the bridge VLAN table can be rehearsed. The management
address is printed at the end.

Tear down with:

```
virsh destroy chr-test && virsh undefine chr-test --remove-all-storage
```

The downloaded `chr-*.img*` / `chr-*.qcow2` files land next to the script and
are git-ignored.

### What CHR does NOT test

- **PPPoE over VLAN 35** — needs a real session with the ISP; it cannot be
  reproduced in a VM.
- **PoE** — the RB5009's powered ports have no CHR equivalent.
- **The hardware switch chip and fasttrack** — CHR forwards purely in software.
- **Real throughput** — the CHR Free licence caps every interface at 1 Mbit/s.
- **`--check` does not validate interface existence.** The `invalid value for
  argument interface` error only surfaces during an actual API call, not in
  check mode. If `routeros_lan_bridge_ports` (or the VLAN table) lists interfaces
  the CHR VM does not have — e.g. `ether3`–`ether8` / `sfp-sfpplus1` on a smaller
  instance — `--check` passes but the real run fails. A typo in a port name is
  the same trap: the RB5009's SFP+ port is `sfp-sfpplus1`, not `sfp-plus1`, and
  the wrong name would sail through check mode. Match the port list to the VM's
  NIC count, or give the VM enough NICs via `chr-test-vm.sh`.
- **The trunk between two physical devices.** `routeros_switch` on a single CHR
  instance exercises the VLAN-table syntax and idempotence, but not the RB5009 ↔
  CRS310 trunk itself or how the hardware switch chip tags frames — those only
  show up on real hardware.
- **Mechanism C (management port inside the bridge).** A deliberate rehearsal
  with `ether1` added to `routeros_lan_bridge_ports` completed cleanly on CHR
  (`ok=25 changed=24 failed=0`). It only worked because CHR's management address
  (libvirt's `192.168.122.0/24`) and the bridge address (`10.0.0.0/24`) are on
  **different subnets**: RouterOS migrated the management address onto the bridge
  without a conflict, leaving the original `ether1` entry flagged `S` (SLAVE),
  and L2 was never actually lost. On the RB5009 both addresses live in **one**
  subnet — the bridge takes over the very network the operator is connected
  through and claims the gateway address at the same time, while the hardware
  switch chip is reprogrammed. That is a materially different operation.
  Mechanism C stands unchanged, and a clean CHR run with the management port
  bridged is **not** evidence that it is safe on hardware. This has since been
  settled directly on the RB5009 — the same run fails on the first bridge-port
  item with a timeout. See "Mechanism C, in operational form" below.

CHR verifies role logic, idempotence, the API connection, and firewall / DHCP
behaviour. It is not a performance test bed, and "it passed on CHR" is not
"it is safe on hardware" — the first real run still goes through the dead man's
switch (mechanism A) and, once verified, Safe Mode. See `CLAUDE.md`.

## Step zero on the RB5009: unlock `device-mode` (or mechanism A is dead)

A factory RB5009 ships with `/system device-mode mode=home`, which has
`scheduler=no`. The dead man's switch (mechanism A) arms a `/system scheduler`
entry, so on an untouched box it fails with **`not allowed by device-mode`** —
and mechanism A is the layer that saves you when a run wedges the router.

Do this before anything else, including the reset:

```
/system device-mode print                      # confirm mode=home, scheduler=no
/system device-mode update scheduler=yes
```

RouterOS then waits for a **physical confirmation within 5 minutes**: press the
**Reset button** on the box. The router reboots by itself — that reboot is the
confirmation succeeding, not a fault. Verify afterwards:

```
/system device-mode print                      # scheduler=yes
```

Notes from the hardware run:

- **`mode=enterprise` does not exist in 7.23.4** (`input does not match any value
  of mode`). Do not try to switch the whole mode; update the single flag.
- Changing `device-mode` cannot be done over the API alone by design — the
  physical button press is the point. It is a bootstrap step, never a role.
- `routeros_dns` also installs `/system script` entries driven by a Netwatch
  hook. Whether `home` mode blocks those the same way it blocks the scheduler was
  **not verified** — if the DNS fallback never fires on hardware, check
  `device-mode` before debugging the role.

## Factory-config teardown on the RB5009 (do this first, on hardware)

A factory RB5009 ships with a `defconf`: a bridge **named `bridge`** holding
`ether2`–`ether8` + the SFP+ port, `192.168.88.1/24` on it, a DHCP server, a
pool, firewall rules, a `masquerade`, **and pre-populated `LAN` / `WAN`
interface lists** (`ether1` → WAN, `bridge` → LAN).

`routeros_interfaces` builds a **different** bridge (`bridge-lan`). A port cannot
be in two bridges, so "Podłącz porty dostępowe" fails on the first run; and the
interface-list tasks use `handle_absent_entries: ignore`, so the `defconf` list
members survive and pollute `LAN` / `WAN`. Wipe the `defconf` before the first
Ansible run.

**Before the reset:**

1. **Update RouterOS** to the branch the roles were tested against on CHR
   (7.19.x). This needs the router temporarily online — plug its WAN port into an
   existing network with internet, `/system package update check-for-updates`,
   `install`, let it reboot.
2. **Write down the serial number and the WAN port's MAC** (`/system routerboard
   print`, `/interface ethernet print`). You need them for Netinstall if
   MAC-Winbox ever fails to find the box.

**The reset:**

```
/system reset-configuration no-defaults=yes skip-backup=yes
```

This leaves the router with **no address and no configuration**. The only way
back in is **Winbox → Neighbors → click the MAC** (MAC-Winbox). This is safe
**only** with a laptop cabled straight into a router port. MAC-Winbox works
because `routeros_common_disable_mac_recovery` is `false` by default — if you
have already run `--tags disable-mac-recovery` on this box, that path is gone
and you must use Netinstall instead.

**After the reset, over Winbox / MAC-Winbox:**

```
/user add name=netadmin group=full password=<vault_routeros_api_password>
/ip service enable api
/ip address add address=192.168.99.1/24 interface=ether3
```

(`netadmin` here is a placeholder for whatever `routeros_api_user` is set to —
create the account under that name.)

**Put the temporary address on a LAN access port that you have removed from
`routeros_lan_bridge_ports`** — plain mechanism C. `ether3` above is an example;
use whichever port the cable is actually in, and take that same port out of
`routeros_lan_bridge_ports` in the local `group_vars/all/vars.yml` before the
run. A port that is in neither the bridge nor an interface list keeps working:
it never joins `bridge-lan`, and the firewall's `input` chain ends with
`drop in-interface-list=WAN`, not `drop all`, so traffic arriving on a
list-less interface falls through to the default `input` policy (accept).

> **Do not use the WAN port for this.** An earlier revision of this document put
> the temporary address on `ether2`. That is now a lockout:
> `routeros_interfaces` puts `routeros_wan_interface` into interface list `WAN`,
> and the `input` chain drops everything from `WAN` except WireGuard. ICMP still
> answers (the `accept protocol=icmp` rule sits above the drop and matches on any
> interface), so the router looks alive while SSH and the API are gone — see
> "Symptom: the router pings but SSH and the API are dead" below.

Then import the SSH key and confirm login (next section), point the `edge`
inventory group at the temporary address, and run `routeros_common` +
`routeros_interfaces`. **Remove the temporary address and put the port back into
`routeros_lan_bridge_ports` only after** the router is cabled into the real
network and connectivity via the `bridge-lan` gateway address is confirmed.

### `routeros_controller_ip` must match the address you connect from *now*

`routeros_controller_ip` is the control node's own address, and it is used in two
places that both assume it is current for **this** run:

- `roles/routeros_common/tasks/restrict_api_access.yml` — pins
  `/ip service api address=<controller>/32` (deferred; `--tags restrict-api`);
- the firewall rule `ansible: fwd accept control node to switch`, which is what
  lets Ansible reach the CRS310's management address in the server VLAN.

During bootstrap the control node is cabled into the router and sits in the
temporary subnet (`192.168.99.0/24` above, or `192.168.88.0/24` on a
button-reset box) — **not** in the production LAN, and not on the Wi-Fi address
it will use afterwards. Set `routeros_controller_ip` to the cabled address for
the bootstrap runs and change it back once the router is in place, or the
switch rule points at an address that is no longer yours.

### Symptom: the router pings but SSH and the API are dead

Almost always the interface you are connected through ended up in interface list
`WAN`. The `input` chain accepts ICMP before it drops `WAN`, so ping keeps
working while TCP 22 / 8728 is dropped. Check, over Winbox / MAC-Winbox:

```
/interface list member print          # is your port in WAN?
/ip service print                     # did a restrict-api run pin an address?
/ip firewall filter print             # confirm the input chain order
```

Two ways to get there: the temporary address on the WAN port (above), or a
button-reset box whose `defconf` `WAN` list still holds `ether1` — the
interface-list tasks use `handle_absent_entries: ignore`, so stale `defconf`
members are not cleaned up. Fix the list membership, do not disable the rule.

## Recovering from a hardware reset button press

The reset button is **not** the same as `reset-configuration no-defaults=yes`.
It restores the **full `defconf`**, so you land in a state this document
otherwise never describes:

- a bridge literally named `bridge`, holding `ether2`–`ether8` + the SFP+ port;
- `192.168.88.1/24` on that bridge;
- a DHCP server, its pool and its network entry; a `dhcp-client` on `ether1`;
- populated `LAN` / `WAN` interface lists;
- the `defconf` firewall rules and `masquerade`.

`routeros_interfaces` builds a *different* bridge (`bridge-lan`), and a port
cannot be in two bridges, so "Podłącz porty dostępowe" fails on the first item.
Tear the `defconf` down first.

### Order matters — the address goes on before the bridge comes off

`192.168.88.1` lives on the `bridge` interface. Removing that address, or pulling
your port out of the bridge, drops your session. **Running (c)/(d) before (a) cut
the connection twice on hardware.** Paste these **one at a time**, over Winbox /
MAC-Winbox, with the cable in the port used in step (a):

```
# (a) address on the port the cable is in. It shows as SLAVE for now - the port
#     is still a bridge member, so this address is not yet doing anything.
/ip address add address=192.168.99.1/24 interface=ether3

# (b) drop the DHCP machinery (order within this step does not matter)
/ip dhcp-client remove [find]
/ip dhcp-server remove [find]
/ip dhcp-server network remove [find]
/ip pool remove [find]

# (c) remove the defconf address from the bridge
/ip address remove [find interface=bridge]

# (d) take the ports out of the bridge. THIS is where ether3 stops being a
#     slave and the address from (a) starts working on its own.
/interface bridge port remove [find bridge=bridge]
```

**Stop here and verify from a second terminal** before going further:

```
ping 192.168.99.1          # must answer
ssh netadmin@192.168.99.1  # must connect
```

If it does not answer, you still have Winbox / MAC-Winbox on the open session —
fix it there. Do not continue with a broken management path.

```
# (e) now the empty bridge can go
/interface bridge remove [find name=bridge]

# (f) clear the defconf interface-list members. The role's interface-list tasks
#     use handle_absent_entries: ignore, so anything left here survives every
#     run and pollutes LAN / WAN - a stale ether1 in WAN is enough to have the
#     firewall drop your SSH and API while ICMP still answers.
/interface list member remove [find]
```

The `defconf` firewall rules and `masquerade` need no manual cleanup:
`routeros_firewall` owns `ip firewall filter` and `ip firewall nat` outright
(`handle_absent_entries: remove`) and replaces them.

From here, continue with the account / SSH key / API steps below.

## Mechanism C, in operational form

**The port your cable is in must not be in `routeros_lan_bridge_ports` during
the first run.** Take it out in the local `group_vars/all/vars.yml`, run, confirm
connectivity through the `bridge-lan` gateway address, move the cable to a port
that is already a bridge member, and only then put the original port back with a
second, deliberate run.

This is not theoretical. A run with the cable's port left in the list fails on
the first item of the bridge-port loop and takes the rest of the play with it:

```
TASK [routeros_interfaces : Podłącz porty dostępowe] ***
failed: (item=ether3) => TimeoutError: timed out
failed: (item=ether4) => "Brak trasy do hosta"
failed: (item=ether5) => "Brak trasy do hosta"
```

The port joins `bridge-lan`, L2 goes away before the bridge has an address, and
every remaining item fails with no route to host. Note that this is a **stronger**
result than the CHR note above ("CHR cannot reproduce mechanism C structurally"):
on hardware the failure is direct and immediate.

## One-time RouterOS bootstrap (outside Ansible)

Whether on CHR or the real router, do this once by hand — Winbox, or the CHR
console — before the first `site.yml` run:

1. Create the account Ansible will use (`routeros_api_user`, `netadmin` in the
   templates — use whatever name that variable is set to):

   ```
   /user add name=netadmin group=full password=<vault_routeros_api_password>
   ```

2. Transfer the interactive-login SSH public key onto the router and import it.
   The import is file-based and cannot be done over the API. Copy the key file
   first — either drag it into **Winbox → Files**, or `scp` it before the
   account is locked down, e.g.:

   ```
   scp ~/.ssh/id_ed25519.pub admin@192.168.88.1:/netadmin.pub     # or 192.168.99.1 post-reset
   /user ssh-keys import user=netadmin public-key-file=netadmin.pub
   ```

3. Enable the API service:

   ```
   /ip service enable api
   ```

4. Confirm you can reach the box as `netadmin` (SSH key and API), then point the
   relevant inventory group at it and run `site.yml`.

Pinning the API service to the control node's address and disabling the
built-in `admin` account are deferred steps owned by the `routeros_common`
role — see `roles/routeros_common/README.md`.

## One-time CRS310 bootstrap (cable it straight to a laptop)

The trunk carries VLAN 1 **tagged**, so there is no untagged traffic on the
trunk cable. A factory switch does not know the tags and is unreachable over the
trunk. Bootstrap it before it goes into place:

1. Connect a laptop directly to any access port (or reach it with MAC-Winbox).
2. Do it by hand — Winbox / WebFig only for this step (ADR-0002 still applies):

   ```
   /user add name=netadmin group=full password=<vault_routeros_api_password>
   /user ssh-keys import user=netadmin public-key-file=netadmin.pub
   /interface bridge set bridge vlan-filtering=no
   /interface vlan add name=vlan20-servers interface=bridge vlan-id=20
   /ip address add address=<routeros_switch_mgmt_address> interface=vlan20-servers
   /ip route add dst-address=0.0.0.0/0 gateway=<servers VLAN gateway>
   /ip dhcp-client remove [find interface=bridge]
   /ip service enable api
   ```

3. Confirm you can log in as `netadmin` over that address.
4. **Only now** move the switch into place, cable the trunk, and let Ansible
   (`--limit switches`) take over. `routeros_interfaces` must already be applied
   on the RB5009 or the switch's management address is not routed yet.

Do not try to bootstrap the switch over the trunk.
