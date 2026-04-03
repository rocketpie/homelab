# renaming:
    'kea' inventory role -> 'dhcp'
    'unbound' inventory rule -> 'dns-resolver'
    'configure_disks' role -> 'set_vm_disks'

# rest-server-role.md TODO
- add a second-stage smoke test that uses the `restic` CLI to create a
  disposable repository, write one backup, list snapshots, and restore it
  again once this repo has a proper way to install `restic` for tests


# duplicate documentation 
- restic-retention-role.md
    -> focus on role function details
- use-restic-server.md / Server-side retention config
    -> focus on extending the config, like adding a new repo or changing retention

# restic client log
    - process runtime output live streaming to the console
    - DEBUG_LOG=restic-debug.log

# restic server play
    - add extensive testing, including restic repository access / restore and backup
    since this is frequently re-run when adding htaccess users.
    maybe handle user changes differently?

# docker hostname binding
    - to the docker role, add a haproxy reverse proxy
    - bind to dns_aliases, forward to container ports (set where?) 

# adding restic client repo
    - restic1/host.yml/add_restic_retention_repositories
    - restic1/vault.yml/add_restic_server_htpasswd_entries
    - repo init 
```bash
set -a
source /etc/restic-client/repos.d/paperless.env
restic init
```



# lint
Running ansible-lint...
WARNING  Listing 13 violation(s) that are fatal
yaml[line-length]: Line too long (168 > 160 characters)
playbooks/roles/add_docker/tasks/main.yml:62

risky-file-permissions: File permissions unset or incorrect.
playbooks/roles/add_restic_server/tasks/main.yml:249 Task/Handler: Remove stale rest-server htpasswd users

risky-file-permissions: File permissions unset or incorrect.
playbooks/roles/add_restic_server/tasks/main.yml:263 Task/Handler: Install rest-server htpasswd users

yaml[trailing-spaces]: Trailing spaces
playbooks/roles/export_autoinstall_seed/tasks/main.yml:99

jinja[spacing]: Jinja2 spacing could be improved: {%- if vm.proxmox_replication_rate is defined -%} {{ vm.proxmox_replication_rate | string | trim }} {%- else -%} {{ none }} {%- endif -%} -> {%- if vm.proxmox_replication_rate is defined -%} {{ vm.proxmox_replication_rate | string | trim }}{%- else -%} {{ none }}{%- endif -%} (warning)
playbooks/roles/set_proxmox_vm_hardware/tasks/main.yml:21 Jinja2 template rewrite recommendation: `{%- if vm.proxmox_replication_rate is defined -%} {{ vm.proxmox_replication_rate | string | trim }}{%- else -%} {{ none }}{%- endif -%}`.

yaml[line-length]: Line too long (170 > 160 characters)
playbooks/roles/set_proxmox_vm_hardware/tasks/main.yml:51

no-changed-when: Commands should not change things if nothing needs doing.
playbooks/roles/set_vm_network/tasks/main.yml:39 Task/Handler: Apply generated netplan config

no-handler: Tasks that run when changed should likely be handlers.
playbooks/roles/set_vm_network/tasks/main.yml:42:13 Task/Handler: Apply generated netplan config

risky-shell-pipe: Shells that use pipes should set the pipefail option.
playbooks/roles/test_restic_server/tasks/main.yml:34 Task/Handler: Check whether rest-server port is listening

name[casing]: All names should start with an uppercase letter.
playbooks/roles/test_restic_server/tasks/main.yml:117:13 Task/Handler: troubleshoot capture rest-server service status

name[casing]: All names should start with an uppercase letter.
playbooks/roles/test_restic_server/tasks/main.yml:129:13 Task/Handler: troubleshoot capture recent rest-server journal entries

name[casing]: All names should start with an uppercase letter.
playbooks/roles/test_restic_server/tasks/main.yml:142:13 Task/Handler: troubleshoot capture listening TCP sockets for rest-server port

risky-shell-pipe: Shells that use pipes should set the pipefail option.
playbooks/roles/test_restic_server/tasks/main.yml:142 Task/Handler: troubleshoot capture listening TCP sockets for rest-server port

