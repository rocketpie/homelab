Plan

Restic Stack Unification, Server Validation, and Rclone Admin Refresh
Summary
Refactor the backup stack around one shared restic-client PowerShell runtime and one generated JSON config, then use that same runtime for both normal client backups and server-side retention. Keep deep repository backup/restore checks in playbooks/test-restic-server.yml. Treat the interactive rclone admin work as phase 2 in the same implementation, after the restic schema and runtime are stable.

Public Interfaces And Config Changes
Replace the current split client/retention inventory model with one preferred schema under add_restic_client_repositories:

add_restic_client_repositories:
  - name: "paperless"
    repository: "rest:http://{rest_username}:{rest_password}@backup.lan:8000/{rest_username}/paperless"
    path: "/media/paperless-data/export"
    enabled: true
    backup_pre_command: "/usr/local/bin/paperless-export-backup"
    backup_options:
      - "--skip-if-unchanged"
    snapshot_enabled: true
    retention_enabled: false
    retention_forget_args: []
Add a new vaulted secrets mapping keyed by repository name:

add_restic_client_repository_secrets:
  paperless:
    rest_username: "..."
    rest_password: "..."
    repository_password: "..."
Add host-level schedule vars for the unified runtime:

add_restic_client_snapshot_schedule_enabled
add_restic_client_snapshot_timer_on_calendar
add_restic_client_snapshot_timer_randomized_delay_sec
add_restic_client_retention_schedule_enabled
add_restic_client_retention_timer_on_calendar
add_restic_client_retention_timer_randomized_delay_sec
Generated runtime config becomes a single JSON file consumed by one script and contains resolved repository URL/path, repository password, backup options, retention args, and log settings.

Deprecate and remove from active playbook wiring:

add_restic_client_repository_credentials
add_restic_retention_repositories
add_restic_retention_repository_passwords
Rule for the new schema: path: "" is valid and means snapshot and restore must be hidden/blocked for that repository, while retention may still run.

Implementation Changes
1. Shared restic runtime
Create one canonical PowerShell script plus schema under context/restic-client/, then have playbooks/roles/add_restic_client install that runtime onto Linux hosts.

The script contract will be:

no arguments: interactive mode
-RunSnapshot: run all enabled snapshot repositories
-RunRetention: run all enabled retention repositories
-ShowStatus: non-interactive summary for scripts/tests if needed
Interactive mode will show:

snapshot timer status
retention timer status
log path
configured repositories
per-repo snapshot count and latest snapshot age, with a 5s timeout per repo
actions to enable/disable timers
actions to run snapshot now / retention now
restore now for repos with a non-empty path
restic interactive shell for repos with a non-empty path
The script will log both snapshot and retention output to the configured log directory and redact embedded rest passwords in displayed repository strings.

2. Linux packaging and playbook wiring
Introduce a reusable add_powershell role for Ubuntu/Debian amd64, and call it from both playbooks/add-restic-client.yml and playbooks/add-rest-server.yml before add_restic_client.

Update add_restic_client to:

install restic from the official upstream Linux binary archive, defaulting to 0.18.1
stop using apt install restic
render one runtime config file
install one snapshot service/timer pair that executes restic-client.ps1 -RunSnapshot
install one retention service/timer pair that executes restic-client.ps1 -RunRetention
expose one admin script link named restic-client
expose admin service groups for the snapshot and retention timers instead of per-repo timer groups
Update playbooks/add-rest-server.yml to use add_restic_client directly for retention-capable local repositories and remove add_restic_retention from active use. The old role can then be deleted or left as dead code cleanup in the same change; implementation should delete it to avoid dual paths.

Update inventory/host_vars/restic1/host.yml to define local repository entries through add_restic_client_repositories, using local repository paths in repository, empty path, snapshot_enabled: false, and retention_enabled: true.

3. Server validation and tests
Expand playbooks/roles/test_restic_server so the existing HTTP/auth checks stay as the lightweight default, and add an optional deeper repository validation mode.

The deeper mode will:

use the server host’s local restic binary
talk to the published endpoint through http://127.0.0.1:<port>/...
target a dedicated test repository such as restic-server-test/repo1
verify repository access with restic snapshots
create a temporary test directory and file
run a small backup into the test repository
restore the latest snapshot into a temporary restore path
assert the restored file content matches
clean up temporary working directories
capture troubleshoot diagnostics from restic stdout/stderr on failure
Add a retention coverage assertion to the test role:

discover on-disk repositories under the server data root
compare them to configured add_restic_client_repositories entries where retention_enabled: true
fail the test play when an on-disk repository has no matching retention-managed config entry
Provisioning should keep warnings for partial states; the dedicated test play should enforce full coverage.

4. Docs and operator workflow
Add a focused guide under context/guides/ for “adding a client repo” that documents:

target host add_restic_client_repositories
target host vaulted add_restic_client_repository_secrets
rerunning the client play
initializing the repository
adding the matching server-side local retention entry on restic1
updating the rest-server auth user list
rerunning the server play
running the test play
Update and slim existing restic docs so responsibilities are clear:

restic-client-role.md: role/runtime behavior and schema
use-restic-server.md: operator usage and repo naming rules
remove duplicated retention-specific guidance from the old retention role doc
Rclone Phase
After the restic refactor lands, update playbooks/roles/add_rclone to install an interactive admin script named rclone-sync in the service user’s home.

Its menu will show:

service/timer enabled and active state
log path
timer interval
last run time and result
It will support:

activate timer
deactivate timer
run sync up using the configured service direction
run safe copy down from remote to local
run destructive sync down from remote to local, with an explicit warning and confirmation
adjust timer interval by writing a systemd timer override drop-in and reloading systemd
Keep the default provisioning stance recovery-first: timer remains disabled after install until an operator enables it.

Test Plan
Validate new inventory rendering for dockerhost2 and restic1.
Verify the generated restic JSON config matches the new schema and includes resolved secrets only in the runtime file, not in host vars.
Run playbooks/test-restic-server.yml in default mode to confirm service and HTTP auth behavior still pass.
Run playbooks/test-restic-server.yml in deep repository mode against the dedicated test repo and verify backup plus restore.
Manually verify restic-client interactive mode on a normal client host and on restic1.
Manually verify that empty-path repositories do not expose snapshot/restore actions.
Manually verify rclone-sync interactive status, safe copy-down, destructive sync-down confirmation, and timer interval override behavior.
Assumptions And Defaults
Linux automation scope is Ubuntu/Debian amd64; Windows is supported by the shared script and docs, not by an Ansible Windows role in this change.
restic-server-test/repo1 remains the dedicated integration-test repository.
Empty path is the supported way to model server-local retention-only repositories.
Snapshot scheduling and retention scheduling are host-level timers; repository-level flags only decide whether each repo participates in that run.
For rclone “down”, both safe recovery copy and destructive mirror will be offered, with the safe option presented first.
Deep repository validation stays in the dedicated test play, not in the deployment play.
