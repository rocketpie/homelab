# Ansible Execution VM

`admin1` is the dedicated Ubuntu VM for running this repo inside the homelab.

## Purpose

Use it when you want a Linux control node inside the lab that can:

- run the repo's `pwsh`-based workflow directly
- provision VMs with `playbooks/add-vm.yml`
- carry the local repo state, including local `vault.yml` files, onto the VM

## Provisioning Flow

1. Provision the VM itself with `playbooks/add-vm.yml` and `vm_name=admin1`
2. Configure the execution environment with `playbooks/add-ansible-execution.yml`

The `add_ansible_execution` role:

- installs the repo runtime dependencies on Ubuntu
- installs `pwsh`, `uv`, and `caddy`
- clones the Git remote into the `ansible` user's home directory
- synchronizes the local working tree onto the VM so local vault files come along
- copies the shared Ansible SSH key into `~/.ssh/ansible`
- installs helper commands in the `ansible` user's home directory

## Autoinstall Seed Hosting

The repo's autoinstall settings now honor these optional environment variables:

- `HOMELAB_AUTOINSTALL_HOST`
- `HOMELAB_AUTOINSTALL_PROBE_URL`
- `HOMELAB_AUTOINSTALL_HTTP_SERVER_BIN`
- `HOMELAB_AUTOINSTALL_HTTP_SERVER_WORKDIR`

On `admin1`, the role exports those values for both login shells and
PowerShell sessions so `playbooks/add-vm.yml` serves `srv/http_root/ubuntu2404`
through local `caddy` on port `8080`.

`add_ansible_execution_autoinstall_host` should normally point to the address
new VMs can reach during Ubuntu autoinstall. The current `admin1` host vars
use the VM's `ansible_host` for that reason.
