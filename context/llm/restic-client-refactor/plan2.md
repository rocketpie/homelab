Plan

Restic Client Unification With Explicit Capabilities
Summary
Refactor the backup stack around one shared app in apps/restic-client/, one generated JSON config, and one Linux-installed restic-client.ps1 runtime. Replace implicit behavior with explicit per-repository capability flags: snapshot_allowed, restore_allowed, and forget_allowed.

Keep scheduling on systemd timers, but document the schedule string clearly in context/guides/restic-client-role.md with practical examples and a short “why not cron” note. The current upstream latest restic release is 0.18.1 as of 2026-04-22, but the role should default to a latest mode that resolves the newest upstream release at install time.

Key Changes
Schema and role wiring
Use one preferred inventory shape under add_restic_client_repositories with no generic enabled flag:

add_restic_client_repositories:
  - name: "paperless"
    repository: "rest:http://{rest_username}:{rest_password}@backup.lan:8000/{rest_username}/paperless"
    path: "/media/paperless-data/export"
    snapshot_allowed: true
    restore_allowed: true
    forget_allowed: false
    backup_pre_command: "/usr/local/bin/paperless-export-backup"
    backup_options:
      - "--skip-if-unchanged"
    forget_args: []
Use one vaulted secret map keyed by repo name:

add_restic_client_repository_secrets:
  paperless:
    rest_username: "..."
    rest_password: "..."
    repository_password: "..."
Behavior rules:

path no longer disables anything implicitly.
snapshot_allowed controls inclusion in snapshot runs and snapshot UI actions.
restore_allowed controls restore UI/actions.
forget_allowed controls inclusion in retention/forget runs and UI/actions.
backup_options and backup_pre_command are snapshot-only settings.
forget_args are forget-only settings.
Create apps/restic-client/ for the shared script, schema, and example config. Remove the common runtime from context/.

Linux install and playbooks
Create a reusable add_powershell role by extracting and adapting the current playbooks/add-pwsh-ubuntu.yml logic. Keep add-pwsh-ubuntu.yml as a thin wrapper playbook that calls the new role, so the manual workflow still exists.

Update add_restic_client to:

install pwsh via add_powershell
install restic from the official upstream archive, resolving latest by default
render one JSON config for the runtime
install one admin script link: restic-client
install restic-client.ps1 -RunSnapshot service/timer only if any repo has snapshot_allowed: true
install restic-client.ps1 -RunRetention service/timer only if any repo has forget_allowed: true
expose admin service groups only for the timers that actually exist
Refactor playbooks/add-rest-server.yml so server-local retention uses add_restic_client directly. Delete add_restic_retention entirely.

For restic1, model local server-side repositories as normal add_restic_client_repositories entries with local repository paths, snapshot_allowed: false, restore_allowed: false, and forget_allowed: true.

Runtime and integrity checks
The shared PowerShell runtime should support:

no args: interactive mode
-RunSnapshot
-RunRetention
-ShowStatus
Interactive mode should show:

configured repos
snapshot/retention timer state if present
log path
per-repo snapshot count and latest snapshot age with a short timeout
only the actions allowed by each repo’s flags
Add repository-integrity checks centered on repo consistency, not just upstream tool behavior. These checks should warn when:

snapshot_allowed or restore_allowed is true but path is empty
forget_allowed is true but forget_args is empty
snapshot-only settings exist but snapshot_allowed is false
forget_args exist but forget_allowed is false
a client-side REST username has no matching add_restic_server_htpasswd_entries user
a server-side access user has no repos
a repo has no matching access user
an on-disk server repo has no matching forget-managed config entry
a VM-side repo appears to have no server-side forget config counterpart
Runtime failures should still fail when the script or generated config is broken; consistency mismatches should warn.

Tests and Operator Workflow
Keep host/runtime checks in playbooks/test-restic-server.yml, but shift emphasis toward validating the custom restic-client setup and repo consistency.

The test play should:

validate generated repo config sanity on the target
validate that allowed actions have the required companion settings
warn on inventory inconsistencies listed above
optionally run a deeper smoke test of the installed restic-client.ps1 against a dedicated test repo, but only as a secondary mode
Put any manual test entrypoints under scripts/test/. These should be user-run only; I will not execute them. Add scripts there for:

inventory consistency validation
generated config/schema validation
optional remote smoke-test invocation guidance
Fold the “adding a client repo” workflow into context/guides/restic-client-role.md as a dedicated section instead of a separate guide.

Assumptions and Defaults
Scheduling stays on systemd timers, not cron.
The documented variable should be named clearly, for example snapshot_schedule_on_calendar / retention_schedule_on_calendar, and the guide should show examples like daily, Mon..Fri 02:00, and hourly-style patterns.
-RunRetention remains the action name for continuity, even though the explicit repo flag is forget_allowed.
apps/restic-client/ is new and will be created as part of the implementation.
add_restic_retention is removed in the same change, not deprecated.
User-executed tests live only under scripts/test/, and their output can then be reviewed together.
