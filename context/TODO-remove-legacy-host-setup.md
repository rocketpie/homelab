# TODO: Remove the legacy host setup route

Status: **implemented**

Implementation notes:

- Service-account public keys stay as literal `host_vars/*/host.yml` values.
  Only the Ansible identity is sourced from the active environment.
- `run.ps1` passes the public key as JSON extra-vars. A bare
  `key=ssh-ed25519 AAAA...` value is split by Ansible's extra-vars parser.
- `admin1` installs Node 22 from NodeSource because Ubuntu 24.04's Node 18 is
  too old for the current `@devcontainers/cli`.
- `build.ps1` now requires an active environment only when it has to decrypt a
  checked-in `vault.yml` for template-comment sync.

Source TODOs:

```markdown
# Dev Container
- devcontainer verified. Remove the legacy WSL setup route, wsl, python, ansible etc. setup and interactive key handling from all init / run etc. scripts.
- move venv-requirements.txt collection-requirements.txt to .devcontainer?
- migrate from legacy inventory hard-coded ansible key / public string

# add ansible execution vm
- rethink the role around the dev container and the environment store
- do *not* create missing local `vault.yml` files
- remove `add_ansible_execution_copy_ssh_key` and the `~/.ssh/ansible` copy tasks
```

Goal: the dev container is the only supported way to run the Ansible
toolchain. No WSL/host install route, no repo-local `.venv` or `.collections`,
no interactive SSH key handling in the run/build scripts. The active environment
is the only source of vault passwords, the Ansible SSH identity, and the Ansible
public key. Service-account public keys may remain literal `host_vars` values;
no Ansible private key material lives in the repository.

## Findings

The dev container is already the only *documented* install path, but the legacy
route is still live in five places:

| Area | What remains |
|---|---|
| [`install.ps1`](../install.ps1) | `-InstallApt`, `-InstallVenv`, `-InstallVault`; `.venv`/`.collections` bootstrap |
| [`run.ps1`](../run.ps1) | vault prompt, `~/.ssh/ansible` loading, `ssh-agent` start, `.collections` fallback, "activate .venv" error text |
| [`build.ps1`](../build.ps1) | `.venv/bin/python` fallback, `.collections` fallback, legacy error text |
| `inventory` | [`group_vars/all/users.yml`](../inventory/group_vars/all/users.yml) hard-codes `~/.ssh/ansible` and a real `ssh-ed25519 ... ansible` public key; [`hosts.yml`](../inventory/hosts.yml) wires the private-key path into every host |
| `admin1` | `add_ansible_execution` runs `./install.ps1 -InstallVenv`, installs `uv`, copies `~/.ssh/ansible`, and can prefill vault templates |

Docs and wording: [`README.md`](../README.md),
[`context/guides/pwsh-ansible-workflow.md`](guides/pwsh-ansible-workflow.md),
[`context/guides/environment-switching.md`](guides/environment-switching.md),
[`context/guides/public-gateway-setup.md`](guides/public-gateway-setup.md),
[`AGENTS.md`](../AGENTS.md),
[`.devcontainer/Initialize-HomelabRuntime.ps1`](../.devcontainer/Initialize-HomelabRuntime.ps1),
[`Set-Environment.ps1`](../Set-Environment.ps1),
[`tests/troubleshoot-devcontainer-network.sh`](../tests/troubleshoot-devcontainer-network.sh).

`vault_pass.ps1` is **not** legacy. It is the vault-password-file plugin used by
`build.ps1`, `srv/Initialize-VaultTemplates.ps1`, and manual `ansible-vault`
commands. It stays.

## Decisions (confirmed)

1. **`admin1` uses the dev container.** Delete `install.ps1`; the
   `add_ansible_execution` role installs Docker and the devcontainer CLI instead
   of a repo-local venv.
2. **`run.ps1` hard-fails without an active environment.** No vault prompt, no
   `ssh-agent` bootstrap, no `~/.ssh/ansible` loading.
3. **The active environment is the only key source.** `run.ps1` keeps injecting
   `ansible_admin_ssh_public_key` from
   `~/.homelab-active/homelab-environment.json`, plus empty
   `ansible_admin_ssh_private_key_file=` and `ansible_ssh_private_key_file=`, so
   no inventory value can win.
4. **Published state is trusted for the public key.** A compromised container
   can already act on new hosts; the requirement is only that it cannot
   compromise the container host. Do not add extra agent-derived key validation
   for this.
5. **`admin1` receives a copy of the environment store.** The execution VM is a
   trusted host because the copied store contains the environment SSH private
   key; document that trust model.

---

## Phase 0 - Remove hard-coded inventory key material

- [x] `inventory/group_vars/all/users.yml`: remove
      `ansible_admin_ssh_private_key_file` and the hard-coded
      `ansible_admin_ssh_public_key` literal. Keep `shared_admin_users`
      referencing `ansible_admin_ssh_public_key`.
- [x] `inventory/hosts.yml`: remove
      `ansible_ssh_private_key_file: "{{ ansible_admin_ssh_private_key_file }}"`.
- [x] `inventory/host_vars/gateway2/host.yml`: remove the commented legacy
      `~/.ssh/id_ed25519` path or replace it with an environment-neutral
      comment.
- [x] Validate `ansible_admin_ssh_public_key` before it can be written to a
      host: non-empty, `ssh-`/`ecdsa-` prefix, and a base64 body. Add the check
      where users are materialized (`export_autoinstall_seed` today, plus any
      future user role).
- [x] Add a regression check that rejects the legacy Ansible identity
      (`~/.ssh/ansible`, `~/.ssh/id_ed25519`, and an `ssh-... ansible` key)
      under `inventory/`. Service-account public keys are allowed.
- [x] Keep the active-environment `--extra-vars` injection described in Phase 2
      so a leftover local value can never take precedence.

## Phase 1 - Move requirements into `.devcontainer/`

- [x] `git mv venv-requirements.txt .devcontainer/venv-requirements.txt`
- [x] `git mv collection-requirements.txt .devcontainer/collection-requirements.txt`
- [x] `.devcontainer/Dockerfile` (build context is the repo root, so paths stay
      repo-relative):
  - `COPY .devcontainer/venv-requirements.txt .devcontainer/collection-requirements.txt /tmp/ansible-bootstrap/`
  - Update the comment that says the repo-local `.venv`/`.collections` are "only
    needed by the legacy WSL workflow".
- [x] Update references in `README.md`.
- [x] Delete `apt-requirements.txt`: its only consumer was `install.ps1` (via a
      TODO comment), and the Dockerfile already owns the apt list. Keep it only
      if you prefer to make the Dockerfile read it.
- [x] Optional: rename to `pip-requirements.txt` while moving. Prefer keeping
      the current names to avoid churn.

## Phase 2 - Strip `run.ps1`

- [x] Delete `$defaultAnsibleSshKeyPath`, `Ensure-AnsibleSshKeyLoaded`,
      `Test-SshAgentHasKey`, `Start-SshAgent`.
- [x] Delete the `$localCollections` / `$devContainerToolchain` block; rely on
      the image's `ANSIBLE_COLLECTIONS_PATH`.
- [x] In `Invoke-Playbook`: require the active state; throw
      `"No active environment. Run 'pwsh Set-Environment.ps1 -Environment <name>' on the container host first."`
      instead of falling back.
- [x] Delete the `else` branch that prompts for a vault password and passes
      `vault_pass.ps1`.
- [x] Delete `Remove-Item Env:ANSIBLE_VAULT_PASSWORD` (nothing sets it any more).
- [x] Update `Write-Help` and the "Run Set-Environment.ps1 on the WSL host"
      messages to "on the container host".
- [x] `Require-Command` message becomes a plain missing-dependency error.
- [x] Keep `Use-ActiveEnvironment` including the `ssh-add -l` check: that is
      verification, not interactive key handling.
- [x] Keep the active-environment `--extra-vars` injection:
      `ansible_admin_ssh_public_key` from the published state, plus empty
      `ansible_admin_ssh_private_key_file=` and
      `ansible_ssh_private_key_file=`. This guarantees the agent is used even if
      a stale inventory or host var remains.

## Phase 3 - Strip `build.ps1` and `tests/verify-vault-template-render.ps1`

- [x] `build.ps1`:
  - Drop the `.venv/bin/python` and `.collections` fallbacks.
  - Require `ANSIBLE_PYTHON` (already set by `devcontainer.json`) and fail with
    a clear "run inside the dev container" message. Keep `python3` as a fallback
    only if the script must stay usable outside the image.
  - Update `Require-Command` text.
  - Keep `Ensure-VaultPassword`'s active-runtime detection. Recommended:
    replace its prompt fallback with the same "run Set-Environment.ps1" error,
    so `build.ps1` and `run.ps1` behave identically.
- [x] `tests/verify-vault-template-render.ps1`: remove the `.venv` fallback and
      the legacy error text; use `ANSIBLE_PYTHON` or `python3`.
- [x] Optional: add negative checks to `tests/verify-devcontainer.ps1` (for
      example, `ansible-playbook` resolves inside the image's venv and no
      `.venv` exists) so the legacy route cannot creep back.

## Phase 4 - Delete `install.ps1` and retarget `admin1`

- [x] `git rm install.ps1`.
- [x] `playbooks/roles/add_ansible_execution/`:
  - Remove the `uv` install task and `add_ansible_execution_install_uv`.
  - Remove the `.venv/bin/ansible-playbook` stat and the
    `install.ps1 -InstallVenv` task.
  - Add Docker via the existing role or an `include_role: add_docker` with
    `add_docker_users: ["{{ add_ansible_execution_repo_owner }}"]`.
  - Add `nodejs` + `npm` to `add_ansible_execution_packages` and install
    `@devcontainers/cli` globally.
  - Trim `add_ansible_execution_packages`: drop `python3-pip`, `python3-venv`,
    `sshpass`, `xorriso` (those live in the image now); keep
    `ca-certificates`, `git`, `openssh-client`.
  - Keep `add_ansible_execution_install_powershell`; `initializeCommand` and
    `Set-Environment.ps1` both run on the host.
  - Remove `add_ansible_execution_copy_ssh_key`,
    `add_ansible_execution_ssh_private_key_source`,
    `add_ansible_execution_ssh_public_key_source`, the SSH directory task, and
    the key-copy tasks.
  - Remove `add_ansible_execution_prefill_vault_templates`; do not create
    missing local `vault.yml` files. The copied environment store supplies them.
  - Print instructions for copying the host environment store
    (`~/.homelab/environments/<name>`) to the VM and running
    `Set-Environment.ps1 -Environment <name>` there.
  - Document that the execution VM is trusted because it holds the environment
    SSH private key.
  - Replace the helper wrappers:
    - `homelab-run` -> `devcontainer up --workspace-folder <repo> && devcontainer exec --workspace-folder <repo> -- pwsh ./run.ps1 "$@"`
    - `homelab-lint` -> same pattern with `./build.ps1`
    - `homelab-init-vaults` -> same pattern with
      `./srv/Initialize-VaultTemplates.ps1 -RepoRoot .`
    - `homelab-install` -> delete
  - Update `playbooks/add-ansible-execution.yml` metadata if the role no longer
    installs the toolchain.
- [x] `inventory/host_vars/admin1/host.yml`: no change needed unless new role
      flags are added.
- [x] `context/guides/ansible-execution-vm.md`: replace "installs the repo
      runtime dependencies" / "installs `uv`" with Docker + devcontainer CLI,
      document that the first `homelab-run` builds the image, and add the
      environment-store copy + trust-model steps.
- [x] Note: after `add_docker_users` runs, the `talos` session needs one
      reconnect before `docker` works without sudo.

## Phase 5 - Wording and docs

- [x] `AGENTS.md`: drop the "`install.ps1` is only for the legacy WSL workflow"
      line; point the workflow note at the renamed guide.
- [x] `README.md`: delete "Option B: legacy WSL setup" and the `.venv`
      activation; document the hard requirement to run `Set-Environment.ps1`
      first; point at the `.devcontainer/` requirements.
- [x] Rename `context/guides/wsl-pwsh-ansible-workflow.md` to
      `context/guides/pwsh-ansible-workflow.md`; delete the legacy section and
      the "why the legacy flow still exists" notes; keep dev container +
      environment switching.
- [x] `context/guides/environment-switching.md`: "WSL / container host" ->
      "container host"; expand the `run.ps1` section to state that no active
      environment is now a hard error and that `ansible_admin_ssh_public_key`
      comes from the active environment.
- [x] `context/guides/public-gateway-setup.md`: remove the "For the legacy WSL
      workflow, activate `.venv`" note and replace `~/.ssh/ansible` references
      with the active environment's agent/key. Update the
      `ansible_ssh_private_key_file` override notes.
- [x] `Set-Environment.ps1` and `.devcontainer/Initialize-HomelabRuntime.ps1`:
      replace "WSL/container host" and "Linux/WSL host" with "container host".
- [x] `tests/troubleshoot-devcontainer-network.sh`: "WSL shell that VS Code
      uses" -> "Docker host shell".
- [x] `context/TODO.md`: replace the Dev Container, Set-Environment key-migration,
      and add-ansible-execution items with a single pointer to this file.
- [x] Optional cleanup: drop `.venv/` and `.collections/` from `.gitignore` and
      `.dockerignore`, and the `.venv`/`.collections` exclusions in
      `Set-Environment.ps1`'s vault scan.

## Verification

1. [ ] Rebuild the image: `docker build -f .devcontainer/Dockerfile .` (validates
       the moved requirements).
2. [ ] Inside the container: `pwsh tests/verify-devcontainer.ps1`,
       `pwsh tests/verify-vault-template-render.ps1`, `pwsh build.ps1`.
3. [ ] Negative test: with no `~/.homelab-active`, `pwsh run.ps1 add-vm.yml`
       fails with the Set-Environment message, not a prompt.
4. [ ] Positive test: after `Set-Environment.ps1 <name>`, `pwsh run.ps1
       add-vm.yml --syntax-check` (via `-Debug` or direct) picks up the tmpfs
       password and socket, and confirms the active public key is injected.
5. [ ] Inventory guard:
       `grep -rniE "\.ssh/(ansible|id_ed25519)|ssh-(ed25519|rsa)\s+\S+\s+ansible\b" inventory/`
       returns no hits.
6. [ ] `ansible-playbook -i inventory/hosts.yml playbooks/add-ansible-execution.yml --syntax-check`.
7. [ ] Repo-wide search should only hit intentional text:
       `grep -rniE "install\.ps1|InstallVenv|InstallApt|\.venv|WSL"`
       (excluding `context/llm/ansible-ssh-format-disks.md`, which is about VM
       SSH and unrelated).
8. [ ] Rebuild/restart `admin1`: `homelab-run -Help` works through
       `devcontainer exec`.

## Risks / open items

- **`admin1` image build cost:** the first `devcontainer up` on `admin1`
  rebuilds the image locally. If that host is slow or offline, consider
  publishing the image to a registry later.
- **Docker group timing:** the wrapper needs a fresh login after the role adds
  the user to `docker`.
- **`build.ps1` without an environment:** if its vault prompt is dropped,
  linting a clone that still has encrypted `vault.yml` files requires an active
  environment. That matches `run.ps1`, but it is a behavior change worth
  confirming.
- **`vault_pass.ps1`:** left alone. If the `ANSIBLE_VAULT_PASSWORD` fallback
  should also go, that is a small follow-up in `vault_pass.ps1` + `build.ps1`.
- **Execution VM trust:** copying the environment store to `admin1` puts the
  environment SSH private key at rest there. Treat that VM as a trusted host and
  document it.
- **Git history:** the current hard-coded public key stays in old commits.
  Removing it from `HEAD` stops new checkouts from authorizing it, but anyone
  running an old revision still uses the old identity. The key is public, so
  this is an environment-isolation issue rather than a secret leak.

## Suggested commits

Single commit:

```
chore(devcontainer): remove legacy WSL setup route
```

If a series is preferred:

```
build(devcontainer): move ansible requirements into .devcontainer
refactor(inventory): source the ansible key from the active environment
refactor(run): require an active environment and drop ssh-agent bootstrap
chore(install): remove the legacy install.ps1 route
feat(add_ansible_execution): run the repo through the dev container and environment store
docs: drop the legacy WSL workflow
```
