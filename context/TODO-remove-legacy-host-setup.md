# TODO: Remove the legacy host setup route

Status: **not started**

Source TODO:

```markdown
# Dev Container
- devcontainer verified. Remove the legacy WSL setup route, wsl, python, ansible etc. setup and interactive key handling from all init / run etc. scripts.
- move venv-requirements.txt collection-requirements.txt to .devcontainer?
```

Goal: the dev container is the only supported way to run the Ansible
toolchain. No WSL/host install route, no repo-local `.venv` or `.collections`,
no interactive SSH key handling in the run/build scripts.

## Findings

The dev container is already the only *documented* install path, but the legacy
route is still live in four places:

| Area | What remains |
|---|---|
| [`install.ps1`](../install.ps1) | `-InstallApt`, `-InstallVenv`, `-InstallVault`; `.venv`/`.collections` bootstrap |
| [`run.ps1`](../run.ps1) | vault prompt, `~/.ssh/ansible` loading, `ssh-agent` start, `.collections` fallback, "activate .venv" error text |
| [`build.ps1`](../build.ps1) | `.venv/bin/python` fallback, `.collections` fallback, legacy error text |
| `admin1` | `add_ansible_execution` runs `./install.ps1 -InstallVenv` and installs `uv`; helper wrappers include `homelab-install` |

Docs and wording: [`README.md`](../README.md),
[`context/guides/wsl-pwsh-ansible-workflow.md`](guides/wsl-pwsh-ansible-workflow.md),
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

---

## Phase 1 - Move requirements into `.devcontainer/`

- [ ] `git mv venv-requirements.txt .devcontainer/venv-requirements.txt`
- [ ] `git mv collection-requirements.txt .devcontainer/collection-requirements.txt`
- [ ] `.devcontainer/Dockerfile` (build context is the repo root, so paths stay
      repo-relative):
  - `COPY .devcontainer/venv-requirements.txt .devcontainer/collection-requirements.txt /tmp/ansible-bootstrap/`
  - Update the comment that says the repo-local `.venv`/`.collections` are "only
    needed by the legacy WSL workflow".
- [ ] Update references in `README.md`.
- [ ] Delete `apt-requirements.txt`: its only consumer was `install.ps1` (via a
      TODO comment), and the Dockerfile already owns the apt list. Keep it only
      if you prefer to make the Dockerfile read it.
- [ ] Optional: rename to `pip-requirements.txt` while moving. Prefer keeping
      the current names to avoid churn.

## Phase 2 - Strip `run.ps1`

- [ ] Delete `$defaultAnsibleSshKeyPath`, `Ensure-AnsibleSshKeyLoaded`,
      `Test-SshAgentHasKey`, `Start-SshAgent`.
- [ ] Delete the `$localCollections` / `$devContainerToolchain` block; rely on
      the image's `ANSIBLE_COLLECTIONS_PATH`.
- [ ] In `Invoke-Playbook`: require the active state; throw
      `"No active environment. Run Set-Environment.ps1 on the container host first."`
      instead of falling back.
- [ ] Delete the `else` branch that prompts for a vault password and passes
      `vault_pass.ps1`.
- [ ] Delete `Remove-Item Env:ANSIBLE_VAULT_PASSWORD` (nothing sets it any more).
- [ ] Update `Write-Help` and the "Run Set-Environment.ps1 on the WSL host"
      messages to "on the container host".
- [ ] `Require-Command` message becomes a plain missing-dependency error.
- [ ] Keep `Use-ActiveEnvironment` including the `ssh-add -l` check: that is
      verification, not interactive key handling.

## Phase 3 - Strip `build.ps1` and `tests/verify-vault-template-render.ps1`

- [ ] `build.ps1`:
  - Drop the `.venv/bin/python` and `.collections` fallbacks.
  - Require `ANSIBLE_PYTHON` (already set by `devcontainer.json`) and fail with
    a clear "run inside the dev container" message. Keep `python3` as a fallback
    only if the script must stay usable outside the image.
  - Update `Require-Command` text.
  - Keep `Ensure-VaultPassword`'s active-runtime detection. Recommended:
    replace its prompt fallback with the same "run Set-Environment.ps1" error,
    so `build.ps1` and `run.ps1` behave identically.
- [ ] `tests/verify-vault-template-render.ps1`: remove the `.venv` fallback and
      the legacy error text; use `ANSIBLE_PYTHON` or `python3`.
- [ ] Optional: add negative checks to `tests/verify-devcontainer.ps1` (for
      example, `ansible-playbook` resolves inside the image's venv and no
      `.venv` exists) so the legacy route cannot creep back.

## Phase 4 - Delete `install.ps1` and retarget `admin1`

- [ ] `git rm install.ps1`.
- [ ] `playbooks/roles/add_ansible_execution/`:
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
  - Replace the helper wrappers:
    - `homelab-run` -> `devcontainer up --workspace-folder <repo> && devcontainer exec --workspace-folder <repo> -- pwsh ./run.ps1 "$@"`
    - `homelab-lint` -> same pattern with `./build.ps1`
    - `homelab-init-vaults` -> same pattern with
      `./srv/Initialize-VaultTemplates.ps1 -RepoRoot .`
    - `homelab-install` -> delete
  - Update `playbooks/add-ansible-execution.yml` metadata if the role no longer
    installs the toolchain.
- [ ] `inventory/host_vars/admin1/host.yml`: no change needed unless new role
      flags are added.
- [ ] `context/guides/ansible-execution-vm.md`: replace "installs the repo
      runtime dependencies" / "installs `uv`" with Docker + devcontainer CLI,
      and document that the first `homelab-run` builds the image.
- [ ] Note: after `add_docker_users` runs, the `talos` session needs one
      reconnect before `docker` works without sudo.

## Phase 5 - Wording and docs

- [ ] `AGENTS.md`: drop the "`install.ps1` is only for the legacy WSL workflow"
      line; point the workflow note at the renamed guide.
- [ ] `README.md`: delete "Option B: legacy WSL setup" and the `.venv`
      activation; document the hard requirement to run `Set-Environment.ps1`
      first; point at the `.devcontainer/` requirements.
- [ ] Rename `context/guides/wsl-pwsh-ansible-workflow.md` to
      `context/guides/pwsh-ansible-workflow.md`; delete the legacy section and
      the "why the legacy flow still exists" notes; keep dev container +
      environment switching.
- [ ] `context/guides/environment-switching.md`: "WSL / container host" ->
      "container host"; expand the `run.ps1` section to state that no active
      environment is now a hard error.
- [ ] `context/guides/public-gateway-setup.md`: remove the "For the legacy WSL
      workflow, activate `.venv`" note.
- [ ] `Set-Environment.ps1` and `.devcontainer/Initialize-HomelabRuntime.ps1`:
      replace "WSL/container host" and "Linux/WSL host" with "container host".
- [ ] `tests/troubleshoot-devcontainer-network.sh`: "WSL shell that VS Code
      uses" -> "Docker host shell".
- [ ] `context/TODO.md`: remove the two Dev Container items and link this file.
- [ ] Optional cleanup: drop `.venv/` and `.collections/` from `.gitignore` and
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
       password and socket.
5. [ ] `ansible-playbook -i inventory/hosts.yml playbooks/add-ansible-execution.yml --syntax-check`.
6. [ ] Repo-wide search should only hit intentional text:
       `grep -rniE "install\.ps1|InstallVenv|InstallApt|\.venv|WSL"`
       (excluding `context/llm/ansible-ssh-format-disks.md`, which is about VM
       SSH and unrelated).
7. [ ] Rebuild/restart `admin1`: `homelab-run -Help` works through
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
- **Out of scope:** the separate `add ansible execution vm` TODO (drop
  `add_ansible_execution_prefill_vault_templates`, thin the role to pwsh +
  clone). This plan only changes the toolchain bootstrap.

## Suggested commits

Single commit:

```
chore(devcontainer): remove legacy WSL setup route
```

If a series is preferred:

```
build(devcontainer): move ansible requirements into .devcontainer
refactor(run): require an active environment and drop ssh-agent bootstrap
chore(install): remove the legacy install.ps1 route
feat(add_ansible_execution): run the repo through the dev container
docs: drop the legacy WSL workflow
```
