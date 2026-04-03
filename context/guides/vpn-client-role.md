# VPN Client Role

This guide covers the `add_vpn_client` role and the related VM rollout paths.

## Scope

The role installs a WireGuard client on Ubuntu VM hosts by:

- installing `wireguard-tools`
- rendering a vaulted client config into `/etc/wireguard/<interface>.conf`
- enabling and starting `wg-quick@<interface>`

It is intentionally host-side only. Generating the per-host client config on the
WireGuard gateway is still an external step.

## Vaulted Host Variable

Each host should store its full client config in the host vault:

```yaml
add_vpn_client_config: |
  [Interface]
  Address = 10.13.0.10/32
  PrivateKey = SECRET_VALUE_HERE

  [Peer]
  PublicKey = SECRET_VALUE_HERE
  AllowedIPs = 10.13.0.0/24
  Endpoint = vpn.example:51820
```

The repo intentionally keeps the whole config vaulted instead of splitting out
the private key.
After adding the vaulted host variable, run `build.ps1` so the matching
`# vault.yml:` template comment in the host file stays in sync.

Each host that publishes `.vpn.lan` DNS names should also define its non-secret
overlay IPv4 in host vars:

```yaml
add_vpn_client_overlay_ipv4: "10.13.0.10"
```

This keeps `.vpn.lan` DNS generation independent from cross-host access to
vaulted content. The `add_vpn_client` role validates that the `Address` inside the
vaulted config matches `add_vpn_client_overlay_ipv4`.

## Rollout Paths

For existing VMs:

```powershell
pwsh run.ps1 add-vpn-client.yml
```

For network-day-2 updates, `playbooks/set-vm-network.yml` also reapplies the
WireGuard client config when the vaulted variable is present.

For newly provisioned VMs, `playbooks/add-vm.yml` installs the VPN client during
guest configuration when the vaulted variable is present.

## DNS Behavior

Host-level `.vpn.lan` names gathered from `dns_aliases` or Docker reverse proxy
bindings use `add_vpn_client_overlay_ipv4`. Inventory-derived `.vpn.lan` names
follow the same rule. If a host advertises a `.vpn.lan` name without
`add_vpn_client_overlay_ipv4`, `add_unbound` fails rather than publishing the
LAN IP by mistake.
