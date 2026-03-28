# DNS Records Configuration Guide

## Overview

The homelab DNS system uses two mechanisms to register DNS records:

1. **Global DNS records** - defined in `inventory/group_vars/all/dns.yml`
2. **Host-level aliases** - defined in each host's `inventory/host_vars/{hostname}/host.yml`

Both are processed by the `unbound-setup` role and merged together into the DNS resolver.

## Global DNS Records (`dns.yml`)

### Structure

DNS records are organized by IP address, with each IP mapping to a list of hostname aliases:

```yaml
homelab_dns_records:
  "192.168.178.55":
    - "dockerhost1"
    - "docker.backup"
    - "minio.internal"
  "10.13.0.3":
    - "gateway.vpn"
  "10.13.0.6":
    - "dockerhost1.vpn"
```

**Key points:**
- Map keys are IP addresses (strings, must be quoted)
- Map values are lists of DNS names/aliases
- Multiple aliases can point to the same IP
- Names are automatically qualified with the local TLD (default: `.lan`)

### Local TLD

By default, names are qualified as `{name}.lan`. To change this globally:

```yaml
homelab_dns_local_tld: "internal"  # Results in names like "dockerhost1.internal"
```

## Host-Level DNS Aliases

Individual hosts can define additional DNS aliases in their host variables file.

### Example: `host_vars/restic1/host.yml`

```yaml
vmid: 22001
proxmox_node: "n2"

# DNS aliases for this host
dns_aliases:
  - "backup.lan"
  - "archive.lan"
  - "storage.local"

# ... other config ...
```

**Key points:**
- `dns_aliases` is an optional list
- These names resolve to the host's `ansible_host` (primary inventory IP)
- Useful for service-specific names without modifying central DNS records

### Example: Adding Aliases to `netcontroller1`

```yaml
# inventory/host_vars/netcontroller1/host.yml

vmid: 23002
proxmox_node: "n2"

# Optional DNS names for this host
dns_aliases:
  - "dns1.lan"
  - "dhcp1.lan"

# ... other config ...
```

## How It Works

When the `unbound-setup` playbook runs:

1. **Global records are flattened**
   - IP→aliases map is converted to individual name/value pairs
   - Each alias becomes a separate DNS A record

2. **Host aliases are collected**
   - For each host with an `ansible_host` defined
   - Any `dns_aliases` entries are converted to name/value pairs
   - Uses the host's IP as the target

3. **Records are merged**
   - Global records and host aliases are combined
   - Validated for required fields (name, value)
   - Written to Unbound config

4. **Unbound generates local-data entries**
   - Template converts each record to Unbound syntax
   - `local-data: "name. IN A ip_address"`

## Naming Conventions

### Reserved/Special Suffixes

- `.lan` - homelab TLD (IANA / ICANN reserved `.internal` for this purpose)
- `.vpn` - VPN overlay subdomain
- `.local` - mDNS reserved

### Examples

| Use Case | Name | Result |
|----------|------|--------|
| Primary service | `service` | `service.lan` |
| Alternative name | `service`, `s-alias` | both resolve to same IP |
| VPN access | `service.vpn` | `service.vpn` resolves to VPN IP |

## Common Patterns

### Multiple names for one service

```yaml
# dns.yml
homelab_dns_records:
  "192.168.1.50":
    - "plex"
    - "media-server"
    - "movies"
```

### Service-specific aliases

```yaml
# Global: main hostname
# host_vars/myserver/host.yml:
dns_aliases:
  - "web.lan"
  - "api.lan"
  - "admin.lan"
```

## Validation

The `unbound-setup` role validates all DNS records:

- `name` field must be present and non-empty
- `value` field must be present and non-empty
- `value` must be a valid IP address (parsed by Unbound)

If validation fails, the playbook will error with details about the invalid record.

## Troubleshooting

### Records not resolving

1. Check DNS records were created:
   ```bash
   ansible-playbook install-netcontroller.yml
   ```

2. Check Unbound config was generated:
   ```bash
   ssh <netcontroller> cat /etc/unbound/unbound.conf.d/homelab-records.conf
   ```

3. Check record format (should be `local-data:` entries)

### Changes not taking effect

- Rerun `install-netcontroller.yml` to regenerate config
- Reload Unbound: `systemctl reload unbound`

### Ambiguous/conflicting names

- Ensure global records and host aliases don't create conflicts
- Same name pointing to different IPs will cause last-write-wins behavior
- Check logs for validation errors
