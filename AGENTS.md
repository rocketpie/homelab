# AGENTS.md

This file is the entrypoint for coding agents working in this repository.

Rule: never use absolute paths anywhere. Paths should always be relative to the repository root, or relative to the file they appear in.
Rule: never interact with *vault.yml files.

## Purpose

This repository automates parts of a homelab with Ansible, with a current focus on provisioning and configuring Proxmox VMs.

## Start Here

Before making changes:

1. Read this file.
2. Do a lightweight repo scan.
3. Open only the relevant files for the task.
4. Use `context/` for project guidance and LLM context before making assumptions.

Do not try to build a one-time full mental model of the whole repository up front. Prefer a fast initial scan and then task-specific reading.

## Context Directory

The [`context/`](context/) directory is the shared home for:

- human-oriented guides
- LLM task context
- implementation notes that should be reusable across sessions

Current structure:

- [`context/guides/`](context/guides/) for human-readable guides, workflows, and helper assets
- [`context/llm/`](context/llm/) for concise LLM-oriented context and summaries

When adding durable project knowledge, prefer placing it in `context/` rather than bloating this file.

Current workflow notes worth checking:
- `context/guides/wsl-pwsh-ansible-workflow.md` for the local WSL + `pwsh` execution flow
- `context/guides/naming-conventions.md` for playbook, role, and variable naming rules

## Lightweight Repo Scan

At the start of a task, quickly inspect:

- top-level directories and key files
- the target inventory, playbook, role, or host vars involved in the request

If relevant, also inspect:

- [`inventory/`](inventories/)
- [`playbooks/`](playbooks/)
- the matching files under `context/`

## Working Conventions

- Keep changes focused and minimal.
- Follow existing Ansible and PowerShell patterns already used in the repo.
- Use the repository naming convention:
  playbooks use PowerShell-style verb-noun names in kebab-case, roles use verb_noun snake_case, and role-local variables should be prefixed with the full role name.
- Prefer updating the relevant `context/` docs when you discover task-specific knowledge that should persist.
- Do not overwrite unrelated user changes.
- Treat inventory and host variable changes as sensitive, because they affect real infrastructure behavior.

## Key Areas

- [`inventory/`](inventory/) contains inventory, group vars, and host vars
- [`playbooks/`](playbooks/) contains playbooks and roles
- [`playbooks/add-vm.yml`](playbooks/add-vm.yml) is a central workflow for provisioning a VM on Proxmox

## When Updating Docs

Update `context/` when:

- a workflow becomes stable enough to reuse
- a repo rule or constraint should be preserved for future sessions
- a non-obvious infrastructure assumption was uncovered during implementation

Keep `AGENTS.md` short. Put durable detail in `context/`.
