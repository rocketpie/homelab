# Homelab Network Design

Status: **draft, design only**. Nothing in this directory changes infrastructure.

This directory is the design home for the homelab network: public edge, VPN,
internal DNS, naming, TLS, DHCP, and firewall boundaries. It complements the
inventory-driven implementation in `inventory/` and `playbooks/`; it does not
replace the host-specific runbooks.

## Goals

- Host internet-facing services on the public domain: VPN gateway, website, and
  optionally a public status page.
- Keep everything else reachable only from the VPN or the home LAN.
- Let a phone join the VPN and reach internal services (Immich, Grafana,
  smarthome, backups, management) with simple DNS names and trusted TLS.
- On the home WLAN, reach the same services **without** the VPN, without a
  round trip through the public gateway, and without VPN setup on every device.
- Run DNS-based ad blocking for all clients, with internal service names served
  by the same resolver.
- Make service placement irrelevant to the network design: a public service may
  live on the gateway host or in the homelab, and the gateway should still be
  able to reverse-proxy it.

## Non-goals

- Building or migrating anything in this iteration.
- Replacing the FritzBox as router, firewall, or DHCP server (for now).
- A full enterprise segmentation project (VLANs, 802.1X, per-device policy).
- Public DNS automation. Authoritative DNS for `co3d.eu` stays self-hosted and
  manually managed unless a later decision changes that.

## Design principles

1. **One name per service.** A service should have one hostname that works on
   the home WLAN and over the VPN. Avoid parallel `.lan` and `.vpn.lan` names
   as the long-term model.
2. **Location independence.** The gateway routes to a service endpoint; whether
   that endpoint is a local container, a LAN IP, or a VPN address is an
   implementation detail.
3. **Least privilege at the boundary.** Routing a subnet into the VPN is not the
   same as exposing it. The home gateway enforces an allowlist of service
   IPs/ports.
4. **DNS is the control plane.** Names, ad blocking, and access paths are
   expressed in DNS and inventory, not in per-device hosts files.
5. **Fail safe for the home LAN.** If the public gateway or VPN is down, home
   devices must still resolve and reach internal services on the LAN.
6. **TLS identity matches the name.** Internal certificates come from the
   homelab CA; public certificates come from Let's Encrypt at the edge.

## Current state (as-is)

| Area | Current implementation |
| --- | --- |
| Home LAN | `192.168.178.0/24`, FritzBox at `.1`, DHCP `.20`-`.191`, homelab static block `192.168.178.192/26` |
| Guest WLAN | `192.168.179.0/24`, separate from the home LAN |
| Public edge | `gateway2`, Caddy + wg-easy, UFW + fail2ban, Let's Encrypt via Caddy |
| VPN | wg-easy on `gateway2`, UDP 51820, per-host clients in `10.13.0.0/24` |
| DNS | Unbound on `netcontroller1`/`netcontroller2`, active/passive rollout, blocklists, local `.lan` records |
| DHCP | FritzBox; Kea role exists but is not deployed |
| Internal TLS | Homelab CA in `context/homelab-ca/`, per-host certificates, HAProxy on Docker hosts |
| Public names | `co3d.eu` and `vpn.co3d.eu` |
| Public-to-internal data plane | Not implemented; Caddy only reaches its own Docker network today |

Relevant existing docs and code:

- `context/guides/homelab-network-map.md`
- `context/guides/dns-records-guide.md`
- `context/guides/public-gateway-setup.md`
- `context/llm/homelab-netcontroller.md`
- `inventory/hosts.yml`
- `inventory/group_vars/all/dns.yml`
- `playbooks/roles/add_unbound/`
- `playbooks/roles/add_vpn_gateway/`
- `playbooks/roles/add_docker/`
- `context/homelab-ca/`

## Zone model

| Zone | Address space | Trust | Contains | Notes |
| --- | --- | --- | --- | --- |
| Internet | any | untrusted | clients, scanners, abuse | Only the public edge is reachable |
| Public edge | `gateway2` public IP | semi-trusted | Caddy, wg-easy, website/status containers | Inbound 22/tcp, 80/tcp, 443/tcp, 51820/udp only |
| VPN overlay | `10.13.0.0/24` (road warriors) | authenticated | phones, laptops | wg-easy hub |
| Site link | `10.14.0.0/24` (proposed) | trusted | `gateway2` ↔ `gw1` | Routes the home LAN into the public edge |
| Home LAN | `192.168.178.0/24` | trusted | phones, laptops, TVs, smarthome | FritzBox DHCP/DNS forwarder |
| Homelab static | `192.168.178.192/26` | trusted, service-specific | netcontrollers, dockerhost2, restic1, admin1 | Firewall allowlist from VPN |
| Guest WLAN | `192.168.179.0/24` | untrusted | guest devices | Internet + filtered DNS only, no LAN |
| IoT | currently inside home LAN | untrusted-ish | smarthome devices | Segmentation is an open decision |

## Traffic flows

| Flow | Path | TLS | DNS |
| --- | --- | --- | --- |
| Public website | Internet → `gateway2:443` → Caddy → local container or `gw1` → service | Let's Encrypt at Caddy | Public authoritative DNS |
| Public status page | Internet → `gateway2:443` → Caddy → status container or `gw1` → service | Let's Encrypt at Caddy | Public authoritative DNS |
| VPN connect | Internet → `gateway2:51820/udp` → wg-easy → `10.13.0.x` | WireGuard | n/a |
| Phone on mobile → internal service | phone → VPN → `gateway2` → `gw1` → LAN service | Homelab CA at service | Unbound, LAN IP answer |
| Phone on home WLAN → internal service | phone → FritzBox DNS → Unbound → LAN service | Homelab CA at service | Unbound, LAN IP answer |
| Home device without VPN | same as above | Homelab CA at service | Unbound, LAN IP answer |
| Public service hosted at home | Internet → Caddy → site link → `gw1` → service | Let's Encrypt at Caddy; optional homelab CA on the internal leg | Public name at Caddy |
| Admin SSH | laptop → LAN or VPN → host | SSH | Unbound |

The public edge has a **static** public IP. The home FritzBox has an
**ephemeral** public IP and there is no dedicated link between them. All VPN
tunnels are initiated from the home side (`gw1` and road-warrior clients) to the
static `gateway2` endpoint, so a changing home IP never requires a public-side
configuration change and no inbound home port forwarding is needed.

## Decisions recorded so far

| ID | Decision | Status |
| --- | --- | --- |
| D1 | Internal TLS uses the homelab CA, not a public wildcard | accepted |
| D2 | FritzBox remains DHCP; its upstream DNS points at Unbound | accepted |
| D3 | One public gateway reverse-proxies both local and VPN-reached services; service location is not part of the network design | accepted as a principle |
| D4 | `co3d.eu` authoritative DNS stays self-hosted/manual; no DNS-01 automation assumed | accepted, with an availability caveat |
| D5 | Internal access model: site-to-site gateway, per-host VPN clients, or split-horizon DNS | **proposed: site-to-site gateway**; see `access-models.md` |

## Documents

- `access-models.md` — the three ways to combine VPN routing, DNS names, and
  TLS identities; scenario comparison and recommendation.
- `design.md` — target architecture, public edge, VPN, DNS, TLS, DHCP,
  firewall, failure modes, operations, and open decisions.
- `Option-A-TODO.md` — documentation, implementation, migration, validation,
  and rollback checklist for the proposed site-to-site model.

## Next step

Resolve D5 and the open decisions in `design.md`, then turn the chosen model
into an implementation plan. No playbook changes should start before D5 is
accepted.
