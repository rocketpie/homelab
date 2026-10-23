# Option A TODO

Status: **draft, not started**. This is the working checklist for the proposed
site-to-site access model (Option A) in `access-models.md`. It covers
documentation, implementation, migration, validation, and rollback.

Do not start implementation until the access model and the open decisions are
accepted.

## Decision summary

Option A means:

- one home gateway (`gw1`) routes the home LAN into the VPN,
- service names resolve to LAN addresses everywhere,
- one certificate SAN per service,
- the public edge has a routed leg into the private network,
- the home WLAN uses the same names without the VPN.

## Documentation TODO

### Drawbacks and limitations of Option A

- [ ] Document that `gw1` is a single choke point. If it is down, remote access
      to the LAN is down, even though the home WLAN still works.
- [ ] Document the "VPN off at home" recommendation and why it costs nothing:
      the FritzBox still forwards to Unbound, so ad blocking and internal names
      keep working.
- [ ] Document the client-dependent hairpin behavior when the VPN stays on at
      home, including the client-behavior table in `design.md`.
- [ ] Document that a split-tunnel profile excluding `192.168.178.0/24` avoids
      the hairpin but breaks LAN access while away from home. It is not a free
      fix.
- [ ] Document that routing the LAN into the VPN is not the same as exposing it:
      `gw1` must keep an allowlist, and every new service needs a firewall rule.
- [ ] Document the added latency and public-gateway load when a home client
      hairpins through `gateway2`.
- [ ] Document that public services hosted at home depend on the home internet
      connection, even when `gateway2` is healthy.
- [ ] Document the homelab CA limitation: browsers can trust a user-installed
      CA, but some native Android apps may not. Include the browser/PWA fallback
      and the option to revisit a public wildcard later.
- [ ] Document the FritzBox limitations: no custom DHCP search domain, possible
      DNS caching, unclear failover behavior, and no per-client DNS policy.
- [ ] Document that DoH/Private DNS can bypass Unbound filtering regardless of
      the VPN design.
- [ ] Document that guest WLAN clients may receive LAN answers but cannot reach
      them; this is expected, not a bug.
- [ ] Document that IoT devices remain on the trusted LAN until a segmentation
      decision is made.
- [ ] Document that `.lan` is not formally reserved. Note the `.internal` and
      `home.arpa` alternatives and the migration cost.
- [ ] Document that IPv6 is not fully designed. State whether the tunnel is
      IPv6-disabled or dual-stack, and why.
- [ ] Document that `gateway2` and `gw1` have no high-availability story. State
      the accepted outage behavior.
- [ ] Document that the public authoritative DNS must not live only at home.
- [ ] Document the certificate rotation impact: server certificates can rotate
      quietly, but a CA rotation requires re-trusting every device.
- [ ] Document the backup requirements: CA key, wg-easy database, Unbound
      inventory, FritzBox configuration.
- [ ] Add a "what Option A does not solve" section to `design.md`.

### Operational documentation

- [ ] Add a runbook for adding a service: name, DNS, certificate SAN, HAProxy
      binding, `gw1` allowlist, public route, monitoring.
- [ ] Add a runbook for adding a host: VM, static address, inventory, DNS alias,
      certificate, firewall rule. Make clear that no new VPN peer is needed.
- [ ] Add a troubleshooting section for:
  - DNS loop after pointing the FritzBox at Unbound,
  - hairpin when the VPN stays on at home,
  - a name that resolves but does not connect,
  - a public route that cannot reach a home service,
  - a certificate name mismatch,
  - a VPN client that cannot resolve internal names.
- [ ] Add a network diagram that shows the site link, the wg-easy pool, the LAN,
      the guest WLAN, and the public edge.
- [ ] Keep the four primary use-case paths in `design.md` current when routing,
      DNS, or TLS changes.
- [ ] Cross-link the network docs from `context/guides/homelab-network-map.md`,
      `context/guides/dns-records-guide.md`, and `context/guides/public-gateway-setup.md`.
- [ ] Record the accepted Option A decision in `README.md` and
      `access-models.md` once approved.
- [ ] Keep `README.md`, `design.md`, and this TODO consistent when decisions
      change.

## Important notes and risks

### DNS loop risk

- The FritzBox will forward to Unbound.
- Unbound currently forwards the global `.` zone to `9.9.9.9` **and**
  `192.168.178.1`.
- Once the FritzBox points at Unbound, that second forwarder creates a loop:
  `FritzBox -> Unbound -> FritzBox -> Unbound`.
- Remove `192.168.178.1` from the global `.` forwarders before enabling the
  FritzBox upstream change.
- Keep the `fritz.box` forward zone pointing at `192.168.178.1`; that zone is
  authoritative on the router.
- Validate with `dig @192.168.178.1 example.com` and
  `dig @192.168.178.193 example.com`.

### Unbound is currently open

- `playbooks/roles/add_unbound/templates/homelab-server.conf.j2` currently
  allows `0.0.0.0/0` and `::0/0`.
- Restrict access to loopback, the home LAN, guest WLAN if desired, the
  road-warrior pool, and the site-link subnet.
- Deny everything else.
- Never forward port 53 from the internet. Add Unbound rate limiting.
- Verify listeners and ACLs on both resolvers.

### Caddy also needs VPN access

- Caddy currently runs on a Docker bridge network.
- wg-easy creates its WireGuard interface inside its own container, so the
  `gateway2` host has no route to `10.13.0.0/24` or `192.168.178.0/24`.
- Caddy therefore cannot reach VPN peers or LAN services today.
- Choose and document the data plane before adding a public route to a
  home-hosted service:
  - host-level site link plus Caddy on host networking (preferred),
  - host-level site link plus bridge NAT,
  - a WireGuard sidecar for Caddy,
  - wg-easy with host networking and a verified site peer.
- Test both directions: Caddy to service, and service back to Caddy.

### Site link, dynamic home IP, and wg-easy

- The datacenter `gateway2` has a static public IP; the home FritzBox has an
  ephemeral public IP that may change daily.
- There is no dedicated connection between them. Every tunnel runs over the
  public internet through the FritzBox's WAN interface.
- `gw1` must be the **tunnel initiator**; `gateway2` is the stable rendezvous.
  This keeps a changing home IP from requiring any public-side configuration.
- No inbound port forwarding at home is needed. Outbound UDP from `gw1` is
  sufficient, which also covers CGNAT and DS-Lite.
- Configure a persistent keepalive on `gw1` so the NAT mapping stays open and a
  dead path is detected quickly.
- Verify recovery after a home IP change or a FritzBox reconnect.
- Verify whether wg-easy supports a site peer with custom server-side
  `AllowedIPs` covering `192.168.178.0/24`.
- If it does not, use a separate host-level WireGuard interface for the site
  link instead of forcing it into wg-easy.
- Keep the site-link subnet separate from the road-warrior pool. Proposed:
  `10.14.0.0/24`.
- Confirm MTU. WireGuard overhead plus a second tunnel can cause large-packet
  stalls if the MTU is left at 1500 everywhere.

### Return path

- Add a FritzBox static route for `10.13.0.0/24` via `gw1` so LAN hosts can reply
  to VPN clients.
- If the FritzBox cannot do that, SNAT on `gw1` is the fallback. It preserves
  connectivity but hides client identity.
- Verify with a packet capture or connection tracking, not only with `ping`.

### Firewall and Docker

- Docker-published ports bypass UFW. Audit Compose files whenever a port is
  added.
- `gw1` is the enforcement point for VPN-to-LAN traffic.
- Default-deny on `gw1`, then allow explicit service IPs and ports.
- Do not expose the whole homelab static block just because it is routed.

### TLS names

- Under Option A, each service should have one name and one SAN.
- Reissue certificates after the DNS change; do not keep both `.lan` and
  `.vpn.lan` SANs forever.
- Verify the certificate chain from a client that trusts only the homelab CA.
- Test native mobile apps, not only browsers.

### Public DNS

- Confirm where the authoritative zone for `co3d.eu` actually lives.
- If it lives only at home, move it to `gateway2` or a reliable provider before
  relying on public services.
- Public names must point at `gateway2` before Caddy can issue certificates.

## Implementation TODO

### Phase 0 — decisions

- [ ] Accept or reject Option A (O1).
- [ ] Choose the `gw1` platform (O2).
- [ ] Choose the public-edge data plane (O3).
- [ ] Confirm where authoritative DNS for `co3d.eu` lives (O4).
- [ ] Decide whether `.lan` stays or migrates (O5).
- [ ] Decide the IPv6 position (O10).
- [ ] Record all decisions in `README.md` and `design.md`.

### Phase 1 — DNS hardening

- [ ] Remove `192.168.178.1` from Unbound's global `.` forwarders.
- [ ] Keep the `fritz.box` forward zone.
- [ ] Restrict Unbound `access-control` to the expected subnets.
- [ ] Add the site-link subnet to the Unbound ACL.
- [ ] Add Unbound rate limiting.
- [ ] Confirm no inbound port 53 forwarding exists.
- [ ] Enable or verify DNSSEC validation.
- [ ] Point the FritzBox upstream DNS at `netcontroller1` and
      `netcontroller2`.
- [ ] Verify internal names through the FritzBox, not only directly.
- [ ] Verify blocklist behavior.
- [ ] Add a DNS canary check to monitoring.
- [ ] Document the final forwarder and ACL configuration.

### Phase 2 — internal TLS

- [ ] Inventory every internal name and its certificate.
- [ ] Decide the final SAN list per host.
- [ ] Reissue certificates with the Option A names.
- [ ] Deploy the new PEM bundles.
- [ ] Install the homelab CA on all client devices.
- [ ] Test browser and native-app access.
- [ ] Add certificate expiry monitoring.
- [ ] Document the rotation procedure.
- [ ] Back up the CA key and certificate offline.

### Phase 3 — site gateway

- [ ] Create the `gw1` VM with a static LAN address outside the DHCP range.
- [ ] Add `gw1` to inventory and host vars.
- [ ] Enable IP forwarding on `gw1`.
- [ ] Establish the site-link WireGuard interface on `gw1` as the initiator.
- [ ] Establish the matching interface on `gateway2` as the stable endpoint.
- [ ] Configure a persistent keepalive on `gw1`.
- [ ] Set `AllowedIPs` deliberately on both sides.
- [ ] Confirm no inbound port forwarding is required at home.
- [ ] Add `192.168.178.0/24` via the site link on `gateway2`.
- [ ] Add `10.13.0.0/24` via `gateway2` on `gw1`.
- [ ] Add the FritzBox static route for `10.13.0.0/24` via `gw1`, or configure
      SNAT.
- [ ] Add the `gw1` allowlist firewall rules.
- [ ] Verify routing from a VPN client to a LAN service.
- [ ] Verify routing from a LAN host back to the VPN client.

### Phase 4 — public-edge data plane

- [ ] Implement the chosen Caddy data plane.
- [ ] Verify Caddy can reach a LAN service by LAN address.
- [ ] Verify the service can return traffic to Caddy.
- [ ] Confirm UFW and Docker port exposure are still correct.
- [ ] Add a public route to one low-risk home-hosted service as a test.
- [ ] Document the data-plane choice and its limitations.

### Phase 5 — public services

- [ ] Decide the status page content and whether it is authenticated.
- [ ] Add the status page route if wanted.
- [ ] Ensure public pages do not leak internal hostnames or IPs.
- [ ] Review the wg-easy UI exposure. Keep it public only with strong auth.
- [ ] Add rate limiting or CrowdSec if the public surface warrants it.
- [ ] Verify public certificates and renewals.

### Phase 6 — operations

- [ ] Add `gw1` and `gateway2` to monitoring.
- [ ] Monitor VPN handshakes and peer count.
- [ ] Monitor certificate expiry.
- [ ] Monitor public endpoints.
- [ ] Back up the wg-easy database.
- [ ] Back up the Unbound inventory and generated configuration.
- [ ] Export the FritzBox configuration.
- [ ] Document the recovery order: DNS, VPN, gateway, public edge.

## Migration TODO

- [ ] Keep the existing per-host WireGuard clients during the transition.
- [ ] Add the site link alongside the existing per-host peers.
- [ ] Validate the site link before changing any DNS record.
- [ ] Move one low-risk service first, for example `immich.lan`.
- [ ] Change DNS records to LAN addresses one service at a time.
- [ ] Keep `.vpn.lan` records until no client or bookmark depends on them.
- [ ] Update the Docker reverse proxy bindings to the final names.
- [ ] Reissue certificates without the `.vpn.lan` SANs.
- [ ] Verify from home WLAN, mobile VPN, and the public edge after each move.
- [ ] Remove per-host WireGuard peers only after the site link has been stable
      for a defined observation period.
- [ ] Remove `add_vpn_client_overlay_ipv4` from host vars only after no
      `.vpn.lan` record or DNS assertion depends on it.
- [ ] Remove obsolete `.vpn.lan` records from
      `inventory/group_vars/all/dns.yml` and host vars.
- [ ] Update `context/guides/dns-records-guide.md` to describe Option A as the
      primary model.
- [ ] Update any verification scripts that still expect `.vpn.lan` names.

## Validation TODO

- [ ] `dig @192.168.178.1 immich.lan` returns the LAN address.
- [ ] `dig @192.168.178.193 immich.lan` returns the LAN address.
- [ ] A VPN client resolves the same name to the same address.
- [ ] `curl -I https://immich.lan` works from the home WLAN.
- [ ] `curl -I https://immich.lan` works from a VPN client.
- [ ] The certificate SANs match the names in use.
- [ ] `unbound-checkconf` passes on both resolvers.
- [ ] Unbound listens only where intended.
- [ ] `wg show` shows the site link and the expected handshakes.
- [ ] The site link reconnects after a FritzBox reconnect or a home IP change
      without any change on `gateway2`.
- [ ] No inbound port forwarding exists on the home router for the site link.
- [ ] `ip route` on `gateway2` shows the LAN route via `gw1`.
- [ ] `ip route` on `gw1` shows the VPN route via the site link.
- [ ] A LAN host can reply to a VPN client.
- [ ] A guest WLAN client cannot reach a LAN service.
- [ ] A known blocked domain returns a blocked answer through the FritzBox.
- [ ] A public home-hosted service is reachable through Caddy.
- [ ] Caddy rewrites Host/SNI to the internal name and trusts the homelab CA.
- [ ] A public service survives a `gw1` outage only if it is hosted on
      `gateway2`; confirm the expected behavior.
- [ ] SSH to `vpn.co3d.eu:22` works from home with the VPN off, using key-only
      authentication.
- [ ] Native mobile apps work with the homelab CA, or the limitation is
      documented.

## Rollback TODO

- [ ] Keep the previous DNS records and certificate SANs ready.
- [ ] Keep the per-host WireGuard peers configured until the site link is
      proven.
- [ ] Keep the old Caddy upstream routes documented.
- [ ] Define the rollback trigger: DNS failure, routing failure, or a service
      unreachable from two of the three vantage points.
- [ ] Roll back DNS first, then the Caddy route, then the site link.
- [ ] Re-enable the per-host peer path if the site link is the failing part.
- [ ] Document the rollback steps next to the implementation runbook.

## Open decisions

| ID | Question | Recommendation |
| --- | --- | --- |
| O1 | Accept Option A? | yes, with a firewall allowlist |
| O2 | Where does `gw1` run? | dedicated small VM |
| O3 | Caddy data plane? | host-level site link plus Caddy on host networking |
| O4 | Where is authoritative DNS for `co3d.eu`? | `gateway2` or a reliable provider, not home-only |
| O5 | Keep `.lan` or migrate? | keep `.lan` for now |
| O6 | Per-host HAProxy or central proxy? | keep per-host HAProxy |
| O7 | wg-easy UI exposure? | VPN-only or SSO |
| O8 | Status page content and auth? | aggregate state only |
| O9 | Segment IoT? | yes, if the hardware allows |
| O10 | IPv6? | disable in the tunnel until there is a full plan |
| O11 | When does Kea replace FritzBox DHCP? | after the site link and naming are stable |
| O12 | Need split-tunnel or DNS-only mobile profiles? | start with full tunnel |

## Definition of done

- [ ] One internal name works from the home WLAN and the VPN.
- [ ] The name resolves to the same LAN address from both paths.
- [ ] TLS is trusted from a phone and a laptop.
- [ ] The VPN can reach only allowlisted services.
- [ ] The public edge can reach a home-hosted service without exposing the LAN.
- [ ] DNS filtering works through the FritzBox and over the VPN.
- [ ] The DNS loop cannot occur.
- [ ] Unbound is not an open resolver.
- [ ] The home WLAN works with the VPN off.
- [ ] The drawbacks and limitations are documented.
- [ ] Rollback is documented and tested.
