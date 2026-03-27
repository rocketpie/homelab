# DHCP Notes

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
  - `homelab_dns_records`
- The `kea` inventory group is intentionally empty for now
