# homelab

this is my homelab automation project.

It builds on physical servers running Proxmox, 
Automating VM provisioning and configuration with Ansible.
Backup is relying on restic, with an rsync mirrored cloud storage.

It serves two goals: 
- document what i have set up and how
- making it reproduceable in case of hardware or catastrophic failure.

## Setup

### Host

The host is where the repository and the environment store lives. It needs:
- git to clone the repository,
- docker (and devcontainers/cli, or VSCode + Dev Containers) to run the dev container
- pwsh to use `Set-Environment.ps1` for interacting with the environment store.

### dev container

The dev container is the Ansible (and Agent) runtime. 
The image contains:

- PowerShell 7
- Python and Ansible tooling in `/opt/ansible/venv`
- all collections from `.devcontainer/collection-requirements.txt`
- `ansible-lint`, `sshpass`, and `xorriso`

There is no post-create install step; `postCreateCommand` only verifies the
image and the repository wiring:

```bash
pwsh tests/verify-devcontainer.ps1
```

## Run playbooks

Before running a playbook, activate an environment on the container host.
The active environment is the only source of the vault password, 
the SSH agent socket, and the Ansible public key:

```powershell
pwsh Set-Environment.ps1 -Environment <name>
```

Then, inside the dev container:

```bash
pwsh run.ps1 <playbook> [-Debug]
pwsh run.ps1 -Help
```

`run.ps1` tab-completes the playbook name and injects the active environment's vault
password, SSH agent socket, and public key. 
Without an active environment it fails with instructions to use Set-Environment.

See [`context/guides/environment-switching.md`](context/guides/environment-switching.md)
for the host/container secret boundary and the `Set-Environment.ps1` workflow.

## Verification

PowerShell is kept for readable verification checks:

```bash
pwsh tests/verify-devcontainer.ps1
pwsh tests/verify-public-gateway-config.ps1
pwsh tests/verify-vault-template-render.ps1
```

`build.ps1` remains the lint and vault-template sync entrypoint:

```bash
pwsh build.ps1
```

It requires an active environment when the repository contains encrypted
`vault.yml` files, because it decrypts them to sync the checked-in template comments.
