# PowerShell Ansible Workflow

## Dev container

The repository dev container is the only supported Ansible runtime.
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

## Environment switching

Vaults and the Ansible SSH key can be switched between environments such as
`Test`, `Prod`, and `Agent` from the container host. The host owns the
environment store and the active tmpfs secrets; the dev container sees only the
active environment.

`run.ps1` requires an active environment:

```bash
pwsh Set-Environment.ps1 -Environment <name>
```

See [`environment-switching.md`](environment-switching.md) for the first-time
setup, the active key source, and the host/container boundary.

## What `run.ps1` does for you

`run.ps1` is a convenience wrapper around `ansible-playbook`. Per `pwsh` session it adds:

- tab-completion on playbook names from `playbooks/`
- the active environment's `SSH_AUTH_SOCK` and vault password file
- the active environment's public key as `ansible_admin_ssh_public_key`
- empty `ansible_admin_ssh_private_key_file` and `ansible_ssh_private_key_file`
  overrides, so the agent is used even if a stale inventory value remains
- `-Debug`, which forwards `-v` to `ansible-playbook`

Without an active environment, `run.ps1` fails with instructions instead of
prompting for a vault password or loading a key. The environment store is
host-only; see [`environment-switching.md`](environment-switching.md).
