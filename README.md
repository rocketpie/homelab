# homelab
automating my homelab setup with ansible

## Install

### Option A: dev container (recommended)

Open the repository in the dev container. The image already contains:

- PowerShell 7
- Python and Ansible tooling in `/opt/ansible/venv`
- all collections from `collection-requirements.txt`
- `ansible-lint`, `sshpass`, and `xorriso`

There is no post-create install step; `postCreateCommand` only verifies the
image and the repository wiring:

```bash
pwsh tests/verify-devcontainer.ps1
```

If `venv-requirements.txt` or `collection-requirements.txt` changes, rebuild
the dev container so the image picks up the new toolchain.

Run playbooks directly:

```bash
pwsh run.ps1 <playbook>
```

### Option B: legacy WSL setup

The old `install.ps1` flow is only needed outside the dev container:

```powershell
install.ps1 -InstallApt
install.ps1 -InstallVenv
install.ps1 -InstallVault
```

Then activate `.venv` before running playbooks:

```bash
. .venv/bin/activate
pwsh run.ps1 <playbook>
```

## Run playbooks

```bash
pwsh run.ps1 <playbook>
pwsh run.ps1 -Help
```

`run.ps1` only locates the playbook, handles the vault password, and starts the
SSH agent. It no longer creates a virtual environment.

For the current `pwsh` session it also adds tab-completion for playbook names,
keeps the vault password in `$env:ANSIBLE_VAULT_PASSWORD`, loads `~/.ssh/ansible`
into `ssh-agent`, and forwards `-v` when you pass `-Debug`. Both secrets live in
memory only.

## Verification

PowerShell is kept for readable verification checks:

```bash
pwsh tests/verify-devcontainer.ps1
pwsh tests/verify-public-gateway-config.ps1
pwsh tests/verify-vault-template-render.ps1
```

`verify-public-gateway-config.ps1` intentionally fails while the example domains are
still present or the host is missing from the `vpn_gateway`/`website` inventory
groups.

`build.ps1` remains the lint and vault-template sync entrypoint:

```bash
pwsh build.ps1
```
