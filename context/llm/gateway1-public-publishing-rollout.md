# Gateway1 public publishing rollout

Date: 2026-10-31
Host: `gateway1` (`37.120.190.139`, Ubuntu 26.04.1 LTS)
Playbook: `playbooks/add-public-gateway.yml -Limit gateway1`

## Result

The first run started from a clean host (no Docker, UFW inactive) and installed:

- Docker Engine and Compose plugin
- UFW allowing 22/tcp, 80/tcp, 443/tcp, 443/udp
- fail2ban with the `sshd` jail active
- Caddy in `/opt/caddy` with a generated `Caddyfile`
- `add_website` with the `website` and `lobby` services in `/opt/public`
- `website-deploy` publish account, key pair, and cron-driven deploy script

`add_vpn_gateway` and the WireGuard firewall port are skipped because
`gateway1` is not in `vpn_gateway`.

A follow-up run added the `website` service and the `co3d.eu` route. Gateway2
was removed from the `website` group and its `co3d.eu` route was removed so
route hostnames stay unique.

## Validation

- `docker compose -f /opt/caddy/docker-compose.yml ps` shows `caddy` up with
  80/tcp, 443/tcp, and 443/udp published.
- Let's Encrypt issued a certificate for `lobby.co3d.eu`:
  subject `CN = lobby.co3d.eu`, issuer `Let's Encrypt`, valid to 2027-01-29.
- `curl -I https://lobby.co3d.eu/` returns `502` with `server: Caddy`; the TLS
  handshake succeeds and the lobby workload has not been published yet.
- `curl -I https://co3d.eu/` still reaches the legacy site on gateway2 because
  DNS points at `62.83.36.224`.
- The gateway1 Caddyfile now has both `lobby.co3d.eu` and `co3d.eu`. Caddy's
  ACME attempt for `co3d.eu` fails until DNS moves to gateway1.
- `id website-deploy` shows only its own group; it is not in `docker`.
- `/opt/public` is root-owned; `/opt/public/website`,
  `/opt/public/lobby`, and `/opt/public/triggers` are owned by
  `website-deploy`.
- `/root/website-publish` is `0600`; the generated publish README is
  `/root/website-publish.README.md`.
- `add_website_publish_key_rotate: false` preserves the CI key. Fingerprint
  before and after the follow-up run:
  `SHA256:hQVkjPQ6n1jZ0aiB15Dc4WJ4CKJYAJ+GVpW7pZUtt54`.
- `bash -n /usr/local/sbin/public-deploy` passes.
- `/var/log/public-deploy.log` is empty; no marker has been published.

## Fix found during rollout

`add_caddy` initially rendered the `Caddyfile` without notifying the restart
handler. The file changed, but the running container kept the old config. The
role now notifies `Restart Caddy` when the template changes. The current
container was restarted manually to load the `co3d.eu` route.

## Next steps

1. Point `co3d.eu` DNS at gateway1. Caddy retries ACME automatically; restart
   the caddy container if it does not.
2. Publish `homelab/website:latest` and `homelab/lobby:latest` from CI using
   `context/guides/public-workload-publishing.md`.
3. Confirm `/var/log/public-deploy.log` logs `loading`, `restarting`, and
   `deploy complete`, then remove the expected 502s.
4. Migrate `gateway2` later: stop the legacy Caddy in `/opt/vpn-gateway` before
   running the playbook there, then remove the legacy `/opt/website` project.
