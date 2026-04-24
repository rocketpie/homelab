# Restic Client Role

The `add_restic_client` role installs `pwsh`, installs `restic` from the
official upstream release archive, renders one generated JSON config, and
installs one shared `restic-client.ps1` runtime.

The source-of-truth app files live under `apps/restic-client/`.

## Repository Config Shape

`add_restic_client_repositories` now uses the same field names as the generated
runtime JSON. In practice, the inventory is a YAML representation of the final
repository objects, and the role writes that list straight into
`restic-client.json`.

If the repository list gets large, prefer a sibling
`add_restic_client_repositories.json.j2` file under the host's `host_vars`
directory and point `host.yml` at it:

```yaml
add_restic_client_repositories_template_file: "add_restic_client_repositories.json.j2"
```

The role renders that file with Jinja and parses the result as JSON before it
generates `restic-client.json`.

You can still keep secrets in vaulted vars and reference them from the repo
entries:

```yaml
add_restic_client_repositories_template_file: "add_restic_client_repositories.json.j2"
```

```json
[
  {
    "name": "paperless",
    "path": "/media/paperless-data/export",
    "resticRepository": "rest:http://{{ add_restic_client_repository_secrets.paperless.rest_username }}:{{ add_restic_client_repository_secrets.paperless.rest_password }}@backup.lan:8000/{{ add_restic_client_repository_secrets.paperless.rest_username }}/paperless",
    "repositoryPassword": "{{ add_restic_client_repository_secrets.paperless.repository_password }}",
    "snapshotAllowed": true,
    "restoreAllowed": true,
    "forgetAllowed": false,
    "backupPreCommand": "/usr/local/bin/paperless-export-backup",
    "resticBackupOptions": [
      "--skip-if-unchanged"
    ],
    "forgetArgs": [],
    "restUsername": "{{ add_restic_client_repository_secrets.paperless.rest_username }}",
    "repositoryDisplay": "rest:http://{{ add_restic_client_repository_secrets.paperless.rest_username }}:***@backup.lan:8000/{{ add_restic_client_repository_secrets.paperless.rest_username }}/paperless"
  }
]
```

One workable secret helper map is:

```yaml
add_restic_client_repository_secrets:
  paperless:
    rest_username: "REST_SERVER_USERNAME"
    rest_password: "REST_SERVER_ACCESS_PASSWORD"
    repository_password: "RESTIC_REPOSITORY_PASSWORD"
```

Capability flags are explicit:

- `snapshotAllowed` controls snapshot runs and snapshot menu actions
- `restoreAllowed` controls restore menu actions
- `forgetAllowed` controls retention runs and forget menu actions

Rules:

- `path` no longer disables anything implicitly
- `backupPreCommand` and `resticBackupOptions` are snapshot-only settings
- `forgetArgs` are forget-only settings
- if `snapshotAllowed` or `restoreAllowed` is true while `path` is empty,
  the runtime and test play warn
- if `forgetAllowed` is true while `forgetArgs` is empty, the runtime and
  test play warn

## Runtime Behavior

The role installs:

- `restic-client.ps1`
- one generated `restic-client.json`
- `restic-client-snapshot.service` and `.timer` if any repo allows snapshots
- `restic-client-retention.service` and `.timer` if any repo allows forget
- one admin helper link named `restic-client`

The runtime supports:

- no arguments: interactive mode
- `-RunSnapshot`
- `-RunRetention`
- `-ShowStatus`

Interactive mode shows:

- the generated config path
- log path
- snapshot and retention timer state
- configured repositories and their allowed actions
- snapshot count and latest snapshot age with a short timeout

The runtime logs snapshot and retention output under
`add_restic_client_log_dir`, which defaults to `/var/log/restic-client`.

## Schedule Strings

Scheduling stays on systemd timers instead of cron.

Use:

- `add_restic_client_snapshot_schedule_on_calendar`
- `add_restic_client_retention_schedule_on_calendar`

Examples:

- `daily`
- `Mon..Fri 02:00`
- `hourly`
- `*-*-* *:00:00`

Why not cron:

- systemd timers are already the repo standard for Linux services
- `Persistent=true` catches up missed runs after downtime
- timer status is visible through the same admin scripts and `systemctl`
  workflow

## Adding A Client Repo

To add a new VM-side repo and its matching server-side forget config:

1. Add a new repository entry to the target host's
   `add_restic_client_repositories.json.j2`, using the final JSON field names.
2. Add matching secrets to the target host's
   `add_restic_client_repository_secrets` if you want to keep credentials out
   of the main host vars file.
3. Run `./run.ps1 playbooks/add-restic-client.yml`.
4. Initialize the repository from the client host.
5. Add the matching `rest-server` access user on `restic1` if needed.
6. Add the matching local server-side repository entry to
   `inventory/host_vars/restic1/host.yml` with:
   `snapshotAllowed: false`, `restoreAllowed: false`,
   `forgetAllowed: true`, `path: ""`, and a local `resticRepository` path.
7. Add the matching repository password entry to
   `restic1`'s `add_restic_client_repository_secrets`.
8. Run `./run.ps1 playbooks/add-rest-server.yml`.
9. Run `./run.ps1 playbooks/test-restic-server.yml` and review warnings.

Example local server-side entry:

```yaml
- name: "dockerhost2-paperless"
  resticRepository: "/media/backups/restic-data/dockerhost2/paperless"
  repositoryPassword: >-
    {{ add_restic_client_repository_secrets['dockerhost2-paperless'].repository_password }}
  path: ""
  snapshotAllowed: false
  restoreAllowed: false
  forgetAllowed: true
  resticBackupOptions: []
  forgetArgs:
    - "--keep-within"
    - "7d"
    - "--keep-weekly"
    - "4"
    - "--prune"
  restUsername: ""
  repositoryDisplay: "/media/backups/restic-data/dockerhost2/paperless"
```

## Admin Scripts

For hosts that also use `add_admin_scripts`, the admin user gets:

- `restic-client`
- `start-restic-client-snapshot` and `stop-restic-client-snapshot` when the
  snapshot timer exists
- `start-restic-client-retention` and `stop-restic-client-retention` when the
  retention timer exists
