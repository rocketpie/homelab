# Service Admin Scripts

Homelab service users should get small host-local admin scripts in their home
directory.

The default pattern is:

- install scripts under `~/`
- provide one universal `host-status` script
- provide service-specific `start-<name>` and `stop-<name>` scripts
- allow extra one-shot scripts for service-specific workflows

The `add_admin_scripts` role should assemble those service-specific scripts
from playbook-provided service groups, instead of hardcoding knowledge about
specific roles into the role defaults.

For workflows that are not just start/stop operations, the playbook may also
pass `add_admin_scripts_extra_scripts` to install additional executable helper
scripts in the same location.

`add_admin_scripts_user` should normally be chosen at the host level.
`add_admin_scripts_group` exists only to control group ownership of the
installed script files, and in the common case it should simply default to the
same value as `add_admin_scripts_user`.

## Purpose

These scripts give the service user a lightweight operational toolbox on the
host itself, without needing to remember exact `systemctl` commands.

`host-status` should show:

- relevant systemd units for that host
- whether each unit is enabled
- whether each unit is active
- recent deployment history from `/var/lib/homelab/deploy-history.yml`

The service-specific scripts should:

- use `sudo systemctl`
- start scripts should enable and/or start the relevant units
- stop scripts should disable and/or stop the relevant units
- warn cleanly if a referenced unit is not installed yet

## Example: restic1

On `restic1`, the `add_admin_scripts` role installs scripts for `archivar`
covering:

- `rest-server`
- `restic-retention`
- `rclone-sync`
- `pull-rclone-remote`

`playbooks/add-rest-server.yml` currently assembles those script groups from the
service roles it installs.

When a future `add_restic_retention` role exists, that playbook can add the
`restic-retention` script group at the same integration point.
