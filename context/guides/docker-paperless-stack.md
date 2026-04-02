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
