# Netcontroller Notes

## Current direction
- Use a dedicated configuration play: `playbooks/configure-netcontroller.yml`
- DNS setup via `playbooks/roles/add_unbound`
- DHCP setup via `playbooks/roles/add_kea`
- start with dns/unbound role, without dhcp/kea

## DNS rollout behavior
- `playbooks/configure-netcontroller.yml` rolls Unbound updates one resolver at a time
- passive resolvers are updated first, then the active resolver last
- after each resolver update, the controller verifies every effective DNS A record with `dig`
- the rollout also verifies that the autoinstall seed host under `fritz.box` resolves the same way through Unbound as it does through the router DNS
- set `unbound_active_resolver_host` to pin which resolver should be treated as active
- if `unbound_active_resolver_host` is not set, the last host in the `unbound` inventory group is treated as active

## split Kea install and configure
- Kea package/service bootstrap is stable and low-risk
- DHCP configuration will likely depend on inventory-driven subnet, reservation, and interface data
- DNS integration is still undecided, so keeping config separate avoids baking in the wrong coupling

## DNS status
- Inventory owns:
  - `homelab_dns_blocklist_sources`
  - `homelab_dns_records` (see context/guides/dns-records-guide.md)
  - `homelab_dns_local_tld`
  - Host-level `dns_aliases` in each host's host_vars

See [DNS Records Guide](../guides/dns-records-guide.md) for details.
