# Rest Server Role

The `add_restic_server` role builds and installs `rest-server` from the upstream
Git repository on the target host and manages it as a systemd service.

## Current assumptions

- target host is Linux `amd64`
- Go is installed from the official upstream tarball because `rest-server`
  currently requires Go 1.24+ to build
- repository data lives under `add_restic_server_data_dir`, which defaults to
  `/media/backups/restic` for `restic1`
- the systemd service writes logs to journald by default via `--log -`

## Auth choice required

Before running `playbooks/add-rest-server.yml`, choose one of these:

- set `add_restic_server_no_auth: true` for a LAN-only bootstrap
- provide `add_restic_server_htpasswd_entries` in the host vault with plaintext
  passwords

The role intentionally refuses to start `rest-server` until one of those
choices is made explicitly.
