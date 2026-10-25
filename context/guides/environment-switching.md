# Environment Switching

`Set-Environment.ps1` is the technical solution to the Problem: 
"how do I enable agentic testing, while effectively preventing any key compromises?" 

To achieve this, it removes all key material from the repository and replaces it with test data.
This includes Ansible vaults, the vault key and SSH identities.

Any set of keys and vault files are an `environment` such as `Test`, `Prod`, or `Agent`.
Set-Environment syncronizes them from a separate environment store.

Run it on the container host (eg. wsl), not inside the dev container. 
It makes only those secrets available to the container that belong to the selected environment.

The host needs PowerShell 7 plus the usual OpenSSH client tools (`ssh-agent`, `ssh-add`, `ssh-keygen`) and `chmod`.

## Goals

- The vault and ssh key passwords are never written to persistent disk.
- The container never receives an inactive environment's vaults, keys, or password.
- ssh private keys stay in a host-side `ssh-agent`; the container only gets the agent socket.
- Vault files are encrypted at rest in both the environment store and the repository.
- Switching is reversible and does not silently lose the current vault changes.

## Host / container boundary

```text
WSL / container host                          Dev container
~/.homelab/environments/                      <not accessible>
/dev/shm/homelab/control/                     <not accessible>

../homelab/                         <bind>    /workspace
/dev/shm/homelab/homelab-active/    <bind>    ~/.homelab-active/
```

the host owns:
- `~/.homelab/environments/` the environment store
- `~/.homelab/environments/<name>/repo/` environment encrypted vault files mirroring repository paths.
- `~/.homelab/environments/<name>/ssh/` environment SSH identities.
- `/dev/shm/homelab/` tmpfs runtime directory
- `/dev/shm/homelab/control/` host-only tmpfs data. 
- `/dev/shm/homelab/homelab-active/` container-shared tmpfs data (bind source).
  Note: read-only mounting would break `active.sock`: connecting to a Unix socket requires write permission.

The container only sees:
- `/workspace` the repository, containing the active environment's encrypted `vault.yml` files.
- `~/.homelab-active/`, containing `vault_pass`, `active.sock`, and `homelab-environment.json`

Because the environment store and the `control/` directory are **not** mounted
into the container, inactive environments and host control data remain inaccessible.

### Runtime root bootstrap

The host tmpfs runtime root is prepared by
[`.devcontainer/Initialize-HomelabRuntime.ps1`](../../.devcontainer/Initialize-HomelabRuntime.ps1),
which is wired as the dev container's `initializeCommand`. It runs on the host
before the container starts and guarantees that the runtime directory is set up correctly.

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

Populate the encrypted vaults or copy an existing encrypted set into
`~/.homelab/environments/Prod/repo/...`.

Then run the switch again:

```bash
pwsh Set-Environment.ps1 -Environment Prod
```

## What a switch does

If the target environment does not exist, the script creates its directories,
prints the key and vault setup steps, and exits before changing the active
environment.

1. Validate: that all repository `vault.yml` files are encrypted.
2. Save old: synchronizes the current repository vaults into the leaving environment's `repo/` mirror.
3. Load new: synchronizes the target environments stored `vault.yml` files into the repository.
4. Writes the target environment's vault password to `vault_pass`.
5. Stops the old host `ssh-agent` and starts a new one with the target environment's key. 
6. Writes the new state to 
   `control/active-environment.json` and 
   `homelab-active/homelab-environment.json`.
7. Rolls back the repository vaults, active password, host state, and newly
   started agent if a step fails.

Saving mirrors the repository: it copies all repository vaults into the store and removes all store vaults that no longer exist in the repository, so deleting a `vault.yml` is persisted.

## Deactivating

`pwsh Set-Environment.ps1 -Deactivate` saves the active repository vaults into
the environment store, deletes all active `vault.yml` files from the repository,
stops the host `ssh-agent`, and removes all files from the runtime directory.
The container is left without any active vault files, password, or agent socket.
The encrypted copies stay in the environment store, so `Set-Environment.ps1 <name>` switches them back.

If saving fails, the repository vaults are rolled back and deactivation aborts.

If repository vault files exist but no active runtime is present, deactivate refuses to remove them.
Use `-Force` to clear the runtime and remove the unmanaged vault files.

## `run.ps1` uses the active environment

`run.ps1` reads the published `homelab-environment.json` from
`~/.homelab-active/` when it exists and:

- sets `SSH_AUTH_SOCK` to `~/.homelab-active/active.sock`;
- verifies that the host agent has a loaded key;
- uses `~/.homelab-active/vault_pass` as the Ansible Vault password file;
- overrides the inventory's key path so Ansible uses the agent rather than a key file;
- passes the active environment's public key as `ansible_admin_ssh_public_key`.

## Creating and updating vaults

`Initialize-VaultTemplates.ps1` now encrypts new files directly using the
active vault password. It does not write a plaintext `vault.yml` first:

```bash
pwsh srv/Initialize-VaultTemplates.ps1
```

The `add_ansible_execution_prefill_vault_templates` role option is disabled by
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
- `<runtime>/homelab-active/` is mounted read-write so the container can
  connect to `active.sock`. The container can also rewrite `vault_pass` and the
  published `homelab-environment.json`; the host MUST NOT trust this copy,
  so this only affects commands run inside the container.
- `/dev/shm` is tmpfs, but swap can still page it unless swap is disabled or
  encrypted.
- The runtime root and files are owned by the WSL host user. The dev
  container runs as `vscode` (uid 1000) by default. If your WSL uid differs, the
  container cannot read the tmpfs password or connect to the agent socket; align
  the uid or adjust the container user.
- Running `Set-Environment.ps1` inside the dev container is rejected. The
  script requires the host's `~/.homelab` store and host `ssh-agent`.

## Troubleshooting

- **"must run on the container host"** — The entire purpose is to keep the secrets out of the container.
  Can't do that if you have access to the secret store inside it. Run the command from the host.
- **"Runtime root ... is not tmpfs"** — `/dev/shm` is not mounted as tmpfs.
  Fix the host mount rather than using `-Force` unless you accept the risk.
- **"repository ... vault.yml file(s) but no active runtime environment"** — the
  host rebooted or the tmpfs runtime was cleared. The script will not guess
  which environment owned the repository vaults. Re-run a switch with `-Force`
  to override, or with `-NoSave` to discard the repository vaults. 
  Alternatively, move the vault files into their environment store first.
- **"SSH agent socket not found"** — the active environment is stale, or the
  container was started without the `~/.homelab-active` mount. Run
  `Set-Environment.ps1 -Environment <name>` on the host and restart the
  container if the mount changed.
- **"vault password file not found"** — the active environment has vaults but
  no published password. Re-run `Set-Environment.ps1` and enter the password.
- **"Refusing plaintext vault file"** — encrypt the file with `ansible-vault`
  before switching.
