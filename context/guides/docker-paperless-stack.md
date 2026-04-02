# Docker + Paperless Stack

`playbooks/add-docker.yml` installs the Docker engine on hosts in the
`docker` inventory group, then installs Paperless-ngx on hosts in the
`paperless` inventory group.

Current intended host:
- `dockerhost2`

## Host Variables

Paperless currently expects these host variables:

- `add_docker_users`
- `add_paperless_owner_user`
- `add_paperless_time_zone`
- `add_paperless_ocr_language`

On `dockerhost2`, the Paperless bind mounts live under `/media/paperless-data`
and the compose project lives under `/home/<owner>/paperless`.

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
the compose stack and enables it on boot. `add_admin_scripts` installs
`start-paperless`, `stop-paperless`, `host-status`, and
`paperless-create-superuser` for the configured admin user.

## Recovery

For export-based recovery after a rebuild or data loss, see
`context/guides/paperless-recovery.md`.

## Backups

For Paperless, the practical backup input is usually the exported data under
`/media/paperless-data/export`, not the live database internals. The
`add_paperless` role installs `/usr/local/bin/paperless-export-backup`, and the
`add_restic_client` role can call that script via a repository-local
`backup_pre_command` immediately before the restic snapshot starts.
