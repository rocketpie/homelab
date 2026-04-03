# Restic Client Windows Script

The `context/restic-client/New-ResticSnapshot.ps1` helper manages ad-hoc and
scheduled restic backups for the local Windows machine.

## Interactive Use

Run the script without arguments to open the interactive menu:

```powershell
pwsh context/restic-client/New-ResticSnapshot.ps1
```

Available actions:

- run backup now
- show snapshots for each configured path
- install or update the scheduled task
- remove the scheduled task

## Non-Interactive Use

The script also supports explicit actions:

```powershell
pwsh context/restic-client/New-ResticSnapshot.ps1 -Action Backup
pwsh context/restic-client/New-ResticSnapshot.ps1 -Action ShowSnapshots
pwsh context/restic-client/New-ResticSnapshot.ps1 -Action InstallSchedule
pwsh context/restic-client/New-ResticSnapshot.ps1 -Action RemoveSchedule
```

The scheduled task created by the script runs the `Backup` action directly, so
scheduled executions stay non-interactive.

## Config

`context/restic-client/New-ResticSnapshot.json` now supports an optional
`scheduledTask` block:

```json
"scheduledTask": {
  "name": "New-ResticSnapshot",
  "description": "Run configured restic snapshots",
  "dailyAt": "02:00"
}
```

If the block is missing, the script falls back to sensible defaults:

- task name: script file name
- description: generated from the script name
- daily trigger time: `02:00`

## Backup Ignore Files

The script discovers `.backupignore` files in each configured backup root and
one level below it, then forwards them to restic with `--iexclude-file`.
