# Naming Conventions

This repository follows a PowerShell-inspired verb-noun naming style.

## Playbooks

- Playbooks use kebab-case verb-noun names.
- Preferred verbs are action-oriented and operational, such as `add`, `configure`, `remove`, and `test`.
- Keep the noun specific to the thing being managed.

Examples:

- `playbooks/add-vm.yml`
- `playbooks/configure-netcontroller.yml`
- `playbooks/remove-vm.yml`
- `playbooks/add-proxmox-api-user-ansible.yml`
- `playbooks/test-unbound-from-controller.yml`

## Roles

- Roles use snake_case verb_noun names.
- This keeps them aligned with Ansible role naming conventions and `ansible-lint`.
- Role names should describe the responsibility of the role, not the implementation detail.

Examples:

- `playbooks/roles/add_unbound`
- `playbooks/roles/add_kea`
- `playbooks/roles/add_proxmox_vm`
- `playbooks/roles/test_proxmox_api`
- `playbooks/roles/configure_disks`
- `playbooks/roles/export_autoinstall_seed`

## Role-local Variables

- Variables defined inside a role should be prefixed with the full role name.
- Apply this to defaults, `set_fact`, and `register` names.
- This avoids cross-role collisions and keeps lint happy.

Examples:

- `add_unbound_service_name`
- `add_unbound_effective_dns_records`
- `add_proxmox_vm_active_node`
- `configure_disks_mounts`
- `export_autoinstall_seed_vm_users`

## Vault Variables

Keep all secrets in a `vault.yml`.
Add a template comment at the bottom of the relevant `host.yml` / `users.yml` or `any-other-yml`:

eg. restic1/host.yml:
```yaml
...
# vault.yml:
# add_restic_server_htpasswd_entries:
#   - user: "archivar"
#     password: "REST_SERVER_PASSWORD_HERE"
```

## General Notes

- Keep file and directory paths relative to the repository root or the current file.
- Prefer consistent verb choice across related playbooks and roles.
