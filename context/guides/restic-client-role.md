# Restic Client Role

The `add_restic_client` role installs `restic`, renders backup and restore
scripts per configured repository, and installs disabled-by-default backup
timers that can be enabled later.

## Repository Config Shape

Non-secret metadata belongs in the host vars:

```yaml
add_restic_client_repositories:
  - name: "paperless"
    path: "/media/paperless-data/export"
    repository: "rest:http://{rest_username}:{rest_password}@backup.lan:8000/{rest_username}/paperless"
    backup_schedule_enabled: false
```

Repository credentials belong in the host vault:

```yaml
add_restic_client_repository_credentials:
  paperless:
    rest_username: "REST_SERVER_USERNAME"
    rest_password: "REST_SERVER_ACCESS_PASSWORD"
    repository_password: "RESTIC_REPOSITORY_PASSWORD"
```

## Runtime Behavior

Each configured repository gets:

- a `restic-backup-<name>` script
- a `restic-restore-<name>` script
- a `restic-backup-<name>.service` unit
- a `restic-backup-<name>.timer` unit

The scripts load `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, and the restore target
path from a root-managed env file.

For backups, the generated Linux helper also auto-discovers `.backupignore`
files in the repository `path` and its first child level, and passes each one
to restic with `--iexclude-file`. This mirrors the behavior of
`context/restic-client/New-ResticSnapshot.ps1`.

If needed, a repository can also run one `backup_pre_command` before `restic
backup`. This is useful for applications like Paperless that need to refresh an
export directory before the filesystem backup runs.

The restore script prompts for confirmation and restores in place with:
`restic restore <snapshot> --target / --include <path>`

The backup timer is installed but disabled unless
`backup_schedule_enabled: true` is set for that repository.

Example:

```bash
restic-backup-paperless
restic-restore-paperless
restic-restore-paperless latest
restic-restore-paperless 7c9c4f15
```

Example pre-backup hook:

```yaml
add_restic_client_repositories:
  - name: "paperless"
    path: "/media/paperless-data/export"
    repository: "rest:http://{rest_username}:{rest_password}@backup.lan:8000/{rest_username}/paperless"
    backup_pre_command: "/usr/local/bin/paperless-export-backup"
```

If the repository URL contains `{rest_username}` and `{rest_password}`, the role
replaces those placeholders from
`add_restic_client_repository_credentials.<name>` before writing the env file.
The helper scripts print a redacted repository string so the embedded password
is not echoed back to the terminal.

Example ignore file for excluding a generated subtree from snapshots:

```text
/thumbs
```

For hosts that also use `add_admin_scripts`, the same script name is installed
in the admin user's home directory as a wrapper, and timer start/stop helpers
are exposed through the normal service-group scripts.
