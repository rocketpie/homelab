# Ansible Execution VM

`admin1` is the dedicated Ubuntu VM for running this repo inside the homelab.

## Purpose

Use it when you want a Linux control node inside the lab that can:

- run the repo's `pwsh`-based workflow directly
- provision VMs with `playbooks/add-vm.yml`
- keep a normal Git clone of this repo on a homelab host

## Provisioning Flow

1. Provision the VM itself with `playbooks/add-vm.yml` and `vm_name=admin1`
2. Configure the execution environment with `playbooks/add-ansible-execution.yml`

The `add_ansible_execution` role:

- installs the repo runtime dependencies on Ubuntu
- installs `pwsh`, `uv`, and the repo's Ansible prerequisites
- clones the Git remote into the `ansible` user's home directory
- optionally copies the shared Ansible SSH key into `~/.ssh/ansible`
- creates missing local `vault.yml` files from the checked-in `# vault.yml:` template comments
- installs helper commands in the `ansible` user's home directory

## Autoinstall Seed Hosting

The shared seed URL is `http://autoinstall-seed.lan:8080/ubuntu2404`.

Point `autoinstall-seed.lan` at whichever host should currently serve
`srv/http_root`, then run that host's repo-local launcher script.

For `admin1`, the expected launcher is:

- `srv/Start-AutoInstallServer-admin1.sh`

The role also installs a helper wrapper so the admin user can run
`homelab-autoinstall-seed` when that launcher script exists.
