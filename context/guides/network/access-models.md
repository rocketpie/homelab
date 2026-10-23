# Internal Access Models

This document answers one question:

> When a phone or laptop is on the VPN, how does it reach a home service, and
> what does the service name resolve to?

The answer bundles three things that are easy to conflate:

1. **DNS answer** — the IP address the client receives for a service name.
2. **Packet path** — which device routes that IP to the service.
3. **TLS identity** — the hostname(s) the certificate must cover.

Three models are viable. Only one should be the long-term target.

## Running example

Immich runs on `dockerhost2`:

- LAN address: `192.168.178.201`
- VPN overlay address (current per-host client): `10.13.0.11`
- Internal name today: `immich.lan` and `immich.vpn.lan`
- TLS today: homelab CA certificate on `dockerhost2`, covering both names

## Model A — site-to-site gateway

One home gateway (`gw1`) holds a WireGuard link to the public edge. The public
edge routes the entire home LAN (`192.168.178.0/24`) through `gw1`. Service
names always resolve to their LAN address.

```text
phone on mobile
  -> wg-easy (gateway2)
  -> site link
  -> gw1
  -> 192.168.178.201 (dockerhost2)
```

- DNS: `immich.lan` → `192.168.178.201` everywhere.
- TLS: certificate SAN `immich.lan` only.
- Routing: `gateway2` has `192.168.178.0/24 via gw1`; `gw1` forwards to the LAN.
- Home WLAN: same name, same address, direct path.
- Firewall: `gw1` allowlists which VPN clients may reach which LAN IPs/ports.

This is the only model where one name, one certificate SAN, and one routing
rule cover both the VPN and the home WLAN.

## Model B — per-host VPN clients (current direction)

Each service host runs its own WireGuard client to wg-easy and has its own
`10.13.0.x` address. The public edge reaches each host directly over the
overlay. Names are split: `.lan` for the LAN address, `.vpn.lan` for the
overlay address.

```text
phone on mobile
  -> wg-easy (gateway2)
  -> 10.13.0.11 (dockerhost2)
```

- DNS: `immich.lan` → `192.168.178.201`; `immich.vpn.lan` → `10.13.0.11`.
- TLS: certificate SANs must include both names.
- Routing: no LAN route on the public edge; it only knows enrolled hosts.
- Home WLAN: use `immich.lan`, direct path.
- Firewall: only enrolled hosts are reachable, but wg-easy client-to-client
  widens the reachable set.

This is the current repository direction and the smallest change from today.
Its cost is two names per service, two SANs per certificate, and per-host VPN
enrollment for every new service host.

## Model C — split-horizon DNS

Each service host still has an overlay address (as in B), but DNS publishes one
name. Unbound returns the LAN address to home clients and the overlay address
to VPN clients.

```text
phone on mobile
  -> DNS via VPN -> Unbound sees 10.13.0.x -> 10.13.0.11
  -> wg-easy -> 10.13.0.11

phone on home WLAN
  -> DNS via FritzBox -> Unbound sees 192.168.178.1 -> 192.168.178.201
  -> direct
```

- DNS: one name, two answers selected by client source.
- TLS: one SAN.
- Routing: same as B.
- Home WLAN: works while the client queries the FritzBox.
- Complexity: Unbound views, separate caches, source detection, and a new class
  of "wrong view" failures.

## Scenario comparison

| Situation | A. Site-to-site | B. Per-host | C. Split-horizon |
| --- | --- | --- | --- |
| Phone at home, VPN off | `immich.lan` → `.201`, direct | same | same |
| Phone on mobile, VPN on | `immich.lan` → `.201`, via `gw1` | must use `immich.vpn.lan` → `10.13.0.11`; `immich.lan` fails | `immich.lan` → `10.13.0.11` if the view is correct |
| Phone at home, VPN on | name works; may hairpin if the phone routes the LAN into the tunnel | `.lan` may be captured and fail at the public edge; `.vpn.lan` works but hairpins | DNS goes through the tunnel → overlay answer → hairpin |
| Home TV without VPN | works | works | works |
| Add service on existing host | 1 DNS record + 1 SAN + optional firewall rule | 2 DNS records + 2 SANs | 1 record + both views |
| Add new host | no VPN change; add firewall rule and DNS | WG client, overlay IP, peer, inventory, cert | same as B, plus views |
| Gateway or host failure | `gw1` down = all remote LAN access down | one host down = only that host | same as B |
| Compromised phone | whatever `gw1` allows; must allowlist | enrolled hosts only; client-to-client widens it | same as B |
| Debugging | route + firewall + DNS | route + peer + DNS name choice | route + peer + view selection |

## Why split-horizon is fragile in this environment

- **FritzBox forwarding collapses the source.** All home clients query the
  FritzBox, so Unbound sees `192.168.178.1` for every home query. Guest WLAN
  clients also arrive through the same forwarder. Unbound cannot distinguish a
  trusted laptop from a guest phone, so a guest client would receive LAN answers
  it cannot reach.
- **The same phone can flip views.** If the phone uses the VPN-pushed resolver,
  Unbound sees the overlay address. If it uses the FritzBox resolver, Unbound
  sees the FritzBox. The answer changes with a DNS setting the user may not
  realize is in play.
- **Full tunnel at home guarantees the wrong path.** The DNS query itself goes
  through the VPN, so Unbound returns the overlay address, and the service
  traffic follows the tunnel to the public edge and back.
- **View bugs look like timeouts.** A wrong view returns a syntactically valid
  but unreachable address. That is harder to diagnose than a missing record.

Model C buys one name and pays for it with DNS views, cache separation, and
source-dependent behavior. Model A buys the same one name with routing instead,
which is easier to observe and test.

## Why Model A fits the stated goals

- **One name per service.** `immich.lan` works on the WLAN and over the VPN.
- **Location independence.** Caddy can proxy to a container name, a LAN IP, or
  an overlay IP. The route table, not the DNS name, decides the path.
- **Home devices without VPN.** They keep using the same LAN address they use
  today.
- **One certificate SAN per service.** The homelab CA workflow gets simpler,
  not more complex.
- **No split-horizon DNS.** Unbound stays a straightforward resolver, which
  matters because the FritzBox is the forwarder.

The price is a single choke point (`gw1`) and a firewall allowlist to prevent
"routed LAN" from becoming "exposed LAN".

## Why Model B is still defensible

- **Least privilege by default.** Only hosts with a WireGuard peer are
  reachable; there is no LAN-wide route to firewall.
- **Incremental.** It is already implemented and works for the current hosts.
- **Failure isolation.** One host's tunnel does not affect another host.

It is a reasonable interim model, but it does not meet the "one simple name"
goal without split-horizon DNS, and it grows linearly with the number of
service hosts.

## Recommendation

Adopt **Model A** as the target, with these guardrails:

1. Keep the existing per-host WireGuard clients during the transition; they are
   useful for management and for validating the site link.
2. Put an explicit allowlist on `gw1`: VPN clients may reach only the service
   IPs and ports that are meant to be reachable.
3. Publish one name per service, pointing at the LAN address.
4. Reissue internal certificates with the single name; existing certificates
   with both SANs continue to work during the transition.
5. Retire `.vpn.lan` records and per-host peers once the site link is stable.

## Migration outline (no implementation yet)

1. Choose the `gw1` platform: a dedicated small VM, an existing netcontroller,
   or the FritzBox WireGuard client. A dedicated VM is the cleanest.
2. Establish the site link between `gateway2` and `gw1` on a dedicated subnet
   (proposed `10.14.0.0/24`), separate from the wg-easy road-warrior pool.
3. Add the home LAN route on `gateway2` and the VPN route on `gw1`.
4. Add a FritzBox static route for `10.13.0.0/24` via `gw1`, or SNAT on `gw1`
   if a static route is not workable. A static route preserves client identity
   and is preferred.
5. Add the `gw1` allowlist and verify from a VPN client.
6. Point service names at LAN addresses; stop publishing new `.vpn.lan` names.
7. Verify from home WLAN, mobile VPN, and the public edge before retiring the
   per-host peers.


