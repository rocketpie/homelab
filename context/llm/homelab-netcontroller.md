# Netcontroller Notes

## Current direction
- Use a dedicated install play: `playbooks/install-netcontroller.yml`
- DNS setup via `playbooks/roles/unbound-setup`
- DHCP setup via `playbooks/roles/kea-install`
- start with dns/unbound role, without dhcp/kea

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
