# Immich Role

This guide covers the `add_immich` role.

It assumes the host already uses the base Docker host workflow from
`context/guides/docker-hosts.md`.

## Scope

`playbooks/add-docker.yml` currently:

- installs the Docker host base on hosts in the `docker` inventory group
- installs Paperless on hosts in the `paperless` inventory group
- installs Immich on hosts in the `immich` inventory group

`add_immich` is the application role layered onto a Docker host. Generic Docker
host and reverse proxy behavior still belongs in `add_docker`.

## Host Variables

Immich currently expects these host variables:

- `add_immich_owner_user`
- `add_immich_time_zone`

On `dockerhost2`, the bind mounts live under `/media/immich-data` and the
compose project lives under `/home/<owner>/immich-app`.

If the host should expose Immich under names such as `immich.lan` or
`immich.vpn`, define that in the Docker host config with
`add_docker_reverse_proxy_bindings`, not in the Immich role.
TLS termination for those names is also managed by the Docker host role.

## Vault Variables

Store the local database password in the host vault:

```yaml
add_immich_db_password: "IMMICH_DB_PASSWORD_HERE"
```

## Version Pinning

The role writes the official `.env` style variables and defaults
`add_immich_version` to `v2`, which tracks the current stable major line.
Pin a specific Immich release by overriding `add_immich_version` in host vars if
you need a controlled upgrade or rollback.

## Service Management

The `add_immich` role installs an `immich.service` systemd unit that runs the
compose stack, but it does not pull images or start the stack automatically.
This avoids surprising restarts during repeat playbook runs.

`add_admin_scripts` installs `start-immich`, `stop-immich`, and `host-status`
for the configured admin user.

Bring the stack up explicitly when you are ready:

```bash
start-immich
```

Or:

```bash
cd ~/immich-app
docker compose up --detach --remove-orphans
```

## Backups

For the current `dockerhost2` setup, restic snapshots the uploaded asset tree
under `/media/immich-data/library`. The live PostgreSQL data remains local under
`/media/immich-data/postgres`.
