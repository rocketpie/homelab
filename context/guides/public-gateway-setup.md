# Public Gateway Setup

This guide covers the public gateway playbook
[`playbooks/add-public-gateway.yml`](../../playbooks/add-public-gateway.yml).

The playbook configures an already provisioned cloud VM that is reachable over
SSH. It deliberately does **not** use:

- `playbooks/add-vm.yml`
- Proxmox or the `proxmox` inventory group
- the local PXE/autoinstall seed workflow
- the homelab CA or `.lan` DNS records

## Roles

| Role | Responsibility |
| --- | --- |
| `add_autoupdate` | Ubuntu unattended security updates |
| `add_docker` | Docker Engine and the Compose plugin |
| `add_firewall` | UFW and fail2ban |
| `add_caddy` | Caddy on 80/443, generated `Caddyfile` |
| `add_website` | public workload containers and the CI publish pipeline |
| `add_vpn_gateway` | wg-easy only |

A host may run Caddy, public workloads, and wg-easy together. Nothing in the
roles assumes the `vpn_gateway` and `website` groups are disjoint.

## Architecture

```text
gateway (groups: vpn_gateway, website)
  /opt/caddy/
    docker-compose.yml          
    Caddyfile                   generated from add_caddy_routes
  /opt/vpn-gateway/             wg-easy only
  /opt/public/                  root-owned
    docker-compose.yml          selected services, image refs only
    <workload>/
      <workload>.tar.zst        uploaded by CI
      <workload>.tar.zst.sha256   
    triggers/                   ephemeral process triggers
      <workload>.restart
  /usr/local/sbin/public-deploy
  /etc/cron.d/public-deploy
```

all containers (vpn-gateway, workloads) join the external `vpn-gateway-proxy` Docker network. Caddy reaches workloads by compose service name (`website:80`, `lobby:8080`).

Firewall exposure is intentionally host-local. Each gateway's `host.yml` lists
`add_firewall_allowed_tcp_ports`, `add_firewall_allowed_udp_ports`, and, for VPN hosts, `add_firewall_wireguard_ports`.

## DNS and Ports

Caddy obtains Let's Encrypt certificates over HTTP-01/TLS-ALPN, so every routed
name must resolve to the host before public TLS can succeed. For an internal or
pre-DNS test, set `add_caddy_use_internal_tls: true` temporarily, then set it
back to `false` and rerun.

Inbound ports on a public host:

| Port | Protocol | Purpose |
| --- | --- | --- |
| 22 (or `add_firewall_ssh_port`) | TCP | SSH |
| 80 (or `add_caddy_http_port`) | TCP | ACME HTTP challenge and HTTP-to-HTTPS redirect |
| 443 (or `add_caddy_https_port`) | TCP | HTTPS |
| 443 (or `add_caddy_https_port`) | UDP | HTTP/3, only when `add_caddy_http3` is true |
| 51820 (or `add_vpn_gateway_wg_easy_wg_port`) | UDP | WireGuard, VPN hosts only |

`add_firewall` has empty defaults, so an unconfigured host gets SSH only.
Exposure is host policy in each gateway's `host.yml`:

```yaml
# gateway1
add_firewall_allowed_tcp_ports:
  - 80
  - 443
add_firewall_allowed_udp_ports:
  - 443
```

```yaml
# gateway2 also allows WireGuard
add_firewall_allowed_tcp_ports:
  - 80
  - 443
add_firewall_allowed_udp_ports:
  - 443
add_firewall_wireguard_ports:
  - 51820
```

Keep these lists in sync with `add_caddy_http_port`,
`add_caddy_https_port`, `add_caddy_http3`, and
`add_vpn_gateway_wg_easy_wg_port` when those values change.

Caddy redirects every plaintext HTTP request to HTTPS, including unknown
hostnames. The automatic host-matched redirects run first; a catch-all
`http://` block handles the rest with a `308`.

Docker publishes container ports through its own iptables chains, which bypass
UFW for published ports. Public workloads publish no host ports. Only Caddy and wg-easy publish ports, and Caddy proxies the wg-easy UI over HTTPS.

## Bootstrap SSH Access (TODO: not specific to gateway, move out of here)

The playbook connects as `ansible_user: root` using the active environment's SSH identity.

If the environment key is not authorized on the new host, add it once from the
container host:

```bash
ssh-copy-id -i ~/.homelab/environments/<name>/ssh/ansible.pub root@<IP>
```

Then verify the agent identity works from inside the dev container:

```bash
ssh root@<IP> 'id'
```

After a reinstall, remove the old host key first:

```bash
ssh-keygen -R <IP>
ssh-keyscan -H <IP> >> ~/.ssh/known_hosts
```

If the provider can run a first-boot script, write the environment's Ansible
public key to `/root/.ssh/authorized_keys` instead. The playbook uses
`ansible_user: root`, so no additional user is needed:

```sh
#!/bin/sh
set -eu

KEY='ssh-ed25519 AAAA... ansible'

install -d -m 0700 -o root -g root /root/.ssh
touch /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys
grep -qxF "$KEY" /root/.ssh/authorized_keys || printf '%s\n' "$KEY" >> /root/.ssh/authorized_keys
```

## Inventory and Host Vars

Each public host needs Caddy routes and, when it runs workloads, a service
selection. A host in `website` gets `add_website`; a host in `vpn_gateway`
gets `add_vpn_gateway`.

## Public workloads

eg. `inventory/host_vars/gatewayX/host.yml`:

```yaml
---
ansible_user: root
add_firewall_ssh_port: 22

add_caddy_acme_email: "lars@co3d.eu"
add_caddy_routes:
  - hostnames:
      - "lobby.co3d.eu"
    upstream: "lobby:8080"
  - hostnames:
      - "co3d.eu"
    upstream: "website:80"

add_website_services:
  - website
  - lobby

# To preserve the CI publish key across playbook runs while testing:
add_website_publish_key_rotate: false
```

### Adding a service definition

For a third service, say status, you would:

- Add `status` to add_website_supported_services.
- Add an explicit block to playbooks/roles/add_website/templates/docker-compose.yml.j2:
```yaml
    {% if 'status' in add_website_services %}
      status:
        image: "{{ add_website_image_prefix }}/status:latest"
        pull_policy: never
        restart: unless-stopped
        expose:
          - "8080"
        labels:
          com.co3d.service: public
        networks:
          - proxy
    {% endif %}
```
- Add the Caddy route and select it in host vars:
```yaml
    add_caddy_routes:
      - hostnames:
          - "status.co3d.eu"
        upstream: "status:8080"

    add_website_services:
      - status
```

No deploy-script or cron changes are needed.


### VPN

`inventory/host_vars/gatewayX/host.yml`:

```yaml
---
ansible_user: root
add_firewall_ssh_port: 22

add_caddy_acme_email: "lars@co3d.eu"
add_caddy_routes:
  - hostnames:
      - "vpn.co3d.eu"
    upstream: "wg-easy:80"

add_vpn_gateway_wg_easy_init_host: "vpn.co3d.eu"
```

EITHER migrate an existing wg-easy.db OR add the initial wg-easy admin password to the host `vault.yml`:

```yaml
add_vpn_gateway_wg_easy_init_password: "a-long-initial-password"
```

The password is only used on the first start when no `wg-easy.db` exists.
After setup, the playbook stops rendering the `INIT_*` variables.

### Rules

- Routing stays in `add_caddy_routes`.
- Service selection stays in `add_website_services`.
- For every service in `add_website_services`, a route upstream must start with `<service>:`.
- Caddy restarts when the rendered `Caddyfile` changes.

## Publishing Workloads

Workload CI must build an image and upload a compressed `docker save` archive.
See [`website-publishing.md`](website-publishing.md) for details. 
The same contract ships on each host as `/root/website-publish.README.md`.

## Run

Activate an environment on the container host:

```powershell
# on the container host
pwsh Set-Environment.ps1 -Environment <name>
```

Inside the dev container:

```bash
pwsh tests/verify-devcontainer.ps1
pwsh tests/verify-public-gateway-config.ps1
pwsh tests/verify-public-deploy-script.ps1
pwsh run.ps1 add-public-gateway.yml -Limit gateway1
```

Omit `-Limit` to run every public host.

## Validation

```bash
sudo docker compose -f /opt/caddy/docker-compose.yml ps
sudo docker compose -f /opt/public/docker-compose.yml ps
sudo docker compose -f /opt/caddy/docker-compose.yml logs --tail=100 caddy

curl -I https://lobby.co3d.eu/healthz
curl -I https://co3d.eu
curl -I https://vpn.co3d.eu

sudo ufw status verbose
sudo fail2ban-client status sshd
```

Before DNS or public TLS is ready, use the internal CA and resolve locally:

```bash
curl -k --resolve lobby.co3d.eu:443:127.0.0.1 https://lobby.co3d.eu/healthz -I
```

A 502 is expected when Caddy is up but the workload has not been published yet.
The point of this check is the TLS handshake.

## Testing Before DNS Cutover

Set the temporary host var:

```yaml
add_caddy_use_internal_tls: true
```

Rerun the playbook, verify the handshake with `curl -k`, then set it back to
`false` and rerun once DNS points at the host.

## Migrating wg-easy Data

If the new stack already created an empty database, remove it first:

```bash
sudo rm -f /opt/vpn-gateway/wg-easy/wg-easy.db \
  /opt/vpn-gateway/wg-easy/wg-easy.db-wal \
  /opt/vpn-gateway/wg-easy/wg-easy.db-shm
```

wg-easy v15 stores its state in a SQLite database at `/etc/wireguard/wg-easy.db` inside the container. 
Stop the old container before copying so SQLite has no pending writes:

```bash
cd /path/to/old/wg-easy
sudo docker compose stop wg-easy

# Find the host path behind the container's /etc/wireguard mount.
sudo docker inspect wg-easy --format '{{range .Mounts}}{{if eq .Destination "/etc/wireguard"}}{{.Source}}{{end}}{{end}}'
```

Copy `wg-easy.db` from the host path or named volume,
eg. `sudo docker run --rm -v <volume>:/data -v "$PWD":/backup alpine cp /data/wg-easy.db /backup/`
then set:

```yaml
add_vpn_gateway_wg_easy_migration_source: "{{ lookup('env', 'HOME') }}/wg-easy-backup/wg-easy.db"
```

Run the playbook.
The file is seeded into `/opt/vpn-gateway/wg-easy/wg-easy.db` before the  container starts, 
so the existing admin login and clients are preserved and unattended setup is skipped.

After the migration:

1. Log in to the new wg-easy UI.
2. If the public hostname or WireGuard UDP port changed, update them in the
   wg-easy admin panel so newly generated client configs use the new server.
3. Remove the `add_vpn_gateway_wg_easy_migration_source` host var so future
   runs do not depend on the backup file.



## Updates

Host packages use Ubuntu unattended-upgrades through `add_autoupdate`. 
Docker Engine comes from Docker's apt repository and is not covered by the Ubuntu security origin; 
Update it manually or extend the allowed origins.

Caddy and wg-easy images are pinned:

```bash
cd /opt/caddy && sudo docker compose pull && sudo docker compose up -d
cd /opt/vpn-gateway && sudo docker compose pull && sudo docker compose up -d
```

Keep the wg-easy major version pinned (`15.x`) to avoid a breaking upgrade.
Public workload images are not pulled from a registry; update them by
publishing a new archive.

## Troubleshooting

Check the moving parts in order:

```bash
sudo ufw status verbose
sudo fail2ban-client status sshd
sudo docker compose -f /opt/caddy/docker-compose.yml ps
sudo docker compose -f /opt/public/docker-compose.yml ps
sudo docker compose -f /opt/vpn-gateway/docker-compose.yml ps

sudo docker compose -f /opt/caddy/docker-compose.yml logs --tail=100 caddy
sudo tail -100 /var/log/public-deploy.log
sudo ls -la /opt/public /opt/public/triggers
```

| Symptom | Check |
| --- | --- |
| Caddy certificate errors | every routed name resolves here, inbound TCP 80/443 open, Caddy retries |
| Caddy cannot bind 80/443 | a legacy Caddy still runs; stop it first |
| Workload returns 502 | image published, container on `vpn-gateway-proxy`, route upstream correct |
| Workload restarting with `exec ... operation not permitted` | image uses `setcap`/file capabilities; rebuild container without them |
| Publish did nothing | marker name matches the compose service, cron enabled, `public-deploy.log` |
| Publish rejected | image tag and labels follow the contract |
| wg-easy shows the setup wizard | `/opt/vpn-gateway/wg-easy/wg-easy.db` was absent on first start |
| wg-easy UI returns 502 | wg-easy container logs and proxy network attachment |
| fail2ban sees nothing | `sudo fail2ban-client -d \| grep -i sshd` and `journalctl -u ssh.service` |

A lockout after enabling UFW usually means `add_firewall_ssh_port` does not
match the real SSH port. The role allows SSH before enabling UFW, but only for
the configured port.
