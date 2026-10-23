# Public Gateway Setup

This guide covers a public gateway that runs:

- `add_vpn_gateway`: wg-easy + Caddy reverse proxy
- `add_website`: a small static website in Docker
- UFW + fail2ban for host firewalling and SSH brute-force blocking
- Ubuntu unattended security updates

The playbook is [`playbooks/add-public-gateway.yml`](../../playbooks/add-public-gateway.yml).

## Scope

This playbook targets an **already-installed public host** that is reachable
over SSH. It deliberately does **not** use:

- `playbooks/add-vm.yml`
- Proxmox or the `proxmox` inventory group
- the local PXE/autoinstall seed workflow
- the homelab CA or `.lan` DNS records

TLS certificates come from Let's Encrypt through Caddy. The public DNS names
must point at the public gateway before the first run.

## Host OS Choice

Recommended: **Ubuntu 26.04 LTS** (current LTS).

| OS | Verdict | Why |
| --- | --- | --- |
| Ubuntu 26.04 LTS | **Recommended** | Current LTS. Docker CE publishes a `resolute` apt repository, and `unattended-upgrades`, UFW, fail2ban, and the existing Ansible roles all work. |
| Ubuntu 24.04 LTS | Also fine | Still supported and slightly more conservative, but there is no reason to prefer it for a new public server. |
| Debian 13 | Good second choice | Very stable and lean. The current roles assert `distribution == Ubuntu`, so they would need to be generalized before use. |
| AlmaLinux 9 | Not preferred here | RHEL-family packaging means Docker CE and update/firewall conventions differ from the rest of the repo. SELinux adds friction for bind-mounted container data. |
| Arch Linux | Not recommended | Rolling release is a poor fit for an unattended public gateway. |

Use a 64-bit x86_64 or arm64 image with at least 1 vCPU, 1 GB RAM, and
10 GB disk. The stack is small; 2 GB RAM is comfortable. The hosting provider
controls image seeding, so this playbook only configures the running guest.

## Architecture

The gateway is the public entry point and owns:

- Caddy on ports 80/443
- wg-easy on UDP 51820
- the public DNS names and Let's Encrypt certificates
- the routing table that maps hostnames to upstreams

The website is a separate Docker workload. For now it runs on the gateway box,
joins the gateway's shared Docker network, and Caddy reaches it as
`website:80`.

The inventory groups make the later split explicit:

- a host in `vpn_gateway` gets Caddy + wg-easy + firewall
- a host in `website` gets the website container
- the current box is in both groups

## DNS and Ports

Point the routed names at the public gateway. Current host vars use:

- `co3d.eu` for the website
- `vpn.co3d.eu` for wg-easy

Caddy obtains Let's Encrypt certificates over HTTP-01/TLS-ALPN, so the names
must resolve publicly before the first run.

Inbound ports on the gateway:

| Port | Protocol | Purpose |
| --- | --- | --- |
| 22 (or `add_firewall_ssh_port`) | TCP | SSH |
| 80 (or `add_vpn_gateway_caddy_http_port`) | TCP | ACME HTTP challenge and HTTP-to-HTTPS redirect for all hosts |
| 443 (or `add_vpn_gateway_caddy_https_port`) | TCP | HTTPS |
| 443 (or `add_vpn_gateway_caddy_https_port`) | UDP | HTTP/3, only when `add_vpn_gateway_caddy_http3` is true |
| 51820 (or `add_vpn_gateway_wg_easy_wg_port`) | UDP | WireGuard |

WireGuard is the one deliberate exception to "SSH and web traffic only".
The wg-easy web UI is **not** published directly; Caddy proxies it over HTTPS.

`add_firewall` is protocol-agnostic and assumes no ports: its defaults are
empty lists, so a host gets SSH only. The exposed ports are inventory policy in
[`inventory/group_vars/vpn_gateway/firewall.yml`](../../inventory/group_vars/vpn_gateway/firewall.yml),
derived from the gateway vars, so the firewall follows whatever the gateway
publishes and disabling HTTP/3 also closes UDP 443 instead of leaving a dead
port open. Host vars can override the lists for a host with different exposure.

Caddy redirects **every** plaintext HTTP request to HTTPS, including requests
for hostnames that are not in `add_vpn_gateway_routes`. Caddy's automatic
host-matched redirects run first, and a catch-all `http://` block handles the
rest with a `308` that preserves the path, query string, and request method.

## Bootstrap SSH Access

The playbook connects as `ansible_user: root` using `~/.ssh/ansible` unless the
host vars override it. If that key is not authorized on the new host yet, add it
once before the first playbook run:

```bash
ssh-copy-id -i ~/.ssh/ansible.pub root@62.83.36.224
```

Then verify the key works:

```bash
ssh -i ~/.ssh/ansible root@62.83.36.224 'id'
```

If this is the first SSH connection, accept the host key when prompted. 
After a reinstall, remove the old host key first, then add the new one:

```bash
ssh-keygen -R 62.83.36.224 # after reinstall only
ssh-keyscan -H 62.83.36.224 >> ~/.ssh/known_hosts
```

If the provider uses a different key, set `ansible_ssh_private_key_file` in
the host vars. If password authentication is enabled, the alternative is to put
`ansible_password` in the host vault and let `sshpass` handle the first run, but
installing the key is the cleaner bootstrap.

### Bootstrapping from a provider install script

If the provider can run a script on first boot after reinstalling the image,
put the key there instead of using `ssh-copy-id`. The script runs as root and
the gateway uses `ansible_user: root`, so it only needs to write
`/root/.ssh/authorized_keys`.

First, read the active environment's ansible `sshPublicKey`:
```bash
jq -r .sshPublicKey .homelab-environment.json
```
or any other public key with `ssh-keygen -lf ~/.ssh/key-file.pub`


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

Note:
- The script must run as root and SSH must accept key-based root login
  (`PermitRootLogin prohibit-password` is the Ubuntu default). If the first
  login fails, add `id > /root/bootstrap-ssh.log` to the script and read that
  file through the provider console.

## Inventory and Vault

The host is in both groups in [`inventory/hosts.yml`](../../inventory/hosts.yml):

```yaml
vpn_gateway:
  hosts:
    gateway2:
      ansible_host: 62.83.36.224
      dns_name: vpn.co3d.eu

website:
  hosts:
    gateway2:
```

Update [`inventory/host_vars/gateway2/host.yml`](../../inventory/host_vars/gateway2/host.yml)
with the gateway routes:

```yaml
add_vpn_gateway_acme_email: "lars@co3d.eu"
add_vpn_gateway_wg_easy_init_host: "vpn.co3d.eu"
add_vpn_gateway_routes:
  - hostnames:
      - "vpn.co3d.eu"
    upstream: "wg-easy:80"
  - hostnames:
      - "co3d.eu"
    upstream: "website:80"

add_website_domain: "co3d.eu"
```

Add the initial wg-easy admin password to the host `vault.yml`:

```yaml
add_vpn_gateway_wg_easy_init_password: "a-long-initial-password"
```

The password is only used on the first start when no `wg-easy.db` exists.
After setup, the playbook stops rendering the `INIT_*` variables.

If the server only accepts SSH as root, keep `ansible_user: root`. Override
`ansible_ssh_private_key_file` if the SSH key is not `~/.ssh/ansible`.

If the provider gives you a root password instead of a key, add
`ansible_password` to the host vault. The devcontainer includes `sshpass`.

## Gateway Routes and Future Splits

`add_vpn_gateway_routes` is the public routing table. A route can point at a
container name on the gateway's Docker network:

```yaml
- hostnames:
    - "co3d.eu"
  upstream: "website:80"
```

It can also point at a VPN-connected homelab address:

```yaml
- hostnames:
    - "service.vpn.co3d.eu"
  upstream: "10.13.0.20:8080"
```

The route model is ready for that later split. The remaining work at split time
is network-level: Caddy currently runs on a Docker bridge network. For it to
reach WireGuard client IPs directly, the gateway will need a deliberate
data-plane change, such as host networking or a VPN sidecar. That is
intentionally deferred until the website actually moves.

If Caddy is switched to host networking, also publish the website on
`127.0.0.1:8080` and change its route to `127.0.0.1:8080`, because Docker DNS
names such as `website:80` are not available from the host network namespace.

To move the website later:

1. Move the host from `vpn_gateway` to only `website` (or add a new host to
   `website`).
2. Set the website publish address to the VPN overlay IP and a port:

   ```yaml
   add_website_publish_bind: "10.13.0.20"
   add_website_publish_port: 8080
   ```

3. Change the gateway route upstream to `10.13.0.20:8080`.
4. Implement the gateway-to-VPN data-plane change.

The website role itself is already independent. `add_website_join_proxy_network`
defaults to `true` only for hosts that are also in `vpn_gateway`.

## Run

Open the repository dev container. The Ansible toolchain is already installed
in the image, so there is no `install.ps1` or `.venv` step:

```bash
pwsh tests/verify-devcontainer.ps1
pwsh tests/verify-public-gateway-config.ps1
pwsh run.ps1 add-public-gateway.yml
```

For the legacy WSL workflow, activate `.venv` first:

```powershell
pwsh run.ps1 add-public-gateway.yml
```

The playbook runs, in order:

1. `add_autoupdate`
2. `add_docker`
3. `add_website` when the host is in the `website` group
4. `add_firewall` when the host is in the `vpn_gateway` group
5. `add_vpn_gateway` when the host is in the `vpn_gateway` group

The projects live in:

```text
/opt/vpn-gateway/
├── Caddyfile
├── docker-compose.yml
└── wg-easy/
    └── wg-easy.db

/opt/website/
├── content/
│   └── index.html
└── docker-compose.yml
```

## Migrating wg-easy data

wg-easy v15 stores its state in a SQLite database at
`/etc/wireguard/wg-easy.db` inside the container. Because the old instance is
already on v15, copy that database instead of using the legacy `wg0.json`
import path.

On the old server, stop the container before copying so SQLite has no pending
writes:

```bash
cd /path/to/old/wg-easy
sudo docker compose stop wg-easy

# Find the host path behind the container's /etc/wireguard mount.
sudo docker inspect wg-easy --format '{{range .Mounts}}{{if eq .Destination "/etc/wireguard"}}{{.Source}}{{end}}{{end}}'
```

The mount path is often a named Docker volume. Copy `wg-easy.db` from it (for
example with `sudo docker run --rm -v <volume>:/data -v "$PWD":/backup alpine
cp /data/wg-easy.db /backup/`), then store it outside the repository:

```bash
mkdir -p ~/wg-easy-backup
cp wg-easy.db ~/wg-easy-backup/wg-easy.db
```

The playbook reads the migration source from the controller path in
`add_vpn_gateway_wg_easy_migration_source`. It never reads a database from the
repository. The `wg-easy.db*` patterns in `.gitignore` are only a safety net
against accidentally committing VPN private keys or client data.

Set the host var:

```yaml
add_vpn_gateway_wg_easy_migration_source: "{{ lookup('env', 'HOME') }}/wg-easy-backup/wg-easy.db"
```

Run the playbook. The file is seeded into
`/opt/vpn-gateway/wg-easy/wg-easy.db` before the container starts, so the
existing admin login and clients are preserved and unattended setup is
skipped.

After the migration:

1. Log in to the new wg-easy UI.
2. If the public hostname or WireGuard UDP port changed, update them in the
   wg-easy admin panel so newly generated client configs use the new server.
3. Remove the `add_vpn_gateway_wg_easy_migration_source` host var so future
   runs do not depend on the backup file.

If you only have a legacy `wg0.json` backup from v14 or older, leave the
migration variable empty, run the playbook, and use the v15 setup wizard's
restore option instead.

### Copying Directly to the New Host

You can skip the controller copy and place the database directly on the new
host. Stop the old container first, then copy the file:

```bash
# On the old host: stop the container and find the data path.
cd /path/to/old/wg-easy
sudo docker compose stop wg-easy
sudo docker inspect wg-easy --format '{{range .Mounts}}{{if eq .Destination "/etc/wireguard"}}{{.Source}}{{end}}{{end}}'
```

From a machine that can reach both hosts:

```bash
scp -3 olduser@oldhost:/path/to/wg-easy.db root@62.83.36.224:/tmp/wg-easy.db
```

On the new host:

```bash
sudo mkdir -p /opt/vpn-gateway/wg-easy
sudo install -o root -g root -m 0600 /tmp/wg-easy.db /opt/vpn-gateway/wg-easy/wg-easy.db
sudo rm -f /tmp/wg-easy.db
```

Then run the playbook with `add_vpn_gateway_wg_easy_migration_source` left
empty. The role detects the existing database and skips unattended setup.

If the new stack was already started and created an empty database, remove it
first:

```bash
sudo rm -f /opt/vpn-gateway/wg-easy/wg-easy.db \
  /opt/vpn-gateway/wg-easy/wg-easy.db-wal \
  /opt/vpn-gateway/wg-easy/wg-easy.db-shm
```

The controller-path method above is still preferred because Ansible handles
directory creation, ownership, and the first-start ordering for you.

## Website Content

By default the role creates a placeholder `index.html` and does not overwrite
it on later runs.

Two ways to deploy real content:

- Let an external site repository or CI job push a build over SSH. See
  [External publishing](#external-publishing).
- Copy files into `/opt/website/content/` on the server manually.

The role does not push content from the Ansible controller.

Caddy routes the website hostname to `website:80` through the shared
`vpn-gateway-proxy` Docker network.

### External publishing

The role creates a password-locked `website-deploy` account that has no sudo and
owns only `/opt/website/content` (`0755`, files `0644`). It also installs
`rsync` and generates an ed25519 key pair for that account:

- `/root/website-publish` - private key
- `/root/website-publish.pub` - public key
- `/root/website-publish.README.md` - operator notes for this host

The private key is what CI uses. Fetch it after a run:

```bash
ssh root@<gateway-host> 'cat /root/website-publish'
```

The publish job then runs:

```bash
rsync -az --delete --chmod=D755,F644 \
  -e 'ssh -i ~/.ssh/website-publish -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
  dist/ website-deploy@<gateway-host>:/opt/website/content/
```

Do not pass `--chown=root:root`. The publish account is not root, so it cannot
change ownership; `-a` already skips owner and group preservation for a non-root
receiver, and `--chmod` keeps the files readable by nginx. Publishing uses the
existing SSH port, so no firewall change is needed.

`add_website_publish_key_rotate` defaults to `true`, so every playbook run
replaces the key pair and revokes the previous CI key. Copy the new private key
into the CI secret after each run. To keep the current key across runs, set
`add_website_publish_key_rotate: false` in the host vars and rotate
deliberately. Set `add_website_publish_user: ""` to skip the account, keys, and
README entirely.

## Firewall and fail2ban

UFW defaults to deny incoming and allow outgoing. The role allows SSH first,
then the TCP and UDP ports from the inventory policy, and only then enables
UFW. It runs only on hosts in the `vpn_gateway` group. The role itself has no
port defaults, so an unconfigured host gets SSH only.

fail2ban uses the `ufw` ban action. The `sshd` jail uses the systemd backend and
bans for `2m` after `7` failures within `2h`. Ban times escalate on repeat
offenses through `bantime.increment` with multipliers `1 4 1800 54000`:

```bash
sudo fail2ban-client status sshd
sudo ufw status verbose
```

Docker publishes ports through its own iptables chains, which bypass UFW for
published container ports. The gateway publishes only the ports listed above;
the wg-easy UI stays on the private Compose network and the website publishes
no host port while it runs on the gateway.

If you change `add_vpn_gateway_caddy_http_port`,
`add_vpn_gateway_caddy_https_port`, `add_vpn_gateway_caddy_http3`, or
`add_vpn_gateway_wg_easy_wg_port`, the firewall rules follow automatically
because `inventory/group_vars/vpn_gateway/firewall.yml` derives them from the
gateway vars. Override the `add_firewall_allowed_*_ports` lists in host vars
only for a host whose exposure differs from the rest of the group.

If the host has no usable IPv6, set
`add_vpn_gateway_wg_easy_disable_ipv6: true`.

## Updates

Host packages use Ubuntu unattended-upgrades through `add_autoupdate`. The role
does not reboot automatically by default. Docker Engine comes from Docker's apt
repository, so it is not covered by the Ubuntu security origin; update it
manually or extend the allowed origins if you want it updated automatically.

Container images are pinned to explicit tags. The role defaults currently pin
`ghcr.io/wg-easy/wg-easy:15.4` and `caddy:2.11.7-alpine`. Update each project
separately:

```bash
cd /opt/vpn-gateway
sudo docker compose pull
sudo docker compose up -d

cd /opt/website
sudo docker compose pull
sudo docker compose up -d
```

Or set `add_vpn_gateway_pull_images: true` and/or
`add_website_pull_images: true` for one playbook run. Keep the wg-easy major
version pinned (`15.x`) to avoid a breaking upgrade.

## Validation

```bash
sudo docker compose -f /opt/vpn-gateway/docker-compose.yml ps
sudo docker compose -f /opt/website/docker-compose.yml ps
sudo docker compose -f /opt/vpn-gateway/docker-compose.yml logs --tail=100 caddy
sudo docker compose -f /opt/vpn-gateway/docker-compose.yml logs --tail=100 wg-easy
curl -I https://co3d.eu
curl -I https://vpn.co3d.eu
```

Caddy retries certificate issuance automatically if DNS is not ready on the
first run.

## Troubleshooting

Check the moving parts in order:

```bash
sudo ufw status verbose
sudo fail2ban-client status sshd
sudo docker compose -f /opt/website/docker-compose.yml ps
sudo docker compose -f /opt/vpn-gateway/docker-compose.yml ps
sudo docker compose -f /opt/vpn-gateway/docker-compose.yml logs --tail=100 caddy
sudo docker compose -f /opt/vpn-gateway/docker-compose.yml logs --tail=100 wg-easy
sudo docker compose -f /opt/website/docker-compose.yml logs --tail=100 website
```

- **Caddy certificate errors**: confirm every routed DNS name resolves to the
  server and that inbound TCP 80/443 are open. Caddy retries automatically.
- **wg-easy shows the setup wizard**: `/opt/vpn-gateway/wg-easy/wg-easy.db` was
  not present on first start. Complete the wizard, or restore the database as
  described above.
- **wg-easy UI returns 502**: check `wg-easy` container logs and confirm the
  container is on the `vpn-gateway-proxy` network.
- **Website returns 502**: check that the `website` container is running and
  attached to `vpn-gateway-proxy`, or that the route upstream points at the
  correct split-host address.
- **fail2ban sees nothing**: confirm the jail is active and that SSH events
  appear in the journal:

  ```bash
  sudo fail2ban-client -d | grep -i sshd
  sudo journalctl -u ssh.service --since "10 minutes ago"
  ```

- **Locked out after enabling UFW**: the role allows SSH before enabling UFW,
  but a custom SSH port must match `add_firewall_ssh_port`.
