# Restic Client Windows Script

The shared runtime now lives at `apps/restic-client/restic-client.ps1`.

This repo does not deploy Windows hosts through Ansible, but the same script
can still be used locally on Windows with a matching JSON config.

## Interactive Use

Run the script without arguments to open the interactive menu:

```powershell
pwsh apps/restic-client/restic-client.ps1
```

Available actions:

- run backup now
- run retention now
- show snapshots for each configured path
- restore files for repositories that allow restore
- run a custom restic command with the configured environment

## Non-Interactive Use

The script also supports explicit actions:

```powershell
pwsh apps/restic-client/restic-client.ps1 -RunSnapshot
pwsh apps/restic-client/restic-client.ps1 -RunRetention
pwsh apps/restic-client/restic-client.ps1 -ShowStatus
```

## Config

Use `apps/restic-client/restic-client.schema.json` as the schema reference for
your local config.

Repository entries use explicit capability flags:

```json
{
  "name": "documents",
  "path": "D:\\Documents",
  "resticRepository": "rest:http://user:password@backup.lan:8000/user/documents",
  "repositoryPassword": "RESTIC_REPOSITORY_PASSWORD",
  "snapshotAllowed": true,
  "restoreAllowed": true,
  "forgetAllowed": false,
  "resticBackupOptions": [
    "--skip-if-unchanged"
  ],
  "forgetArgs": []
}
```

Windows-specific scheduled-task management is no longer part of the shared
script.

## Backup Ignore Files

The script discovers `.backupignore` files in each configured backup root and
one level below it, then forwards them to restic with `--iexclude-file`.
