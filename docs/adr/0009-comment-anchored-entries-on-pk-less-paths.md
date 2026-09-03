# 9. Comment-anchored entries on PK-less paths

## Status

Accepted

## Context

`community.routeros.api_modify` reconciles declaratively by matching each entry
in `data` against the device by its **primary key**. Several RouterOS paths this
repo writes to have no primary key in the collection — `ip route` and
`ip firewall mangle` among them. On a PK-less path `api_modify` falls back to
matching on **full entry content**: change any managed field and the entry no
longer matches, so it is created anew, and because `handle_absent_entries`
defaults to `ignore` the previous entry is left in place.

This was verified on CHR 7.19.4, not assumed:

- **Test 1 — a hand-added static route (comment `manual-test`) survived an
  `api_modify` run untouched.** `api_modify` does not clobber entries it did not
  create.
- **Test 2 — `routeros_vlans.servers.gateway` was changed from `10.0.20.1` to
  `10.0.20.254` and the role re-run.** The result was two default routes:

  ```
  ;;; ansible:default-route
   0  As+ 0.0.0.0/0   10.0.20.1     main   1
  ;;; ansible:default-route
   1  As+ 0.0.0.0/0   10.0.20.254   main   1
  ```

  Both active, both distance 1, so RouterOS ECMPs across them (the `+` flag) and
  half the switch's outbound traffic goes via a gateway that does not exist.
  **The next run reported `changed=0`** — the idempotence gate does not see this
  drift at all.

The alternative was `handle_absent_entries: remove` on `ip route`. Rejected: it
deletes hand-added routes — including the uncommented default route that the
CRS310 bootstrap procedure in `docs/bootstrap/README.md` tells the operator to
add by hand — and `api_modify`'s internal add/remove ordering on a PK-less path
is not guaranteed, which on a console-less switch reached from another subnet is
a lockout risk.

## Decision

On a PK-less path where the repo owns only *some* of the entries:

1. Tag every managed entry with an `ansible:<purpose>` comment.
2. Pair the `api_modify` task with an explicit cleanup task — read `.id` plus the
   distinguishing fields via `community.routeros.api` (`query`), then a targeted
   `remove` in a loop filtered on that comment.
3. Run the cleanup **after** the `api_modify`, so the device is never left
   without the entry.

This is the pattern already used in
`roles/routeros_common/tasks/clear_rollback.yml`. `routeros_switch` now applies
it to its default route.

## Consequences

- The `routeros_switch` cleanup task was verified on CHR 7.19.4, so this is a
  tested convention, not just a reasoned one: applied against the drifted state
  it removed the stale `10.0.20.1` orphan and left the correct route alone
  (`changed=1`); reverting the gateway back was symmetric (`changed=2` — new
  route added, `10.0.20.254` removed); a from-scratch run on a clean device is a
  no-op (`changed=0`, empty remove loop, empty register does not break it); and
  the hand-added `manual-test` route plus every dynamic route (`DAd+`, `DAc`)
  were untouched throughout.
- The idempotence gate (a clean third run) does **not** catch this class of
  drift — `changed=0` was reported with two conflicting default routes present.
  PK-less paths need an explicit on-device state check after a change, not just a
  clean re-run.
- The cleanup filter must exclude entries without a comment
  (`selectattr('comment', 'defined')` first): dynamic routes (connected, DHCP)
  carry none, and `remove` fails on a dynamic entry.
- This does **not** apply where a role owns an entire path — the planned
  `routeros_firewall` ownership of `ip firewall filter` — there
  `handle_absent_entries: remove` is the correct choice.
- `ip firewall mangle` in `routeros_interfaces` (MSS clamping) still carries the
  unfixed version of this pattern: the interface names it keys on are stable, so
  the duplication risk is latent, and the comment there now says so.
