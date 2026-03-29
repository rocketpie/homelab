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
- on `restic1`, the service stack is intended to run as `archivar`, and the
  role preserves that existing user instead of trying to convert it into a
  dedicated system account

## Auth required

Before running `playbooks/add-rest-server.yml`, provide
`add_restic_server_htpasswd_entries` in the host vault with plaintext `user` and `password` keys.

The role intentionally requires authentication and refuses to start
`rest-server` without htpasswd entries.

## Testing

Use `playbooks/test-restic-server.yml` for the first non-destructive validation
pass.

For client usage after the server is up, see `context/guides/use-restic-server.md`.

The `test_restic_server` role currently checks:

- the `rest-server` systemd unit is active
- the configured TCP port is listening
- unauthenticated HTTP access returns `401`
- authenticated HTTP access is no longer `401`

The authenticated probe targets a user-scoped path such as `/<username>/`.
That path works for the auth-only validation we want here, and avoids relying
on `add_restic_server` role defaults being in scope during a standalone
`test_restic_server` run. An authenticated request to `/` can still return
`401` when private repositories are enabled.

## TODO

- add a second-stage smoke test that uses the `restic` CLI to create a
  disposable repository, write one backup, list snapshots, and restore it
  again once this repo has a proper way to install `restic` for tests
