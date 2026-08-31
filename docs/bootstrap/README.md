# Bootstrap

## RouterOS CHR test VM

`chr-test-vm.sh` provisions a RouterOS CHR instance on the local libvirt/KVM
host to rehearse role changes before they touch real hardware.

```
./docs/bootstrap/chr-test-vm.sh [routeros-version]   # default: 7.19.4
```

It downloads the CHR image, converts it to qcow2, defines an isolated
`chr-wan` network, and starts a `chr-test` domain with two NICs — `ether1` on
the libvirt `default` NAT network (API / management) and `ether2` on `chr-wan`
(a stand-in WAN). The management address is printed at the end.

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

CHR verifies role logic, idempotence, the API connection, and firewall / DHCP
behaviour. It is not a performance test bed, and "it passed on CHR" is not
"it is safe on hardware" — the first real run still goes through the dead man's
switch (mechanism A) and, once verified, Safe Mode. See `CLAUDE.md`.

## One-time RouterOS bootstrap (outside Ansible)

Whether on CHR or the real router, do this once by hand — Winbox, or the CHR
console — before the first `site.yml` run:

1. Create the account Ansible will use (`routeros_api_user`, `netadmin` in the
   templates):

   ```
   /user add name=netadmin group=full password=<vault_routeros_api_password>
   ```

2. Import the interactive-login SSH public key. This is file-based and cannot be
   done over the API:

   ```
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
