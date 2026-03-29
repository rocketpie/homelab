# Deployment History

Managed hosts can keep an append-only deployment history at `/var/lib/homelab/deploy-history.yml`.

The per-user `host-status` admin scripts can use that file for quick on-host
status checks.

The history is written by the `record_deployment` role and answers:

- which playbook last touched this host
- which roles were part of that run
- which repository commit was deployed
- whether the controller worktree was dirty at deploy time
- which tracked playbook and role paths contributed to the run

Each entry is appended as a YAML document, so the file is a YAML stream rather than a single list.

Playbooks using deployment history include:

- `playbooks/add-vm.yml`
- `playbooks/add-autoupdate.yml`
- `playbooks/add-rest-server.yml`
- `playbooks/configure-netcontroller.yml`
