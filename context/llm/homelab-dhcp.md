# DHCP Notes

## Current direction
- Use a dedicated install play: `playbooks/install-dhcp.yml`
- Use a focused install role: `playbooks/roles/kea-install`
- Add shared DNS setup via `playbooks/roles/unbound-setup`
- Model DNS as two hosts: `unbound1` and `unbound2`
- Keep Kea install and Kea configure split for now

## Why split install and configure
- Kea package/service bootstrap is stable and low-risk
- DHCP configuration will likely depend on inventory-driven subnet, reservation, and interface data
- DNS integration is still undecided, so keeping config separate avoids baking in the wrong coupling

## DNS status
- Inventory owns:
  - `homelab_dns_blocklist_sources`
  - `homelab_dns_records`
- `install-dhcp.yml` now installs Kea on `kea` and Unbound on `unbound`
