# Website Publishing Refactor

Status: implemented
Scope: split Caddy out of the VPN role, move publishing to CI-built image
tarballs, unify website and lobby, and move public workloads to the web host.

## Motivation

`gateway1` is in the `website` group but not in `vpn_gateway`, so today it gets
`add_website` and `add_lobby` but no Caddy, and both roles fail validation:
`add_website_join_proxy_network` is false on that host and no
`add_website_publish_port` is set. The web host cannot deploy as it stands,
regardless of where Caddy runs.

The split between `gateway1` and `gateway2` is temporary. The refactor must keep
working when one host runs Caddy, the workloads, and wg-easy together, which is
why nothing may assume the groups are disjoint.

## Decisions

- The compose file is the data model. No per-site schema in host vars.
- **CI builds every image.** The host never builds. Publishing uploads a
  compressed image archive plus a marker; the host loads it and recreates the
  container.
- Each service is referenced as `image: homelab/<service>:latest` with
  `pull_policy: never`. There is no registry.
- The marker filename is the compose service name:
  `/opt/public/triggers/<service>.restart`.
- The host validates image labels and refuses anything that does not carry the
  publishing contract labels.
- The host owns disk cleanup: after a successful restart it prunes every unused
  image carrying the public label, then removes the uploaded archive.
- Caddy gets a generated `Caddyfile` from a host-var route list. No
  `caddy-docker-proxy`.
- Caddy, the workloads, and the VPN gateway may all run on the same host; the
  current gateway1/gateway2 split is a development convenience, not a
  constraint.
- `add_caddy` is a role shared by every host that terminates TLS.
  `add_vpn_gateway` keeps only wg-easy. `add_lobby` is deleted.

## Trust Boundary

The publishing model is deliberate:

- The publish account has no sudo, is not in the `docker` group, and owns only
  the artifact directories and the trigger directory. It cannot read WireGuard
  keys: `/opt/vpn-gateway/wg-easy` is root-owned, `wg-easy.db` is `0600`.
- The host never executes publisher-supplied build instructions. No Dockerfile
  runs on the host, so there is no build-time command execution, no builder
  cache to poison, and no build-time network access.
- The publish key still controls the image that runs. That image starts with the
  root-owned compose definition, has no host mounts and no Docker socket, and
  joins `vpn-gateway-proxy` next to wg-easy.
- So the publish key is equivalent to "run arbitrary code in a network-adjacent
  container". Reading WireGuard keys requires a second, independent compromise
  of wg-easy itself. That is the accepted trade.
- On a host without WireGuard, the same model is simply "publisher code runs in
  a hardened container".

This text ships in the generated publish README, not only here.

## Target Architecture

```text
gateway1 (group: website)
  add_autoupdate, add_docker, add_firewall, add_caddy, add_website
  /opt/caddy/                  root-owned
    docker-compose.yml         caddy only
    Caddyfile                  generated from add_caddy_routes
  /opt/public/                 root-owned
    docker-compose.yml         selected services, image refs only
    website/                   artifact dir, only for selected services
      website.tar.zst          uploaded image archive
      website.tar.zst.sha256   optional integrity file
    lobby/
      lobby.tar.zst
    triggers/
      website.restart
      lobby.restart

gateway2 (group: vpn_gateway)
  add_autoupdate, add_docker, add_firewall, add_caddy, add_vpn_gateway
  /opt/caddy/                  same caddy role, routes: vpn.co3d.eu
  /opt/vpn-gateway/            wg-easy only, no publish account, no site roles
```

A single host may run both sides: one `add_caddy` with routes for every name it
terminates, `add_website` for the workloads, and `add_vpn_gateway` for wg-easy.
Nothing in the roles depends on the split.

Both hosts join the external `vpn-gateway-proxy` Docker network. Caddy reaches
workloads by compose service name (`website:80`, `lobby:8080`).

## Image Contract

CI produces an archive per service. The contract is exact so the host can
enforce it:

```bash
# in CI, exact tag and labels matter
docker buildx build --platform linux/amd64 --load \
  --label com.co3d.service=public \
  --label com.co3d.service.name=website \
  -t homelab/website:latest .
docker save homelab/website:latest | zstd -T0 -3 > website.tar.zst
sha256sum website.tar.zst > website.tar.zst.sha256

rsync -az --delete --chmod=D755,F644 \
  -e 'ssh -i ~/.ssh/website-publish -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
  website.tar.zst website.tar.zst.sha256 \
  website-deploy@<host>:/opt/public/website/

ssh -i ~/.ssh/website-publish -o IdentitiesOnly=yes \
  website-deploy@<host> 'touch /opt/public/triggers/website.restart'
```

Requirements:

- tag `homelab/<service>:latest`
- image labels `com.co3d.service=public` and
  `com.co3d.service.name=<service>`
- built for the host architecture (`linux/amd64` for both gateways)
- the image listens on the port Caddy routes to (`website` 80, `lobby` 8080)

The host rejects an archive whose tag or labels do not match, and logs the
reason. Missing labels are a publish bug, not a host problem.

`<service>.tar.zst.sha256` is optional. If present, the host verifies it before
loading.

Because prior images are pruned, there is no image rollback on the host. Roll
back by republishing the previous commit's archive.

## Deploy Script

`/usr/local/sbin/public-deploy`, installed by `add_website`, run by
`/etc/cron.d/public-deploy` every minute:

```bash
#!/usr/bin/env bash
set -euo pipefail

project_dir="{{ add_website_project_dir }}"
trigger_dir="{{ add_website_trigger_dir }}"
compose_file="{{ add_website_compose_file }}"
image_prefix="{{ add_website_image_prefix }}"

exec 9>/run/lock/public-deploy.lock
flock -n 9 || exit 0

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

shopt -s nullglob
for marker in "$trigger_dir"/*.restart; do
    service="$(basename "$marker" .restart)"
    archive="$project_dir/$service/$service.tar.zst"
    reference="$image_prefix/$service:latest"

    # Consume first so a bad publish cannot hot-loop.
    rm -f "$marker"

    if [ ! -f "$archive" ]; then
        log "skipping $service: missing $archive"
        continue
    fi

    if [ -f "$archive.sha256" ] \
        && ! (cd "$project_dir/$service" && sha256sum -c --status "$service.tar.zst.sha256"); then
        log "skipping $service: checksum mismatch"
        continue
    fi

    if ! services_output="$(cd "$project_dir" && docker compose config --services 2>&1)"; then
        log "skipping $service: docker compose config failed: $services_output"
        continue
    fi

    if ! printf '%s\n' "$services_output" | grep -qx "$service"; then
        log "skipping $service: not a service in $compose_file (services: $(printf '%s' "$services_output" | tr '\n' ' '))"
        continue
    fi

    log "loading $service"
    if ! load_output="$(zstd -dc "$archive" | docker load)"; then
        log "skipping $service: docker load failed"
        continue
    fi

    # The archive must contain the exact host tag; otherwise a stale image with
    # the right name could pass the label check below.
    if ! printf '%s\n' "$load_output" | grep -qx "Loaded image: $reference"; then
        log "rejecting $service: archive did not contain $reference"
        docker image prune -af --filter "label=com.co3d.service=public" >/dev/null 2>&1 || true
        continue
    fi

    labels="$(docker image inspect --format \
        '{{index .Config.Labels "com.co3d.service"}}|{{index .Config.Labels "com.co3d.service.name"}}' \
        "$reference" 2>/dev/null || true)"
    if [ "$labels" != "public|$service" ]; then
        log "rejecting $service: expected labels public|$service, got '$labels'"
        docker image rm "$reference" >/dev/null 2>&1 || true
        docker image prune -f >/dev/null 2>&1 || true
        continue
    fi

    log "restarting $service"
    if (cd "$project_dir" && docker compose up -d --no-deps --force-recreate "$service"); then
        # Host-owned cleanup: prior tagged images, then unlabeled dangling layers.
        docker image prune -af --filter "label=com.co3d.service=public" >/dev/null 2>&1 || true
        docker image prune -f >/dev/null 2>&1 || true
        rm -f "$archive" "$archive.sha256"
        log "$service deploy complete"
    else
        log "$service deploy failed; archive kept for inspection"
    fi
done
```

Deliberate properties:

- marker consumed before the load, so a failing archive cannot hot-loop
- checksum verified when the publisher supplies one
- labels and tag enforced by the host; a non-compliant image is removed and
  pruned, including one that loaded under the wrong tag
- one service per marker, so one service never recreates another
- prune runs only after a successful `docker compose up`
- `docker image prune -af` with the label filter removes every unused public
  image, including prior versions of other services; images in use by a
  container are never pruned
- `docker image prune -f` catches unlabeled dangling layers from interrupted
  uploads or loads
- the archive is deleted only after a successful deploy; on failure it stays for
  inspection and is overwritten by the next publish
- `flock` prevents cron and a manual run from overlapping

Manual restart of the currently loaded image (no archive needed):

```bash
cd /opt/public && docker compose up -d --no-deps lobby
```

## Roles

### new: `add_caddy`

Extracted from `add_vpn_gateway`. Owns Caddy only.

Defaults (renamed from `add_vpn_gateway_caddy_*`):

```yaml
add_caddy_project_dir: /opt/caddy
add_caddy_compose_file: "{{ add_caddy_project_dir }}/docker-compose.yml"
add_caddy_caddyfile_path: "{{ add_caddy_project_dir }}/Caddyfile"
add_caddy_acme_email: ""
add_caddy_routes: []
add_caddy_proxy_network_name: vpn-gateway-proxy
add_caddy_image: caddy:2.11.7-alpine
add_caddy_http_port: 80
add_caddy_https_port: 443
add_caddy_http3: true
add_caddy_use_internal_tls: false
```

Tasks: validate routes, create the proxy network, render `Caddyfile` and
`docker-compose.yml`, `docker compose up -d`, show status. No `depends_on`, no
wg-easy references.

### `add_vpn_gateway`

Keep wg-easy only: user, data dir, compose file with the `wg` and `proxy`
networks, wg port, status. Remove caddy defaults, templates, tasks, Caddyfile,
and the `add_vpn_gateway_caddy_*` / `add_vpn_gateway_routes` variables.

### `add_website`

Becomes "public workloads".

Defaults:

```yaml
add_website_project_dir: /opt/public
add_website_compose_file: "{{ add_website_project_dir }}/docker-compose.yml"
# Which of the role's services this host runs. Required; the role asserts it is
# non-empty. A lobby-only host sets [lobby].
add_website_services: []
add_website_trigger_dir: "{{ add_website_project_dir }}/triggers"
add_website_image_prefix: homelab
add_website_proxy_network_name: vpn-gateway-proxy
add_website_owner: root

add_website_publish_user: website-deploy
add_website_publish_key_path: /root/website-publish
add_website_publish_key_rotate: true
add_website_readme_path: /root/website-publish.README.md
add_website_packages:
  - cron
  - logrotate
  - openssh-client
  - rsync
  - zstd

add_website_deploy_script_path: /usr/local/sbin/public-deploy
add_website_cron_file: /etc/cron.d/public-deploy
add_website_log_file: /var/log/public-deploy.log
```

Removed: `add_website_domain`, `add_website_image`,
`add_website_container_name`, `add_website_content_dir`,
`add_website_publish_bind`, `add_website_publish_port`,
`add_website_join_proxy_network`, `add_website_pull_images`,
`add_website_placeholder_enabled`, and all `add_lobby_*` variables.

Compose template (`templates/docker-compose.yml.j2`), image references only.
Each block is conditional on the host's service selection, so a lobby-only host
renders only the lobby service:

```yaml
services:
{% if 'website' in add_website_services %}
  website:
    image: "{{ add_website_image_prefix }}/website:latest"
    pull_policy: never
    restart: unless-stopped
    expose:
      - "80"
    labels:
      com.co3d.service: public
    networks:
      - proxy
{% endif %}
{% if 'lobby' in add_website_services %}
  lobby:
    image: "{{ add_website_image_prefix }}/lobby:latest"
    pull_policy: never
    restart: unless-stopped
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - "no-new-privileges:true"
    mem_limit: 128m
    pids_limit: 64
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    expose:
      - "8080"
    labels:
      com.co3d.service: public
    networks:
      - proxy
{% endif %}

networks:
  proxy:
    external: true
    name: {{ add_website_proxy_network_name }}
```

The `labels:` under each service label the **container**, for `docker ps`
filtering. Pruning uses the **image** labels from the publish contract; they are
validated at load time.

Tasks:

1. Check Docker Compose and assert `add_website_services` is non-empty.
2. Install publish packages, create the publish user, rotate/authorize the key,
   render the README.
3. Create `/opt/public`, each service artifact directory, and `triggers/`, all
   owned by the publish user where CI writes.
4. Render the compose file, the deploy script, the cron entry, and logrotate.
5. If every `homelab/<service>:latest` image already exists, run
   `docker compose up -d --no-build` so compose changes apply. On a fresh host
   the images do not exist yet; the first publish creates the containers.
6. Show status.

There is no placeholder image. The host cannot build one by design, so a fresh
host serves nothing until CI publishes. Caddy returns 502 until then; that is
expected.

#### Publishing security model

This text belongs in the generated publish README:

> The publish account (`website-deploy`) has no sudo, is not in the `docker`
> group, and owns only the artifact and trigger directories. It cannot read the
> WireGuard keys directly: `/opt/vpn-gateway/wg-easy` is root-owned and
> `wg-easy.db` is `0600`.
>
> Publishing does not execute build instructions on this host. CI sends a
> finished image archive; the host verifies its checksum when one is provided,
> loads it, checks the `com.co3d.service` labels, and restarts the container.
>
> The publish key still controls the code that runs. Treat it as permission to
> run arbitrary code in a container that is network-adjacent to wg-easy. Reading
> WireGuard keys additionally requires a wg-easy vulnerability or a container
> escape. Keep the key in CI secrets only, never publish from an untrusted
> branch, and rotate it after any suspicion.
>
> Every publish deletes the previous images for the public services. There is no
> image rollback on the host; roll back by publishing the previous commit.

### delete: `add_lobby`

All defaults, tasks, and templates. `context/guides/lobby.md` is deleted as
well: lobby application behaviour (rooms in memory, hashcash, limits, WebSocket
TTL) is the publisher's concern and belongs in the minigames repository. This
repository documents only the host contract: image name, labels, port 8080, and
the Caddy route.

## Inventory

`inventory/hosts.yml`:

- keep `gateway1` in `website`; the group means "runs public workloads", not
  "runs the website service"
- keep or remove `gateway2` from `website` depending on where the static site
  runs; the role now supports a subset of services per host, so both layouts
  work
- keep firewall exposure in each gateway's `host.yml`:
  `add_firewall_allowed_tcp_ports`, `add_firewall_allowed_udp_ports`, and, for
  VPN hosts, `add_firewall_wireguard_ports`

### Lobby-only host

`gateway1` serves only `lobby.co3d.eu`. Its selected services and its route list
must agree:

`inventory/host_vars/gateway1/host.yml`:

```yaml
---
ansible_user: root
add_firewall_ssh_port: 22

add_caddy_acme_email: "lars@co3d.eu"
add_caddy_routes:
  - hostnames:
      - "lobby.co3d.eu"
    upstream: "lobby:8080"

add_website_services:
  - lobby
```

No `co3d.eu` route, no `add_website_domain`, no `add_lobby_domain`, no wg-easy
variables. Caddy on this host claims only the lobby name, so the certificate
and the DNS record are independent of wherever `co3d.eu` lives.

### Host that keeps the static site

If `co3d.eu` stays on `gateway2` for now, that host keeps its route and selects
only the website service:

`inventory/host_vars/gateway2/host.yml`:

```yaml
---
ansible_user: root
add_firewall_ssh_port: 22

add_caddy_acme_email: "lars@co3d.eu"
add_caddy_routes:
  - hostnames:
      - "vpn.co3d.eu"
    upstream: "wg-easy:80"
  - hostnames:
      - "co3d.eu"
    upstream: "website:80"

add_website_services:
  - website
```

wg-easy variables stay on this host. When the site moves to `gateway1`, add
`website` to that host's `add_website_services`, add the `co3d.eu` route there,
and remove `gateway2` from the `website` group.

Keeping the site on `gateway2` means the publish account stays co-hosted with
wg-easy, so the trust tradeoff in the co-hosting section applies until the site
moves.

### No per-service scalars

Routing stays in `add_caddy_routes`, the service selection stays in
`add_website_services`, and the image contract fixes each container port. There
is no `add_website_domain`, `add_lobby_domain`, or per-service publish address.

## Playbook

`playbooks/add-public-gateway.yml`:

```yaml
roles:
  - add_autoupdate
  - add_docker
  - add_firewall
  - add_caddy
  - add_website        # when: inventory_hostname in groups['website']
  - add_vpn_gateway    # when: inventory_hostname in groups['vpn_gateway']
```

- `add_firewall` now runs on both groups.
- `record_deployment_roles` and the metadata service list become
  `add_caddy` and drop `add_lobby`.

## Tests

`tests/verify-public-gateway-config.ps1`:

- role existence: `add_firewall`, `add_caddy`, `add_vpn_gateway`,
  `add_website` (remove `add_lobby`)
- co-hosting is allowed: do **not** assert that `vpn_gateway` and `website` are
  disjoint; a host may appear in both groups
- gateway hosts: `add_caddy_acme_email`, `add_caddy_routes`, unique hostnames,
  each route has hostnames and an upstream
- vpn hosts: keep the `# vault.yml:` marker and wg-easy password entry
- website hosts: no domain scalars; for every name in `add_website_services`,
  assert `add_caddy_routes` contains a route whose upstream starts with
  `<service>:`; a lobby-only host must not be required to route `co3d.eu`
- assert the deploy script, cron template, and logrotate template exist in
  `playbooks/roles/add_website/templates/`
- keep the "must not depend on Proxmox/PXE" check

New test: render the deploy script and run it against a fake `docker` on `PATH`.
Cases: missing archive, missing marker, checksum mismatch, wrong tag in the
archive, wrong labels, load failure, successful load plus restart plus prune.
Assert the marker is consumed exactly once and the archive is deleted only on
success.

## Docs

- `context/guides/public-gateway-setup.md`: architecture, ports, routes, image
  contract, publish README, firewall, validation, troubleshooting. Rename
  variable references to `add_caddy_*` and replace the rsync/Dockerfile flow
  with the archive flow. It documents the host contract only: service name,
  image, labels, port, route. Application behaviour belongs to the publisher
  repository, not here.
- The generated publish README includes the image contract and the "Publishing
  security model" text, so the trust boundary ships with the key.
- Delete `context/guides/lobby.md`. Lobby application behaviour (rooms,
  hashcash, WebSocket TTL, limits) is the publisher's concern.
- `context/guides/deployment-history.md`: add an entry after rollout.
- `README.md`: check the role list and any publishing commands.

## Migration

This migration puts the **lobby** on `gateway1` first, because that is the only
name it needs to serve. The static site can follow later or stay where it is.

The ordering avoids two Caddy instances binding the same ports and keeps a
rollback path. A single co-hosted deployment skips most of this. While the
static site stays on `gateway2`, its role and publish account stay there too, so
the co-hosting tradeoff applies to that host until the site moves.

### Phase 1: Caddy on the new web host

1. Add the `add_caddy` role and run it on `gateway1` only with
   `--limit gateway1`, using `add_caddy_use_internal_tls: true`. The role is
   written for both hosts, but gateway2 still runs the legacy Caddy inside
   `/opt/vpn-gateway` and would bind the same ports.
2. Verify: `docker compose -f /opt/caddy/docker-compose.yml ps`, then
   `curl -k --resolve lobby.co3d.eu:443:127.0.0.1 https://lobby.co3d.eu/healthz -I`.
   A 502 is expected; the point is the TLS handshake before the workload exists.
3. Leave gateway2 untouched until Phase 3.

### Phase 2: lobby on gateway1

1. Confirm the lobby code is in the minigames repository. The host no longer
   builds from its own copy, so anything edited only in `/opt/lobby/src` must be
   pushed to that repository first.
2. Build and publish the lobby archive from CI: tag `homelab/lobby:latest`,
   label `com.co3d.service=public` and `com.co3d.service.name=lobby`, upload
   `lobby.tar.zst`, touch `triggers/lobby.restart`.
3. Stop the legacy lobby project if it exists:
   `docker compose -f /opt/lobby/docker-compose.yml down`.
4. Run the playbook; confirm
   `docker compose -f /opt/public/docker-compose.yml ps` shows only the lobby
   container on this host.
5. Watch `/var/log/public-deploy.log` for `load`, `restart`, and `deploy
   complete`.
6. Point `lobby.co3d.eu` DNS at `gateway1`. ACME HTTP validation needs the name
   to resolve here, so this comes before public TLS.
7. Flip `add_caddy_use_internal_tls` to false, rerun, and verify the
   certificate with `curl -I https://lobby.co3d.eu/healthz`.

### Phase 3: split Caddy on gateway2

1. Stop the legacy Caddy first, otherwise the new project cannot bind 80/443:
   `docker compose -f /opt/vpn-gateway/docker-compose.yml stop caddy`.
2. Rerun the playbook for both hosts and verify `https://vpn.co3d.eu` still
   serves through the new `/opt/caddy` project.
3. Re-render the wg-easy project without caddy and remove orphans:
   `docker compose -f /opt/vpn-gateway/docker-compose.yml up -d --remove-orphans`.
4. Confirm no WireGuard key file has a non-root reader:
   `find /opt/vpn-gateway -maxdepth 2 -ls`.

Do not remove the publish account or the website role from `gateway2` while the
static site still runs there. That cleanup belongs to the optional move below.

### Moving the static site later

1. Build and publish the website archive to `gateway1`.
2. Add `website` to `gateway1`'s `add_website_services` and add the `co3d.eu`
   route to its `add_caddy_routes`.
3. Rerun the playbook, then point `co3d.eu` DNS at `gateway1`.
4. Remove `gateway2` from the `website` group and rerun the playbook.
5. Stop and remove its legacy website project, then remove the publish account
   and key: `userdel -r website-deploy`, `rm -f /root/website-publish*`.

### Rollback

- Workloads: republish the previous commit's archives; the host prunes old
  images by design, so there is no local image to switch back to.
- Gateway caddy: stop `/opt/caddy`, then `docker start` the stopped legacy
  caddy container. Keep the legacy container until the new one has served a
  certificate.

## Co-hosting and the WireGuard Boundary

Co-hosting is supported. The archive model removes build-time execution from the
host, but it does not make the publisher untrusted:

- no Dockerfile runs on the host
- the publisher still controls the image that runs
- the container joins the same network as wg-easy, so a compromised workload
  can attack wg-easy's API, but cannot read its files
- reading WireGuard keys needs a wg-easy vulnerability or container escape in
  addition to the publish key

The cheapest independent hardening is network separation: attach Caddy to both
a workload network and a wg-easy network, and keep the two app networks
disjoint. A compromised workload then cannot reach wg-easy at all, while Caddy
still proxies both.

The plan does not enforce this; it keeps the roles composable so the choice
stays an inventory decision.

## Open Questions

Defaults are chosen for the plan; flip them before implementation if wrong.

1. Start with `gateway1` serving only `lobby.co3d.eu` (`add_website_services:
   [lobby]`, one route), leaving `co3d.eu` on `gateway2` until the optional
   move? Default: yes. The roles stay composable so any host can run more
   services later.
2. Should `add_firewall` and fail2ban run on `gateway1` (ports 80/443), or does
   the provider firewall stay in charge? Default: run it, verifying the SSH rule
   before enabling.
3. Drop split-host publishing (`add_website_publish_bind`/`port`) since Caddy
   and workloads now share a host? Default: drop. Routes still accept remote
   upstreams such as `10.13.0.20:8080` for a future VPN-connected service.
4. Keep the role name `add_website` even though it now hosts any container?
   Default: keep, to avoid touching the playbook, tests, and deployment history.
5. Enforce the label contract by rejecting non-compliant images, or warn and
   run them anyway? Default: reject. It keeps host-side pruning correct.
6. Keep the previous image for rollback? Default: no. Prune everything unused
   after a successful restart, and roll back by republishing.

## Out of Scope

- a container registry
- building images on the host
- image signing beyond an optional checksum
- moving the VPN gateway itself
- replacing Caddy with `caddy-docker-proxy` labels
- per-service health checks beyond what each image already ships
- tightening the website container (`cap_drop`, `read_only`, non-root port);
  the site contract currently assumes nginx on port 80 with default caps
