# Deployment History

Managed hosts can keep an append-only deployment history at `/var/lib/homelab/deploy-history.yml`.

The per-user `host-status` admin scripts can use that file for quick on-host
status checks.

`host-status` shows the first recorded deployment entry plus a recent summary of
later entries, so the initial `add-vm` provisioning record stays visible even
after many later deployments. It also prints a `cat` command for the full file.

The history is written by the `record_deployment` role in two phases:

- at the start of a host-affecting play, it appends an entry with `status: incomplete`
- if the play finishes successfully, it updates that same entry to `status: success`

This means interrupted or failed runs remain visible on the host.

Each entry answers:

- which playbook last touched this host
- whether that run finished successfully
- which roles were part of that run
- which repository commit was deployed
- whether the controller worktree was dirty at deploy time

Keep the recorded roles focused on work that actually affects the managed host.
For example, `add-vm.yml` should only log guest-side roles such as
`configure_disks` or `add_autoupdate`, not controller-only preparation roles.

Each entry is stored as a YAML document, so the file is a YAML stream rather
than a single list.

Playbooks using deployment history include:

- `playbooks/add-vm.yml`
- `playbooks/add-autoupdate.yml`
- `playbooks/add-rest-server.yml`
- `playbooks/configure-netcontroller.yml`
