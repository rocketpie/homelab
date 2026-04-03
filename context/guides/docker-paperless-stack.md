# Paperless Role

This guide covers the `add_paperless` role.

It assumes the host already uses the base Docker host workflow from
`context/guides/docker-hosts.md`.

## Scope

`playbooks/add-docker.yml` currently does two separate things:

- installs the Docker host base on hosts in the `docker` inventory group
- installs Paperless on hosts in the `paperless` inventory group

`add_paperless` is the extra application role layered onto a Docker host. It is
not the place to define generic Docker host or reverse proxy behavior.

## Host Variables

Paperless currently expects these host variables:

- `add_paperless_owner_user`
- `add_paperless_time_zone`
- `add_paperless_ocr_language`

On `dockerhost2`, the Paperless bind mounts live under `/media/paperless-data`
and the compose project lives under `/home/<owner>/paperless`.

If the host should expose Paperless under a hostname such as `paperless.lan`,
define that in the Docker host config with
`add_docker_reverse_proxy_bindings`, not in the Paperless role.
TLS termination for that hostname is also managed by the Docker host role, not
the Paperless role.

The Paperless container uses `USERMAP_UID` and `USERMAP_GID` to remap its
internal service user to the host owner account. Do not also force a Compose
`user:` override for the `webserver` service, or the container will start
without the privileges it needs for that remap step.

## Vault Variables

Store Paperless secrets in the host vault:

```yaml
add_paperless_db_password: "PAPERLESS_DB_PASSWORD_HERE"
add_paperless_secret_key: "PAPERLESS_SECRET_KEY_HERE"
```

## Service Management

The `add_paperless` role installs a `paperless.service` systemd unit that runs
the compose stack, but it does not pull images or start the stack
automatically. This avoids surprising restarts during repeat playbook runs.

`add_admin_scripts` installs `start-paperless`, `stop-paperless`,
`host-status`, `paperless-create-superuser`, and `paperless-export-backup` for
the configured admin user.

Bring the stack up explicitly when you are ready:

```bash
start-paperless
```

Or:

```bash
cd ~/paperless
docker compose up --detach --remove-orphans
```

## Recovery

For export-based recovery after a rebuild or data loss, see
`context/guides/paperless-recovery.md`.

## Backups

For Paperless, the practical backup input is usually the exported data under
`/media/paperless-data/export`, not the live database internals. The
`add_paperless` role installs `/usr/local/bin/paperless-export-backup`, and the
`add_restic_client` role can call that script via a repository-local
`backup_pre_command` immediately before the restic snapshot starts.
