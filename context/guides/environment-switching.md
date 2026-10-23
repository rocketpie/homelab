# Environment Switching

`Set-Environment.ps1` switches Ansible vaults and SSH identities between environments such as `Test`, `Prod`, or `Agent` from a separate environment store.

Run it on the container host (eg. wsl), not inside the dev container. 
It makes only those secrets available to the container that 
belong to the selected environment.

The host needs PowerShell 7 plus the usual OpenSSH client tools (`ssh-agent`,
`ssh-add`, `ssh-keygen`) and `chmod`.

## Goals

- The vault and ssh key passwords are **never** written to persistent disk.
- The container never receives an inactive environment's vaults, keys, or password.
- ssh private keys stay in a host-side `ssh-agent`; the container only gets the agent socket.
- Vault files are encrypted at rest in both the environment store and the repository.
- Switching is reversible and does not silently lose the current vault changes.

## Host / container boundary

```text
WSL / container host                              Dev container
~/.homelab/environments/<name>/                   /workspace
  repo/... encrypted vault.yml files       <bind>   repo/... active vault.yml files
  ssh/ansible[.pub]                                 .homelab-environment.json
                                                    ~/.homelab-active/
/dev/shm/homelab-active/                  <bind>     vault_pass
  vault_pass          active password only          active.sock
  active.sock         active host ssh-agent

host ssh-agent
  only the active environment's key
```

The host owns:

- `~/.homelab/environments/<name>/repo/` — encrypted vaults mirroring repository
  paths.
- `~/.homelab/environments/<name>/ssh/ansible` and `ansible.pub` — the
  environment SSH identity.
- `/dev/shm/homelab-active/` — the tmpfs runtime directory. It contains only the
  active vault password and the active agent socket.

The container only sees:

- the repository, containing the active environment's encrypted `vault.yml`
  files;
- `~/.homelab-active/`, mounted from the host tmpfs directory;
- `.homelab-environment.json`, which records the active environment and
  generation.

Because the environment store itself is **not** mounted into the container, inactive environments remain fully inaccessible.

### Runtime directory bootstrap

The host tmpfs runtime directory is prepared by
[`.devcontainer/Initialize-HomelabRuntime.ps1`](../../.devcontainer/Initialize-HomelabRuntime.ps1),
which is wired as the dev container's `initializeCommand`. It runs on the host
before the container starts and guarantees that the bind-mount source exists,
is tmpfs rather than persistent disk, has `0700` permissions, and is supported
by the host. It fails closed on non-Linux or non-tmpfs hosts.

The script does not create the vault password or start the SSH agent. It only
prepares the directory that `Set-Environment.ps1` writes to. Because the
directory is tmpfs, a host reboot clears it; the script recreates the empty
directory at the next container start, and `Set-Environment.ps1` must be re-run
to republish the active password and agent.

## Environment Store layout

```text
~/.homelab/environments/Prod/
  repo/
    inventory/group_vars/all/vault.yml
    inventory/group_vars/proxmox/vault.yml
    inventory/host_vars/dockerhost2/vault.yml
    ...
  ssh/
    ansible
    ansible.pub
~/.homelab/environments/Test/
  ...
```

The `repo/` subtree mirrors the repository layout. A file at
`inventory/host_vars/dockerhost2/vault.yml` in the repository lives at
`~/.homelab/environments/Prod/repo/inventory/host_vars/dockerhost2/vault.yml`.

## First-time setup

Create the environment by invoking the switch for it:

```bash
pwsh Set-Environment.ps1 -Environment Prod
```

If the environment does not exist, the script creates its directories, reports
the next steps, and exits. Generate the environment key. The key must be the
identity authorized on that environment's hosts:

```bash
ssh-keygen -t ed25519 -f ~/.homelab/environments/Prod/ssh/ansible -C ansible
```

Populate the encrypted vaults. Either copy an existing encrypted set into
`~/.homelab/environments/Prod/repo/...`, or use the import behaviour below.

Then run the switch again:

```bash
pwsh Set-Environment.ps1 -Environment Prod
```

On the first switch, if the repository already has local `vault.yml` files and
the target environment has none, `Set-Environment.ps1` imports them into the
target environment after prompting for their vault password. If the target
environment already has vaults and the repository also has unmanaged vaults,
the switch refuses to overwrite them unless you pass `-Force` or `-NoSave`.


## What a switch does

If the target environment does not exist, the script creates its directories,
prints the key and vault setup steps, and exits before changing the active
environment.

1. Validates that every managed `vault.yml` is encrypted.
2. Saves the current repository vaults into the active environment's
   `repo/` mirror.
3. Deletes the active repository `vault.yml` files and copies the target
   environment's files into the repository.
4. Writes the target environment's vault password to the active runtime
   directory's `vault_pass`.
5. Stops the old host `ssh-agent` and starts a new one with only the target
   environment's key.
6. Writes `.homelab-environment.json` with a new generation.
7. Rolls back the repository vaults and active password if a step fails.

Saving is additive: it copies the repository's current vaults into the
environment store but does not delete environment files that are no longer in
the repository. To remove a vault from an environment, remove it from the
environment store explicitly.

## How `run.ps1` uses the active environment

`run.ps1` reads `.homelab-environment.json` when it exists and:

- sets `SSH_AUTH_SOCK` to `~/.homelab-active/active.sock`;
- verifies that the host agent has a loaded key;
- uses `~/.homelab-active/vault_pass` as the Ansible Vault password file;
- overrides the inventory's key path so Ansible uses the agent rather than a
  key file;
- passes the active environment's public key as
  `ansible_admin_ssh_public_key`.

Without `.homelab-environment.json`, `run.ps1` falls back to the previous
behaviour: prompt for the vault password and load `~/.ssh/ansible` into a
container-local agent.

## Creating and updating vaults

`Initialize-VaultTemplates.ps1` now encrypts new files directly using the
active vault password. It does not write a plaintext `vault.yml` first:

```bash
pwsh srv/Initialize-VaultTemplates.ps1
```

The same applies to `install.ps1 -InstallVault`. The
`add_ansible_execution_prefill_vault_templates` role option is disabled by
default because it needs an active vault password on the target; enable it only
when that environment has already published an active password.

`Set-Environment.ps1` refuses to copy a plaintext `vault.yml`. Encrypt it first
with the active environment's password:

```bash
ansible-vault encrypt path/to/vault.yml --vault-password-file vault_pass.ps1
```

Be aware that `ansible-vault edit` uses a local temporary file for the editor.
If plaintext must never touch disk, point `TMPDIR` at a tmpfs directory or use a
workflow that keeps the editor buffer in memory.

## Security notes

- The container can use the active SSH key through the agent, but cannot read the
  private key and cannot reach an inactive environment's agent.
- The active vault password is readable by the container because Ansible needs
  it. Inactive passwords are never present.
- `/dev/shm` is tmpfs, but swap can still page it unless swap is disabled or
  encrypted. For a hard guarantee, use a hardware-backed key source and keep the
  password prompt in the container instead.
- Do not switch environments while a playbook is running. The switch replaces
  the active vault files and agent.
- The default runtime path is `/dev/shm/homelab-active`; override it with
  `HOMELAB_RUNTIME_DIR` if needed. The dev container mounts the host runtime
  directory at `~/.homelab-active`. If Docker Desktop cannot see a WSL
  `/dev/shm` path, adjust both the host runtime path and the dev container mount
  together.
- The runtime directory and files are owned by the WSL host user. The dev
  container runs as `vscode` (uid 1000) by default. If your WSL uid differs, the
  container cannot read the tmpfs password or connect to the agent socket; align
  the uid or adjust the container user.
- Running `Set-Environment.ps1` inside the dev container is rejected. The
  script requires the host's `~/.homelab` store and host `ssh-agent`.

## Troubleshooting

- **"must run on the container host"** — The entire purpose is to keep the secrets out of the container. can't do that if you have access to the secret store inside it. Run the command from the host.
- **"Runtime directory is not tmpfs"** — `/dev/shm` is not mounted as tmpfs.
  Fix the host mount rather than using `-Force` unless you accept the risk.
- **"SSH agent socket not found"** — the active environment is stale, or the
  container was started without the `~/.homelab-active` mount. Run
  `Set-Environment.ps1 -Environment <name>` on the host and restart the
  container if the mount changed.
- **"vault password file not found"** — the active environment has vaults but
  no published password. Re-run `Set-Environment.ps1` and enter the password.
- **"Refusing plaintext vault file"** — encrypt the file with `ansible-vault`
  before switching.
