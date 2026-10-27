# Ansible Execution VM

`admin1` is the dedicated Ubuntu VM for running this repo inside the homelab.

## Purpose

Use it when you want a Linux control node inside the lab that can:

- run the repo's `pwsh`-based workflow through the dev container
- provision VMs with `playbooks/add-vm.yml`
- keep a normal Git clone of this repo on a homelab host

## Provisioning Flow

1. Provision the VM itself with `playbooks/add-vm.yml` and `vm_name=admin1`
2. Configure the execution environment with `playbooks/add-ansible-execution.yml`

The `add_ansible_execution` role:

- installs `pwsh`, Docker, and the devcontainer CLI on Ubuntu
- clones the Git remote into the `ansible` user's home directory
- installs helper commands that run the repo inside the dev container
- does **not** copy SSH keys or create missing local `vault.yml` files

The first `homelab-run` builds the dev container image locally, which can take a
few minutes.

## Environment Store and Trust Model

The execution VM does not receive an ad-hoc SSH key. Instead, copy the active
environment store from the container host:

```bash
# on the container host
scp -r ~/.homelab/environments/<name> ansible@admin1.lan:~/.homelab/environments/
```

Then activate it on the VM:

```bash
ssh ansible@admin1.lan
pwsh ~/homelab/Set-Environment.ps1 -Environment <name>
```

`Set-Environment.ps1` publishes the vault password, SSH agent socket, and
Ansible public key exactly as it does on the container host. The copied store
contains the environment's SSH private key, so **treat `admin1` as a trusted
execution host**. A compromise of `admin1` is equivalent to a compromise of the
environment key (at least while it's decrypted).

Log out and back in once after the role adds the user to the `docker` group, or
`docker` will only work with `sudo`.

## Helper Commands

The role installs these in the repo owner's home directory:

- `homelab-run` — `devcontainer up` then `devcontainer exec ... pwsh ./run.ps1`
- `homelab-lint` — the same wrapper around `./build.ps1`
- `homelab-init-vaults` — the same wrapper around
  `./srv/Initialize-VaultTemplates.ps1 -RepoRoot .`
- `homelab-autoinstall-seed` — runs the host launcher script when it exists

## Autoinstall Seed Hosting

The shared seed URL is `http://autoinstall-seed.lan:8080/ubuntu2404`.

Point `autoinstall-seed.lan` at whichever host should currently serve
`srv/http_root`, then run that host's repo-local launcher script.

For `admin1`, the expected launcher is:

- `srv/Start-AutoInstallServer-admin1.sh`

The role also installs a helper wrapper so the admin user can run
`homelab-autoinstall-seed` when that launcher script exists.
