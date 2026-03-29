# Restic Retention Role

The `add_restic_retention` role installs `restic`, renders a single
maintenance script that loops over configured repositories, and schedules it
with a systemd timer.

## Assumptions

- the role runs on Linux hosts
- retention operates on the local on-disk repository paths under
  `add_restic_retention_root_dir`
- the service runs as `add_restic_retention_service_user`
- repository passwords are provided from the host vault through
  `add_restic_retention_repository_passwords`
- the timer is enabled after install

## Repository config shape

Non-secret metadata belongs in the host vars:

```yaml
add_restic_retention_service_user: "archivar"
add_restic_retention_repositories:
  - user: "restic-server-test"
    repository: "repo1"
    enabled: true
    forget_args:
      - "--keep-within-daily"
      - "14d"
      - "--keep-within-weekly"
      - "8w"
      - "--keep-within-monthly"
      - "12m"
      - "--prune"
```

Secrets belong in the host vault:

```yaml
# add_restic_retention_repository_passwords:
#   "restic-server-test/repo1": "RESTIC_REPO_PASSWORD"
```

## Warnings

The role warns when:

- a configured repository does not exist yet
- an existing on-disk repository has no retention configuration

Configured but missing repositories are skipped by the runtime maintenance
script until they appear on disk.
