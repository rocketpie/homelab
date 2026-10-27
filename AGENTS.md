# AGENTS.md

This file is the entrypoint for coding agents working in this repository.
Make sure to read `README.md` as well.

## Start Here

Before making changes:

Do not try to build a one-time full context model of the whole repository up front. 
Prefer a fast initial scan and then task-specific reading.
Keep changes focused and minimal. The best code is the code never written. Solve problems with the least amount of new code.

## Directories

The [`context/`](context/) directory is the shared home for:
- [`context/guides/`](context/guides/) for human-oriented guides, workflows, and helper assets
  Current workflow notes worth checking:
  - `context/guides/pwsh-ansible-workflow.md` for the dev container + `pwsh` execution flow
  - `context/guides/naming-conventions.md` for playbook, role, and variable naming rules

- [`context/llm/`](context/llm/) for concise LLM-oriented context and summaries
- implementation notes that should be reusable across sessions

When adding durable project knowledge, prefer placing it in `context/` rather than bloating this or any other file.

- [`inventory/`](inventory/) contains inventory, group vars, and host vars
- [`playbooks/`](playbooks/) contains playbooks and roles
- [`playbooks/add-vm.yml`](playbooks/add-vm.yml) is a central workflow for provisioning a VM on Proxmox
- [`tests`](tests/) as much setup, inventory, process and config validation as usefully possible.

## Working Conventions

- Use git in read-only mode, never stash, stage, unstage, branch, merge, commit or revert anything. 
- Use `context/` for project guidance and LLM context before making assumptions.
- Never use absolute paths anywhere. Paths should always be relative to the repository root, or relative to the file they appear in.
- The Ansible toolchain lives in a reproducibile dev container. Do not install ansible, python or related tooling on the host if it's missing.
- Follow existing Ansible and PowerShell patterns already used in the repo.
- Use the repository naming convention:
  playbooks use PowerShell-style verb-noun names in kebab-case, roles use verb_noun snake_case, and role-local variables should be prefixed with the full role name.
- When troubleshooting, guess at most once.
  After the first guess, add explicit troubleshooting steps, name them with `troubleshoot`, capture the real output/log/response format, and use that evidence to drive the next change.
- Prefer updating the relevant `context/` docs when you discover task-specific knowledge that should persist.
- Do not overwrite unrelated user changes.
- When adding new roles, servers, or services, check if `service-admin-scripts.yml` applies.
- With every change, recommend a commit message at the very end of the output.

## When Updating Docs

Update `context/` when:

- a workflow becomes stable enough to reuse
- a repo rule or constraint should be preserved for future sessions
- a non-obvious infrastructure assumption was uncovered during implementation

Keep `AGENTS.md` short. Put durable detail in `context/`.
