# WSL PowerShell Ansible Workflow

Use the repository dev container when possible. It contains the full Ansible
toolchain, so no `install.ps1 -InstallVenv` step and no repo-local `.venv` are
needed.

## Dev container (recommended)

Open the repo in the dev container, then run:

```bash
pwsh run.ps1 <playbook.yml>
```

The image provides `ansible-playbook`, `ansible-vault`, `ansible-lint`, the
required collections, PowerShell, `sshpass`, and `xorriso`.

Verify the toolchain with:

```bash
pwsh tests/verify-devcontainer.ps1
```

## Legacy WSL workflow

Only use this when you are not running inside the dev container:

1. Run `install.ps1 -InstallApt`
2. Run `install.ps1 -InstallVenv`
3. Activate `.venv`
4. Start `pwsh`
5. Run `./run.ps1 <playbook.yml>`

Why the legacy flow still exists:
- the repo can create a local `.venv` and `.collections`
- the shared Ansible SSH key lives at `~/.ssh/ansible`
- `run.ps1` bootstraps `ssh-agent` for the current PowerShell session when `SSH_AUTH_SOCK` is missing

Notes:
- `run.ps1 -Help` prints the usage summary
- `run.ps1` still prompts for the SSH key passphrase when the key is not yet loaded
- once loaded into `ssh-agent`, parallel SSH connections are much more reliable

## What `run.ps1` does for you

`run.ps1` is a convenience wrapper around `ansible-playbook`. Per `pwsh` session it adds:

- tab-completion on playbook names from `playbooks/`
- a single Ansible Vault prompt, cached in `$env:ANSIBLE_VAULT_PASSWORD` and fed to
  Ansible through `vault_pass.ps1`
- an `ssh-agent` bootstrap that loads `~/.ssh/ansible`, so the key passphrase is
  asked at most once
- `-Debug`, which forwards `-v` to `ansible-playbook`

The vault password and the SSH key passphrase stay in memory only: nothing is
written to disk, and nothing survives closing the shell. Run `pwsh run.ps1 -Help`
for the usage summary.
